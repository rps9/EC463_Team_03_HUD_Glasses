#include <Arduino.h>
#include <SPI.h>
#include <U8g2lib.h>
#include "driver/i2s.h"
#include "esp_log.h"
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

namespace {

static const i2s_port_t I2S_PORT = I2S_NUM_0;
static const int SAMPLE_RATE = 8000;

static const int PIN_I2S_BCLK = 26;
static const int PIN_I2S_LRCLK = 25;
static const int PIN_I2S_DIN = 33;

static const int PIN_DISPLAY_MOSI = 23;
static const int PIN_DISPLAY_CLK = 18;
static const int PIN_DISPLAY_CS = 5;
static const int PIN_DISPLAY_DC = 21;
static const int PIN_DISPLAY_RST = 22;

static const size_t MAX_TEXT_LEN = 160;
static const uint8_t LINE_HEIGHT = 10;
static const uint8_t MAX_LINES = 6;

static BLEUUID SERVICE_UUID("9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID AUDIO_DATA_UUID("9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID CONTROL_UUID("9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID STATUS_UUID("9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001");

U8G2_SSD1306_128X64_NONAME_F_4W_HW_SPI display(U8G2_R2, PIN_DISPLAY_CS, PIN_DISPLAY_DC, PIN_DISPLAY_RST);

BLECharacteristic *audioDataCharacteristic = nullptr;
BLECharacteristic *statusCharacteristic = nullptr;

volatile bool deviceConnected = false;
volatile bool streamEnabled = false;
uint16_t packetSeq = 0;
float dcEstimate = 0.0f;
float smoothedGain = 1.0f;
std::string inboundTextBuffer;
String currentDisplayText = "Waiting for BLE text";
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
  display.drawStr(0, 8, "HUDini ESP32 HUD test");
  display.drawStr(0, 18, "BLE mic + display");
  display.drawStr(0, 28, "Mic: B26 W25 D33");
  display.drawStr(0, 38, "OLED: S18 M23");
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

class MicServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    (void)server;
    deviceConnected = true;
    queueDisplayText("BLE connected");
    if (statusCharacteristic && notificationsEnabled(statusCharacteristic)) {
      statusCharacteristic->setValue("Connected");
      statusCharacteristic->notify();
    }
  }

  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    streamEnabled = false;
    queueDisplayText("BLE disconnected");
    if (statusCharacteristic) {
      statusCharacteristic->setValue("Disconnected");
    }
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
      streamEnabled = true;
      packetSeq = 0;
      dcEstimate = 0.0f;
      smoothedGain = 1.0f;
      queueDisplayText("Streaming audio...");
      if (statusCharacteristic && notificationsEnabled(statusCharacteristic)) {
        statusCharacteristic->setValue("Streaming");
        statusCharacteristic->notify();
      }
    } else if (upperValue == "STOP") {
      streamEnabled = false;
      queueDisplayText("Stream stopped");
      if (statusCharacteristic && notificationsEnabled(statusCharacteristic)) {
        statusCharacteristic->setValue("Stopped");
        statusCharacteristic->notify();
      }
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
    } else if (upperValue.rfind("TEXT:", 0) == 0) {
      const String text = String(value.substr(5).c_str());
      Serial.print("[BLE RX] ");
      Serial.println(text);
      queueDisplayText(text);
    }
  }
};

void setupI2S() {
  i2s_config_t i2s_config = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 256,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0};

  i2s_pin_config_t pin_config = {
      .bck_io_num = PIN_I2S_BCLK,
      .ws_io_num = PIN_I2S_LRCLK,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = PIN_I2S_DIN};

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setupBLE() {
  BLEDevice::init("HUDini-Mic");
  BLEDevice::setMTU(185);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new MicServerCallbacks());

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
  Serial.println("Starting BLE mic + HUD display streamer");
  esp_log_level_set("BLECharacteristic", ESP_LOG_NONE);
  esp_log_level_set("BLE2902", ESP_LOG_NONE);

  showBootScreen();
  setupI2S();
  setupBLE();
  queueDisplayText(currentDisplayText);
}

void loopFirmware() {
  flushDisplayIfNeeded();

  if (!deviceConnected || !streamEnabled || audioDataCharacteristic == nullptr) {
    delay(10);
    return;
  }

  if (!notificationsEnabled(audioDataCharacteristic)) {
    delay(10);
    return;
  }

  const int N = 80;
  int32_t i2sSamples[N];
  int16_t pcm16[N];
  uint8_t packet[6 + (N * sizeof(int16_t))];

  size_t bytesRead = 0;
  i2s_read(I2S_PORT, (void *)i2sSamples, sizeof(i2sSamples), &bytesRead, portMAX_DELAY);

  int count = bytesRead / sizeof(int32_t);
  if (count <= 0) {
    return;
  }

  if (count > N) {
    count = N;
  }

  int32_t sumAbs = 0;
  for (int i = 0; i < count; i++) {
    int32_t s24 = i2sSamples[i] >> 8;
    int32_t s16 = s24 >> 8;

    if (s16 > 32767) {
      s16 = 32767;
    } else if (s16 < -32768) {
      s16 = -32768;
    }

    dcEstimate += 0.01f * ((float)s16 - dcEstimate);
    int32_t hp = (int32_t)((float)s16 - dcEstimate);
    if (hp > 32767) hp = 32767;
    if (hp < -32768) hp = -32768;
    pcm16[i] = (int16_t)hp;
    sumAbs += abs(hp);
  }

  const float avgAbs = (count > 0) ? ((float)sumAbs / (float)count) : 0.0f;
  const float targetAbs = 2500.0f;
  float desiredGain = targetAbs / max(avgAbs, 250.0f);
  if (desiredGain < 1.0f) desiredGain = 1.0f;
  if (desiredGain > 6.0f) desiredGain = 6.0f;
  smoothedGain = (0.85f * smoothedGain) + (0.15f * desiredGain);

  for (int i = 0; i < count; i++) {
    int32_t amplified = (int32_t)((float)pcm16[i] * smoothedGain);
    if (amplified > 30000) amplified = 30000;
    if (amplified < -30000) amplified = -30000;
    pcm16[i] = (int16_t)amplified;
  }

  packet[0] = 1;
  packet[1] = 0;
  packet[2] = (uint8_t)(packetSeq & 0xFF);
  packet[3] = (uint8_t)((packetSeq >> 8) & 0xFF);
  packet[4] = (uint8_t)(count & 0xFF);
  packet[5] = (uint8_t)((count >> 8) & 0xFF);

  memcpy(packet + 6, pcm16, count * sizeof(int16_t));

  audioDataCharacteristic->setValue(packet, 6 + (count * sizeof(int16_t)));
  audioDataCharacteristic->notify();

  packetSeq++;
  delay(2);
}

}  // namespace

void setup() {
  setupFirmware();
}

void loop() {
  loopFirmware();
}
