#include <Arduino.h>
#include "driver/i2s.h"
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

static const i2s_port_t I2S_PORT = I2S_NUM_0;
static const int SAMPLE_RATE = 16000;

// Your wiring
static const int PIN_I2S_BCLK = 26;
static const int PIN_I2S_LRCLK = 25;
static const int PIN_I2S_DIN = 33;

// BLE UUIDs (must match iOS app)
static BLEUUID SERVICE_UUID("9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID AUDIO_DATA_UUID("9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID CONTROL_UUID("9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001");
static BLEUUID STATUS_UUID("9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001");

static BLECharacteristic *audioDataCharacteristic = nullptr;
static BLECharacteristic *statusCharacteristic = nullptr;

static volatile bool deviceConnected = false;
static volatile bool streamEnabled = false;
static uint16_t packetSeq = 0;

class MicServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    deviceConnected = true;
    if (statusCharacteristic) {
      statusCharacteristic->setValue("Connected");
      statusCharacteristic->notify();
    }
  }

  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    streamEnabled = false;
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

    for (char &ch : value) {
      ch = static_cast<char>(toupper(static_cast<unsigned char>(ch)));
    }

    if (value.find("START") != std::string::npos) {
      streamEnabled = true;
      packetSeq = 0;
      if (statusCharacteristic) {
        statusCharacteristic->setValue("Streaming");
        statusCharacteristic->notify();
      }
    } else if (value.find("STOP") != std::string::npos) {
      streamEnabled = false;
      if (statusCharacteristic) {
        statusCharacteristic->setValue("Stopped");
        statusCharacteristic->notify();
      }
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

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("Starting BLE mic streamer");

  setupI2S();
  setupBLE();
}

void loop() {
  if (!deviceConnected || !streamEnabled || audioDataCharacteristic == nullptr) {
    delay(10);
    return;
  }

  // 80 samples = 5ms at 16kHz. Payload 160 bytes + 6 byte header.
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

  for (int i = 0; i < count; i++) {
    int32_t s24 = i2sSamples[i] >> 8;
    int32_t s16 = s24 >> 8;

    if (s16 > 32767) {
      s16 = 32767;
    } else if (s16 < -32768) {
      s16 = -32768;
    }

    pcm16[i] = (int16_t)s16;
  }

  packet[0] = 1; // protocol version
  packet[1] = 0; // reserved flags
  packet[2] = (uint8_t)(packetSeq & 0xFF);
  packet[3] = (uint8_t)((packetSeq >> 8) & 0xFF);
  packet[4] = (uint8_t)(count & 0xFF);
  packet[5] = (uint8_t)((count >> 8) & 0xFF);

  memcpy(packet + 6, pcm16, count * sizeof(int16_t));

  audioDataCharacteristic->setValue(packet, 6 + (count * sizeof(int16_t)));
  audioDataCharacteristic->notify();

  packetSeq++;
  delay(1);
}
