#include <Arduino.h>
#include <PDM.h>
#include <U8g2lib.h>
#include <bluefruit.h>

#include <cstring>

namespace {

constexpr uint32_t PDM_SAMPLE_RATE = 16000;
constexpr uint32_t OUTPUT_SAMPLE_RATE = 8000;
constexpr size_t PDM_DECIMATION = PDM_SAMPLE_RATE / OUTPUT_SAMPLE_RATE;
constexpr size_t OUTPUT_SAMPLES_PER_PACKET = 80;
constexpr size_t RAW_SAMPLES_PER_PACKET = OUTPUT_SAMPLES_PER_PACKET * PDM_DECIMATION;
constexpr size_t AUDIO_HEADER_BYTES = 6;
constexpr size_t AUDIO_PAYLOAD_BYTES = OUTPUT_SAMPLES_PER_PACKET * sizeof(int16_t);
constexpr size_t AUDIO_PACKET_BYTES = AUDIO_HEADER_BYTES + AUDIO_PAYLOAD_BYTES;
constexpr size_t MIC_RING_CAPACITY = 4096;
constexpr size_t PDM_READ_CHUNK_SAMPLES = 128;

constexpr int PIN_PDM_CLK = 2;
constexpr int PIN_PDM_DIN = 3;

constexpr int PIN_DISPLAY_CLK = 13;
constexpr int PIN_DISPLAY_MOSI = 14;
constexpr int PIN_DISPLAY_CS = 15;
constexpr int PIN_DISPLAY_DC = 16;
constexpr int PIN_DISPLAY_RST = 17;

constexpr size_t MAX_TEXT_LEN = 160;
constexpr uint8_t LINE_HEIGHT = 10;
constexpr uint8_t MAX_LINES = 6;

const char *DEVICE_NAME = "HUDini-Mic";
const char *SERVICE_UUID = "9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001";
const char *AUDIO_DATA_UUID = "9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001";
const char *CONTROL_UUID = "9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001";
const char *STATUS_UUID = "9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001";

BLEService audioService(SERVICE_UUID);
BLECharacteristic audioDataCharacteristic(AUDIO_DATA_UUID);
BLECharacteristic controlCharacteristic(CONTROL_UUID);
BLECharacteristic statusCharacteristic(STATUS_UUID);

U8G2_SSD1306_128X64_NONAME_F_4W_SW_SPI display(
    U8G2_R0,
    PIN_DISPLAY_CLK,
    PIN_DISPLAY_MOSI,
    PIN_DISPLAY_CS,
    PIN_DISPLAY_DC,
    PIN_DISPLAY_RST);

volatile bool deviceConnected = false;
volatile bool streamEnabled = false;
volatile bool audioNotifyEnabled = false;
volatile bool statusNotifyEnabled = false;
volatile uint32_t pdmOverflowCount = 0;

uint16_t currentConnHandle = BLE_CONN_HANDLE_INVALID;
uint16_t packetSeq = 0;
float dcEstimate = 0.0f;
float smoothedGain = 1.0f;
String inboundTextBuffer;
String currentDisplayText = "Waiting for BLE text";
String pendingDisplayText;
volatile bool displayDirty = false;
char statusValue[32] = "Idle";

int16_t micRing[MIC_RING_CAPACITY];
volatile size_t micHead = 0;
volatile size_t micTail = 0;

size_t nextIndex(size_t index) {
  return (index + 1U) % MIC_RING_CAPACITY;
}

void queueDisplayText(const String &text) {
  String trimmed = text;
  trimmed.trim();
  if (trimmed.length() == 0) {
    trimmed = " ";
  }

  if (trimmed.length() > MAX_TEXT_LEN) {
    trimmed.remove(MAX_TEXT_LEN);
  }

  pendingDisplayText = trimmed;
  displayDirty = true;
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

void flushDisplayIfNeeded() {
  if (!displayDirty) {
    return;
  }

  currentDisplayText = pendingDisplayText;
  displayDirty = false;
  drawWrappedText(currentDisplayText);
}

void showBootScreen() {
  display.begin();
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);
  display.drawStr(0, 8, "HUDini MDBT42Q test");
  display.drawStr(0, 18, "BLE mic + display");
  display.drawStr(0, 28, "PDM: C2 D3");
  display.drawStr(0, 38, "OLED: S13 M14");
  display.drawStr(0, 48, "CS15 DC16 R17");
  display.sendBuffer();
}

void setStatusValue(const char *text) {
  strncpy(statusValue, text, sizeof(statusValue) - 1);
  statusValue[sizeof(statusValue) - 1] = '\0';

  statusCharacteristic.write(reinterpret_cast<const uint8_t *>(statusValue),
                             strlen(statusValue));
  if (deviceConnected && statusNotifyEnabled) {
    statusCharacteristic.notify(reinterpret_cast<const uint8_t *>(statusValue),
                                strlen(statusValue));
  }
}

String upperAsciiCopy(const uint8_t *data, uint16_t len) {
  String result;
  result.reserve(len);
  for (uint16_t i = 0; i < len; ++i) {
    result += static_cast<char>(toupper(static_cast<unsigned char>(data[i])));
  }
  return result;
}

String byteSpanToString(const uint8_t *data, uint16_t len) {
  String result;
  result.reserve(len);
  for (uint16_t i = 0; i < len; ++i) {
    result += static_cast<char>(data[i]);
  }
  return result;
}

void pushMicSample(int16_t sample) {
  const size_t next = nextIndex(micHead);
  if (next == micTail) {
    micTail = nextIndex(micTail);
    ++pdmOverflowCount;
  }

  micRing[micHead] = sample;
  micHead = next;
}

size_t availableMicSamples() {
  noInterrupts();
  const size_t head = micHead;
  const size_t tail = micTail;
  interrupts();

  if (head >= tail) {
    return head - tail;
  }

  return MIC_RING_CAPACITY - (tail - head);
}

size_t popMicSamples(int16_t *dst, size_t count) {
  size_t copied = 0;

  noInterrupts();
  while (copied < count && micTail != micHead) {
    dst[copied++] = micRing[micTail];
    micTail = nextIndex(micTail);
  }
  interrupts();

  return copied;
}

void onPdmData() {
  int16_t chunk[PDM_READ_CHUNK_SAMPLES];

  while (PDM.available() > 0) {
    const int bytesRead = PDM.read(chunk, sizeof(chunk));
    if (bytesRead <= 0) {
      return;
    }

    const size_t samplesRead = static_cast<size_t>(bytesRead) / sizeof(int16_t);
    for (size_t i = 0; i < samplesRead; ++i) {
      pushMicSample(chunk[i]);
    }
  }
}

void cccdCallback(uint16_t connHandle, BLECharacteristic *characteristic,
                  uint16_t cccdValue) {
  (void)cccdValue;

  if (characteristic == &audioDataCharacteristic) {
    audioNotifyEnabled = characteristic->notifyEnabled(connHandle);
    return;
  }

  if (characteristic == &statusCharacteristic) {
    statusNotifyEnabled = characteristic->notifyEnabled(connHandle);
  }
}

void controlWriteCallback(uint16_t connHandle, BLECharacteristic *characteristic,
                          uint8_t *data, uint16_t len) {
  (void)connHandle;
  (void)characteristic;

  if (len == 0) {
    return;
  }

  const String originalValue = byteSpanToString(data, len);
  const String upperValue = upperAsciiCopy(data, len);

  if (upperValue == "START") {
    streamEnabled = true;
    packetSeq = 0;
    dcEstimate = 0.0f;
    smoothedGain = 1.0f;
    queueDisplayText("Streaming audio...");
    setStatusValue("Streaming");
  } else if (upperValue == "STOP") {
    streamEnabled = false;
    queueDisplayText("Stream stopped");
    setStatusValue("Stopped");
  } else if (upperValue.startsWith("TEXT_BEGIN")) {
    inboundTextBuffer = "";
    Serial.println("[BLE RX] TEXT_BEGIN");
  } else if (upperValue.startsWith("TEXT_CHUNK:")) {
    inboundTextBuffer += originalValue.substring(11);
  } else if (upperValue.startsWith("TEXT_END")) {
    Serial.println("[BLE RX] TEXT_END");
    Serial.print("[BLE RX] ");
    Serial.println(inboundTextBuffer);
    queueDisplayText(inboundTextBuffer);
    setStatusValue("Rendered text");
  } else if (upperValue.startsWith("TEXT:")) {
    const String text = originalValue.substring(5);
    Serial.print("[BLE RX] ");
    Serial.println(text);
    queueDisplayText(text);
    setStatusValue("Rendered text");
  }
}

void connectCallback(uint16_t connHandle) {
  currentConnHandle = connHandle;
  deviceConnected = true;
  audioNotifyEnabled = false;
  statusNotifyEnabled = false;
  queueDisplayText("BLE connected");
  setStatusValue("Connected");
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  (void)reason;

  currentConnHandle = BLE_CONN_HANDLE_INVALID;
  deviceConnected = false;
  streamEnabled = false;
  audioNotifyEnabled = false;
  statusNotifyEnabled = false;
  queueDisplayText("BLE disconnected");
  setStatusValue("Disconnected");
  Bluefruit.Advertising.start(0);
}

void setupBle() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin(0, 1);
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName(DEVICE_NAME);

  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Periph.setConnInterval(6, 8);

  audioService.begin();

  audioDataCharacteristic.setProperties(CHR_PROPS_NOTIFY);
  audioDataCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  audioDataCharacteristic.setFixedLen(AUDIO_PACKET_BYTES);
  audioDataCharacteristic.setCccdWriteCallback(cccdCallback);
  audioDataCharacteristic.begin();

  controlCharacteristic.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  controlCharacteristic.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  controlCharacteristic.setMaxLen(192);
  controlCharacteristic.setWriteCallback(controlWriteCallback);
  controlCharacteristic.begin();

  statusCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  statusCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  statusCharacteristic.setMaxLen(sizeof(statusValue) - 1);
  statusCharacteristic.setCccdWriteCallback(cccdCallback);
  statusCharacteristic.begin();
  setStatusValue("Idle");

  Bluefruit.Advertising.stop();
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(audioService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void setupMic() {
  PDM.onReceive(onPdmData);
  if (!PDM.begin(1, PDM_SAMPLE_RATE)) {
    Serial.println("Failed to start PDM microphone");
    queueDisplayText("PDM mic start failed");
    while (true) {
      delay(1000);
    }
  }

  PDM.setGain(30);
}

void buildAndSendAudioPacket() {
  if (!deviceConnected || !streamEnabled || !audioNotifyEnabled) {
    return;
  }

  if (availableMicSamples() < RAW_SAMPLES_PER_PACKET) {
    return;
  }

  int16_t rawSamples[RAW_SAMPLES_PER_PACKET];
  const size_t popped = popMicSamples(rawSamples, RAW_SAMPLES_PER_PACKET);
  if (popped < RAW_SAMPLES_PER_PACKET) {
    return;
  }

  int16_t pcm16[OUTPUT_SAMPLES_PER_PACKET];
  uint8_t packet[AUDIO_PACKET_BYTES];

  int32_t sumAbs = 0;
  for (size_t i = 0; i < OUTPUT_SAMPLES_PER_PACKET; ++i) {
    int32_t accum = 0;
    for (size_t j = 0; j < PDM_DECIMATION; ++j) {
      accum += rawSamples[(i * PDM_DECIMATION) + j];
    }

    int32_t s16 = accum / static_cast<int32_t>(PDM_DECIMATION);

    dcEstimate += 0.01f * (static_cast<float>(s16) - dcEstimate);
    int32_t hp = static_cast<int32_t>(static_cast<float>(s16) - dcEstimate);

    if (hp > 32767) {
      hp = 32767;
    } else if (hp < -32768) {
      hp = -32768;
    }

    pcm16[i] = static_cast<int16_t>(hp);
    sumAbs += abs(hp);
  }

  const float avgAbs =
      static_cast<float>(sumAbs) / static_cast<float>(OUTPUT_SAMPLES_PER_PACKET);
  const float targetAbs = 2500.0f;
  float desiredGain = targetAbs / max(avgAbs, 250.0f);
  if (desiredGain < 1.0f) {
    desiredGain = 1.0f;
  } else if (desiredGain > 6.0f) {
    desiredGain = 6.0f;
  }
  smoothedGain = (0.85f * smoothedGain) + (0.15f * desiredGain);

  for (size_t i = 0; i < OUTPUT_SAMPLES_PER_PACKET; ++i) {
    int32_t amplified = static_cast<int32_t>(static_cast<float>(pcm16[i]) * smoothedGain);
    if (amplified > 30000) {
      amplified = 30000;
    } else if (amplified < -30000) {
      amplified = -30000;
    }
    pcm16[i] = static_cast<int16_t>(amplified);
  }

  packet[0] = 1;
  packet[1] = 0;
  packet[2] = static_cast<uint8_t>(packetSeq & 0xFF);
  packet[3] = static_cast<uint8_t>((packetSeq >> 8) & 0xFF);
  packet[4] = static_cast<uint8_t>(OUTPUT_SAMPLES_PER_PACKET & 0xFF);
  packet[5] = static_cast<uint8_t>((OUTPUT_SAMPLES_PER_PACKET >> 8) & 0xFF);
  memcpy(packet + AUDIO_HEADER_BYTES, pcm16, AUDIO_PAYLOAD_BYTES);

  if (!audioDataCharacteristic.notify(packet, sizeof(packet))) {
    static uint32_t lastNotifyFailureAt = 0;
    const uint32_t now = millis();
    if (now - lastNotifyFailureAt > 1000) {
      lastNotifyFailureAt = now;
      Serial.println("BLE notify backpressure detected");
    }
    return;
  }

  ++packetSeq;
}

void emitDiagnostics() {
  static uint32_t lastLogAt = 0;
  const uint32_t now = millis();
  if (now - lastLogAt < 5000) {
    return;
  }
  lastLogAt = now;

  if (pdmOverflowCount > 0) {
    Serial.print("PDM ring overflow count: ");
    Serial.println(pdmOverflowCount);
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("Starting MDBT42Q BLE mic + HUD display streamer");

  showBootScreen();
  setupBle();
  setupMic();
  queueDisplayText(currentDisplayText);
}

void loop() {
  flushDisplayIfNeeded();
  buildAndSendAudioPacket();
  emitDiagnostics();
  delay(1);
}
