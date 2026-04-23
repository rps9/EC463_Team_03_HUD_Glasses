#include <Arduino.h>
#include <SPI.h>
#include <U8g2lib.h>
#include "esp_log.h"
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

namespace {

constexpr int PIN_DISPLAY_MOSI = 23;
constexpr int PIN_DISPLAY_CLK = 18;
constexpr int PIN_DISPLAY_CS = 5;
constexpr int PIN_DISPLAY_DC = 21;
constexpr int PIN_DISPLAY_RST = 22;

constexpr size_t MAX_TEXT_LEN = 160;
constexpr uint8_t LINE_HEIGHT = 10;
constexpr uint8_t MAX_LINES = 6;

BLEUUID SERVICE_UUID("9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001");
BLEUUID AUDIO_DATA_UUID("9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001");
BLEUUID CONTROL_UUID("9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001");
BLEUUID STATUS_UUID("9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001");

U8G2_SSD1306_128X64_NONAME_F_4W_HW_SPI display(U8G2_R2, PIN_DISPLAY_CS, PIN_DISPLAY_DC, PIN_DISPLAY_RST);

BLECharacteristic *audioDataCharacteristic = nullptr;
BLECharacteristic *statusCharacteristic = nullptr;

volatile bool deviceConnected = false;
std::string inboundTextBuffer;
String currentDisplayText = "Waiting for phone mic text";
String pendingDisplayText;
volatile bool displayDirty = false;
portMUX_TYPE displayMux = portMUX_INITIALIZER_UNLOCKED;

void queueDisplayText(const String &text) {
  String trimmed = text;
  trimmed.trim();
  if (trimmed.isEmpty()) {
    trimmed = " ";
  }

  if (trimmed.length() > MAX_TEXT_LEN) {
    trimmed.remove(MAX_TEXT_LEN);
  }

  portENTER_CRITICAL(&displayMux);
  pendingDisplayText = trimmed;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

bool notificationsEnabled(BLECharacteristic *characteristic) {
  if (characteristic == nullptr) {
    return false;
  }

  BLEDescriptor *cccd = characteristic->getDescriptorByUUID(BLEUUID((uint16_t)0x2902));
  if (cccd == nullptr) {
    return false;
  }

  BLE2902 *descriptor2902 = static_cast<BLE2902 *>(cccd);
  return descriptor2902->getNotifications();
}

void drawWrappedText(const String &text) {
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);

  String remaining = text;
  uint8_t y = 8;

  for (uint8_t line = 0; line < MAX_LINES && remaining.length() > 0; ++line) {
    int split = remaining.length();
    while (split > 0 && display.getStrWidth(remaining.substring(0, split).c_str()) > 128) {
      --split;
    }

    if (split <= 0) {
      split = 1;
    }

    int preferredSplit = split;
    while (preferredSplit > 1 && remaining[preferredSplit - 1] != ' ') {
      --preferredSplit;
    }
    if (preferredSplit > 1) {
      split = preferredSplit;
    }

    String lineText = remaining.substring(0, split);
    lineText.trim();
    display.drawStr(0, y, lineText.c_str());
    y += LINE_HEIGHT;

    remaining = remaining.substring(split);
    remaining.trim();
  }

  display.sendBuffer();
}

void showBootScreen() {
  SPI.begin(PIN_DISPLAY_CLK, -1, PIN_DISPLAY_MOSI, PIN_DISPLAY_CS);
  display.begin();
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);
  display.drawStr(0, 8, "HUDini BLE display");
  display.drawStr(0, 18, "ESP32 ready");
  display.drawStr(0, 28, "Waiting for app text");
  display.drawStr(0, 38, "DIN23 CLK18");
  display.drawStr(0, 48, "CS5 DC21 RST22");
  display.sendBuffer();
}

void flushDisplayIfNeeded() {
  if (!displayDirty) {
    return;
  }

  String nextText;
  portENTER_CRITICAL(&displayMux);
  nextText = pendingDisplayText;
  displayDirty = false;
  portEXIT_CRITICAL(&displayMux);

  currentDisplayText = nextText;
  drawWrappedText(currentDisplayText);
}

void publishStatus(const char *text) {
  if (statusCharacteristic == nullptr) {
    return;
  }

  statusCharacteristic->setValue(text);
  if (deviceConnected && notificationsEnabled(statusCharacteristic)) {
    statusCharacteristic->notify();
  }
}

class DisplayServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    (void)server;
    deviceConnected = true;
    publishStatus("Connected");
    queueDisplayText("BLE connected");
  }

  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    publishStatus("Disconnected");
    queueDisplayText("BLE disconnected");
    server->startAdvertising();
  }
};

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string value = characteristic->getValue();
    if (value.empty()) {
      return;
    }

    std::string upperValue = value;
    for (char &ch : upperValue) {
      ch = static_cast<char>(toupper(static_cast<unsigned char>(ch)));
    }

    if (upperValue == "START") {
      publishStatus("Display ready");
      Serial.println("[BLE RX] START");
    } else if (upperValue == "STOP") {
      publishStatus("Idle");
      Serial.println("[BLE RX] STOP");
    } else if (upperValue.rfind("TEXT_BEGIN", 0) == 0) {
      inboundTextBuffer.clear();
      Serial.println("[BLE RX] TEXT_BEGIN");
    } else if (upperValue.rfind("TEXT_CHUNK:", 0) == 0) {
      inboundTextBuffer += value.substr(11);
    } else if (upperValue.rfind("TEXT_END", 0) == 0) {
      Serial.println("[BLE RX] TEXT_END");
      Serial.print("[BLE RX] ");
      Serial.println(inboundTextBuffer.c_str());
      queueDisplayText(String(inboundTextBuffer.c_str()));
      publishStatus("Rendered text");
    } else if (upperValue.rfind("TEXT:", 0) == 0) {
      const String text = String(value.substr(5).c_str());
      Serial.print("[BLE RX] ");
      Serial.println(text);
      queueDisplayText(text);
      publishStatus("Rendered text");
    }
  }
};

void setupBLE() {
  BLEDevice::init("HUDini-Display");
  BLEDevice::setMTU(185);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new DisplayServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  audioDataCharacteristic = service->createCharacteristic(
      AUDIO_DATA_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  audioDataCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *controlCharacteristic = service->createCharacteristic(
      CONTROL_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  controlCharacteristic->setCallbacks(new ControlCallbacks());

  statusCharacteristic = service->createCharacteristic(
      STATUS_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  statusCharacteristic->addDescriptor(new BLE2902());
  statusCharacteristic->setValue("Idle");

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
}

void setupFirmware() {
  Serial.begin(115200);
  delay(300);
  esp_log_level_set("BLECharacteristic", ESP_LOG_NONE);
  esp_log_level_set("BLE2902", ESP_LOG_NONE);

  showBootScreen();
  setupBLE();
  queueDisplayText(currentDisplayText);

  Serial.println("HUDini BLE display ready");
  Serial.println("Connect from the app and send TEXT packets over the control characteristic");
}

void loopFirmware() {
  flushDisplayIfNeeded();
  delay(10);
}

}  // namespace

void setup() {
  setupFirmware();
}

void loop() {
  loopFirmware();
}
