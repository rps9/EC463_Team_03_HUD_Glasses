#include <Arduino.h>
#include <SPI.h>
#include <U8g2lib.h>
#include "driver/i2s.h"
#include "soc/i2s_reg.h"
#include "esp_log.h"
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include "esp_gap_ble_api.h"

#include <vector>

namespace {

static const i2s_port_t I2S_PORT = I2S_NUM_0;
// Mic runs at 16 kHz so BCLK stays at 1.024 MHz (SPH0645 datasheet floor).
// We then 2x-decimate in firmware to send 8 kHz on the wire — that halves
// notification bandwidth from ~260 kbit/s to ~130 kbit/s, which the ESP32
// BT controller TX queue can actually sustain. (At full 16 kHz the queue
// fills cyclically, dropping ~half of all packets — see iOS audio_seq logs
// before this change.)
static const int MIC_SAMPLE_RATE = 16000;
static const int STREAM_SAMPLE_RATE = 8000;
static const int DECIMATION = MIC_SAMPLE_RATE / STREAM_SAMPLE_RATE;

static const int PIN_I2S_BCLK = 26;
static const int PIN_I2S_LRCLK = 25;
static const int PIN_I2S_DIN = 34;

// Matches the actual wiring on this rig (also matches hardware/display/src/main.cpp,
// which is the known-working reference for this OLED).
static const int PIN_DISPLAY_MOSI = 23;  // DIN
static const int PIN_DISPLAY_CLK = 18;
static const int PIN_DISPLAY_CS = 22;
static const int PIN_DISPLAY_DC = 21;
static const int PIN_DISPLAY_RST = 17;

static const int PIN_RECORD_BUTTON = 27;
// GPIO 34-39 are input-only on ESP32. Use a real output pin (19 is free).
static const int PIN_RECORD_LED = 19;
static const unsigned long BUTTON_DEBOUNCE_MS = 45;

// SPH0645 only fills the top ~12 of its 24 bits at speech levels, so after
// `>>16` peaks land at ~2–3k int16 even on loud speech. Apply a fixed
// pre-gain so SFSpeechRecognizer sees a healthy 10–20k peak. Saturation
// (not AGC) handles loud sources — chosen empirically from log peaks.
static const float PCM_GAIN = 6.0f;

static const size_t MAX_FIELD_LEN = 2048;
static const uint8_t LINE_HEIGHT = 10;
static const uint8_t SCREEN_WIDTH = 128;
static const uint8_t MAX_VISIBLE_LINES = 6;
static const unsigned long SCROLL_LINE_INTERVAL_MS = 3000;
static const unsigned long CHUNK_TIMEOUT_MS = 10000;

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
uint16_t buttonEventSeq = 0;
volatile bool buttonEventPending = false;
volatile uint16_t pendingButtonSeq = 0;
float dcEstimate = 0.0f;
bool dcSettled = false;

// Rolling stats for the periodic [AUDIO] line. Reset on every emit so the
// numbers are window-local, not cumulative since boot.
uint32_t audioPeakAccum = 0;
uint64_t audioSumAbsAccum = 0;
uint32_t audioSamplesAccum = 0;
uint32_t audioRawClipAccum = 0;
uint32_t audioSilentWindows = 0;
uint32_t audioPacketsAccum = 0;

// Display state. The mux is held only across set/copy operations — never
// across U8g2 calls, heap allocations, or paints.
String captionText;                         // full final caption
String livePartial;                         // current partial (cleared on final)
String suggestionPhonetic;                  // "response:" content
String suggestionEnglish;                   // "response (english):" content
String statusBanner = "Waiting for BLE";    // shown when no real captions exist
uint16_t scrollOffset = 0;
unsigned long lastScrollAtMs = 0;
volatile bool displayDirty = true;
portMUX_TYPE displayMux = portMUX_INITIALIZER_UNLOCKED;

// Chunked downlink accumulator. Single slot — concurrent verbs would collide.
struct ChunkSlot {
  String verb;
  std::string buffer;
  unsigned long lastWriteMs = 0;
  bool active = false;
};
ChunkSlot chunkSlot;

bool lastButtonReading = HIGH;
bool stableButtonState = HIGH;
unsigned long lastButtonChangeMs = 0;

// ---- State mutators (caller must NOT hold the mux). ----

void clampToMax(String &s) {
  if (s.length() > MAX_FIELD_LEN) {
    s.remove(0, s.length() - MAX_FIELD_LEN);  // keep tail
  }
}

void setStatusBanner(const String &text) {
  String t = text;
  t.trim();
  portENTER_CRITICAL(&displayMux);
  statusBanner = t;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void applyCaptionFinal(const String &raw) {
  String text = raw;
  text.trim();
  clampToMax(text);
  portENTER_CRITICAL(&displayMux);
  captionText = text;
  livePartial = "";
  scrollOffset = 0;        // reset scroll on new content
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void applyCaptionPartial(const String &raw) {
  String text = raw;
  text.trim();
  clampToMax(text);
  portENTER_CRITICAL(&displayMux);
  livePartial = text;
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void applySuggestionPhonetic(const String &raw) {
  String text = raw;
  text.trim();
  clampToMax(text);
  portENTER_CRITICAL(&displayMux);
  suggestionPhonetic = text;
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void applySuggestionEnglish(const String &raw) {
  String text = raw;
  text.trim();
  clampToMax(text);
  portENTER_CRITICAL(&displayMux);
  suggestionEnglish = text;
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void resetCaption() {
  portENTER_CRITICAL(&displayMux);
  captionText = "";
  livePartial = "";
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void resetSuggestion() {
  portENTER_CRITICAL(&displayMux);
  suggestionPhonetic = "";
  suggestionEnglish = "";
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

void resetAll() {
  portENTER_CRITICAL(&displayMux);
  captionText = "";
  livePartial = "";
  suggestionPhonetic = "";
  suggestionEnglish = "";
  scrollOffset = 0;
  lastScrollAtMs = 0;
  displayDirty = true;
  portEXIT_CRITICAL(&displayMux);
}

// ---- Word-wrap (Frame-style accumulator, width-driven). ----
// Caller must NOT hold displayMux — this calls into U8g2.

uint16_t pixelWidth(const String &s) {
  return display.getStrWidth(s.c_str());
}

std::vector<String> wrapLines(const String &text, uint16_t screenWidth, size_t maxLines) {
  std::vector<String> out;
  if (text.length() == 0 || maxLines == 0) return out;

  String current;
  bool truncated = false;

  int start = 0;
  while (start <= (int)text.length()) {
    int sp = text.indexOf(' ', start);
    int end = (sp < 0) ? text.length() : sp;
    String word = text.substring(start, end);
    start = (sp < 0) ? text.length() + 1 : sp + 1;

    if (word.length() == 0) continue;

    while (pixelWidth(word) > screenWidth) {
      if (current.length() > 0) {
        out.push_back(current);
        current = "";
        if (out.size() >= maxLines) { truncated = true; break; }
      }
      int fit = word.length();
      while (fit > 1 && pixelWidth(word.substring(0, fit) + "-") > screenWidth) {
        --fit;
      }
      if (fit < 1) fit = 1;
      out.push_back(word.substring(0, fit) + "-");
      word = word.substring(fit);
      if (out.size() >= maxLines) { truncated = true; break; }
    }
    if (truncated) break;
    if (word.length() == 0) continue;

    String candidate = current.length() == 0 ? word : current + " " + word;
    if (pixelWidth(candidate) <= screenWidth) {
      current = candidate;
    } else {
      if (current.length() > 0) {
        out.push_back(current);
        if (out.size() >= maxLines) { truncated = true; break; }
      }
      current = word;
    }
  }

  if (!truncated && current.length() > 0) {
    if (out.size() < maxLines) {
      out.push_back(current);
    } else {
      truncated = true;
    }
  }

  if (truncated && !out.empty()) {
    String &last = out.back();
    while (last.length() > 0 && pixelWidth(last + "...") > screenWidth) {
      last.remove(last.length() - 1);
    }
    last = last + "...";
  }
  return out;
}

// ---- Render path. ----

struct Snapshot {
  String captionText;
  String livePartial;
  String suggestionPhonetic;
  String suggestionEnglish;
  String statusBanner;
  uint16_t scrollOffset;
  bool dirty;
};

Snapshot takeSnapshot() {
  Snapshot s;
  portENTER_CRITICAL(&displayMux);
  s.captionText = captionText;
  s.livePartial = livePartial;
  s.suggestionPhonetic = suggestionPhonetic;
  s.suggestionEnglish = suggestionEnglish;
  s.statusBanner = statusBanner;
  s.scrollOffset = scrollOffset;
  s.dirty = displayDirty;
  displayDirty = false;
  portEXIT_CRITICAL(&displayMux);
  return s;
}

std::vector<String> buildRenderLines(const Snapshot &s) {
  std::vector<String> out;

  bool hasCaptionContent = s.captionText.length() > 0 || s.livePartial.length() > 0;

  if (hasCaptionContent) {
    out.push_back("translation:");
    String active = s.livePartial.length() > 0 ? s.livePartial : s.captionText;
    auto wrapped = wrapLines(active, SCREEN_WIDTH, 256);
    for (auto &l : wrapped) out.push_back(l);
  } else if (s.statusBanner.length() > 0) {
    auto wrapped = wrapLines(s.statusBanner, SCREEN_WIDTH, MAX_VISIBLE_LINES);
    for (auto &l : wrapped) out.push_back(l);
  }

  if (s.suggestionPhonetic.length() > 0) {
    out.push_back("response:");
    auto wrapped = wrapLines(s.suggestionPhonetic, SCREEN_WIDTH, 256);
    for (auto &l : wrapped) out.push_back(l);
  }

  if (s.suggestionEnglish.length() > 0) {
    out.push_back("response (english):");
    auto wrapped = wrapLines(s.suggestionEnglish, SCREEN_WIDTH, 256);
    for (auto &l : wrapped) out.push_back(l);
  }

  return out;
}

void paint(const std::vector<String> &lines, uint16_t offset) {
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);

  uint8_t y = LINE_HEIGHT - 2;
  size_t end = std::min<size_t>(lines.size(), (size_t)offset + MAX_VISIBLE_LINES);
  for (size_t i = offset; i < end; ++i) {
    display.drawStr(0, y, lines[i].c_str());
    y += LINE_HEIGHT;
  }
  display.sendBuffer();
}

void flushDisplayIfNeeded() {
  Snapshot s = takeSnapshot();

  // Build lines outside any critical section. wrapLines calls U8g2.
  std::vector<String> lines = buildRenderLines(s);
  size_t total = lines.size();
  uint16_t target = total > MAX_VISIBLE_LINES ? (uint16_t)(total - MAX_VISIBLE_LINES) : 0;

  bool needsPaint = s.dirty;
  unsigned long now = millis();

  // Reconcile scroll under the lock so it stays consistent with target.
  portENTER_CRITICAL(&displayMux);
  if (scrollOffset > target) {
    scrollOffset = target;
    needsPaint = true;
  }
  if (scrollOffset < target) {
    if (lastScrollAtMs == 0) lastScrollAtMs = now;
    if (now - lastScrollAtMs >= SCROLL_LINE_INTERVAL_MS) {
      scrollOffset++;
      lastScrollAtMs = now;
      needsPaint = true;
    }
    // Keep dirty so the next loop tick re-checks the timer.
    displayDirty = true;
  } else {
    lastScrollAtMs = 0;
  }
  uint16_t paintOffset = scrollOffset;
  portEXIT_CRITICAL(&displayMux);

  if (needsPaint) {
    paint(lines, paintOffset);
  }
}

void showBootScreen() {
  SPI.begin(PIN_DISPLAY_CLK, -1, PIN_DISPLAY_MOSI, PIN_DISPLAY_CS);
  display.begin();
  // Drop SPI bus clock for noisy breadboard wiring (default is ~8 MHz).
  display.setBusClock(1000000);

  // Step 1: fill the entire screen white. If the OLED is alive at all, you
  // see a fully lit panel for ~600 ms. This rules out "is the panel even
  // talking SPI?" before we worry about text rendering.
  display.clearBuffer();
  display.drawBox(0, 0, 128, 64);
  display.sendBuffer();
  delay(600);

  // Step 2: clear it (panel goes black for ~300 ms).
  display.clearBuffer();
  display.sendBuffer();
  delay(300);

  // Step 3: normal boot text.
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);
  display.drawStr(0, 8, "HUDini ESP32");
  display.drawStr(0, 18, "BLE mic + display");
  display.drawStr(0, 28, "Mic: B26 W25 D34 16k");
  display.drawStr(0, 38, "OLED: S18 M23 CS5");
  display.drawStr(0, 48, "DC21 RST22");
  display.sendBuffer();
}

// ---- BLE ----

bool notificationsEnabled(BLECharacteristic *characteristic) {
  if (characteristic == nullptr) return false;
  BLEDescriptor *cccd = characteristic->getDescriptorByUUID(BLEUUID((uint16_t)0x2902));
  if (cccd == nullptr) return false;
  BLE2902 *descriptor2902 = static_cast<BLE2902 *>(cccd);
  return descriptor2902->getNotifications();
}

void notifyStatus(const char *status) {
  if (statusCharacteristic == nullptr) return;
  statusCharacteristic->setValue(status);
  if (notificationsEnabled(statusCharacteristic)) {
    statusCharacteristic->notify();
  }
}

// The audio characteristic notifies every ~7 ms and the ESP32 BT controller
// has a fixed-depth TX queue. With audio always first in line, calling
// notify() on the status characteristic from inside an interrupt-y press
// path landed on a full queue and got silently dropped (NO_MEM). Instead
// the press sets a pending flag here and the main loop drains the button
// event before it kicks off the next i2s_read — at which point the queue
// is at its emptiest and the notify is guaranteed to land.
void flushButtonEventIfPending() {
  if (!buttonEventPending) return;
  if (statusCharacteristic == nullptr) {
    buttonEventPending = false;
    return;
  }
  uint16_t seq = pendingButtonSeq;
  buttonEventPending = false;

  char payload[24];
  snprintf(payload, sizeof(payload), "MIC_REQUEST:%u", (unsigned)seq);
  statusCharacteristic->setValue((uint8_t *)payload, strlen(payload));
  if (notificationsEnabled(statusCharacteristic)) {
    statusCharacteristic->notify();
  }
}

void setStreamEnabled(bool enabled, const char *bannerText, const char *statusText) {
  streamEnabled = enabled;
  if (enabled) {
    packetSeq = 0;
    dcEstimate = 0.0f;
    dcSettled = false;
    audioPeakAccum = 0;
    audioSumAbsAccum = 0;
    audioSamplesAccum = 0;
    audioRawClipAccum = 0;
    audioSilentWindows = 0;
    audioPacketsAccum = 0;
    Serial.println("[AUDIO] stream START — Frame-style 8-bit pipeline");
  } else {
    Serial.printf("[AUDIO] stream STOP — final packetSeq=%u\n", (unsigned)packetSeq);
  }
  digitalWrite(PIN_RECORD_LED, enabled ? HIGH : LOW);
  setStatusBanner(bannerText);
  notifyStatus(statusText);
}

class MicServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    (void)server;
    deviceConnected = true;

    // Without this we sit at iOS's default 30 ms conn interval, which can't
    // sustain ~260 kbit/s of audio notifications on 1M PHY. The ESP32 BT
    // controller TX queue fills up and silently drops notifies — visible in
    // iOS logs as regular ~25-packet gaps every ~330 ms, eventually tripping
    // supervision timeout and killing the link. 15-20 ms doubles event rate.
    // (2M PHY would help further but isn't enabled in arduino-esp32 v2.x.)
    esp_ble_conn_update_params_t conn_params = {};
    memcpy(conn_params.bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
    conn_params.min_int = 0x0c;  // 15 ms (1.25 ms units)
    conn_params.max_int = 0x10;  // 20 ms
    conn_params.latency = 0;
    conn_params.timeout = 400;   // 4 s (10 ms units)
    esp_err_t cpRes = esp_ble_gap_update_conn_params(&conn_params);
    Serial.printf("[BLE] update_conn_params(15-20 ms) -> %d\n", (int)cpRes);

    setStatusBanner("BLE connected");
    notifyStatus("Connected");
  }

  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    setStreamEnabled(false, "BLE disconnected", "Disconnected");
    server->startAdvertising();
  }
};

// ---- Command parsing ----

bool startsWith(const std::string &s, const char *prefix) {
  size_t pl = strlen(prefix);
  return s.length() >= pl && s.compare(0, pl, prefix) == 0;
}

void dispatchVerb(const String &verb, const String &payload) {
  if (verb == "CAPTION:final") {
    Serial.printf("[BLE RX] CAPTION:final %u chars\n", (unsigned)payload.length());
    applyCaptionFinal(payload);
  } else if (verb == "CAPTION:partial") {
    applyCaptionPartial(payload);
  } else if (verb == "SUGGEST_PH") {
    Serial.printf("[BLE RX] SUGGEST_PH %u chars\n", (unsigned)payload.length());
    applySuggestionPhonetic(payload);
  } else if (verb == "SUGGEST_EN") {
    Serial.printf("[BLE RX] SUGGEST_EN %u chars\n", (unsigned)payload.length());
    applySuggestionEnglish(payload);
  } else {
    Serial.print("[BLE RX] unknown verb: ");
    Serial.println(verb);
  }
}

class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string value = characteristic->getValue();
    if (value.empty()) return;

    // Drop stranded chunk slot if it's gone stale.
    if (chunkSlot.active && (millis() - chunkSlot.lastWriteMs) > CHUNK_TIMEOUT_MS) {
      Serial.println("[BLE RX] chunk slot timeout, dropping");
      chunkSlot = ChunkSlot{};
    }

    if (value == "START" || value == "start") {
      setStreamEnabled(true, "Streaming audio", "Streaming");
      return;
    }
    if (value == "STOP" || value == "stop") {
      setStreamEnabled(false, "Stream stopped", "Stopped");
      return;
    }

    if (value == "CLEAR:caption") { resetCaption(); return; }
    if (value == "CLEAR:suggestion") { resetSuggestion(); return; }
    if (value == "CLEAR:all") { resetAll(); setStatusBanner("Waiting for BLE"); return; }

    auto tryVerb = [&](const char *verbCstr) -> bool {
      size_t vl = strlen(verbCstr);
      if (value.length() > vl + 1 && value.compare(0, vl, verbCstr) == 0 && value[vl] == ':') {
        String payload = String(value.substr(vl + 1).c_str());
        dispatchVerb(String(verbCstr), payload);
        return true;
      }
      return false;
    };
    if (tryVerb("CAPTION:final")) return;
    if (tryVerb("CAPTION:partial")) return;
    if (tryVerb("SUGGEST_PH")) return;
    if (tryVerb("SUGGEST_EN")) return;

    if (startsWith(value, "CHUNK_BEGIN:")) {
      chunkSlot = ChunkSlot{};
      chunkSlot.verb = String(value.substr(strlen("CHUNK_BEGIN:")).c_str());
      chunkSlot.active = true;
      chunkSlot.lastWriteMs = millis();
      return;
    }
    if (startsWith(value, "CHUNK:")) {
      if (!chunkSlot.active) {
        Serial.println("[BLE RX] CHUNK without BEGIN, ignoring");
        return;
      }
      chunkSlot.buffer.append(value.substr(strlen("CHUNK:")));
      chunkSlot.lastWriteMs = millis();
      if (chunkSlot.buffer.size() > MAX_FIELD_LEN * 2) {
        chunkSlot.buffer.resize(MAX_FIELD_LEN * 2);
      }
      return;
    }
    if (value == "CHUNK_END") {
      if (!chunkSlot.active) return;
      String payload = String(chunkSlot.buffer.c_str());
      String verb = chunkSlot.verb;
      chunkSlot = ChunkSlot{};
      dispatchVerb(verb, payload);
      return;
    }

    Serial.print("[BLE RX] unknown command: ");
    Serial.println(value.c_str());
  }
};

// ---- I/O setup ----

void setupI2S() {
  i2s_config_t i2s_config = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = MIC_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 256,
      // APLL gives a clean BCLK at 16 kHz; the default PLL divider is jittery.
      .use_apll = true,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0};

  i2s_pin_config_t pin_config = {
      .bck_io_num = PIN_I2S_BCLK,
      .ws_io_num = PIN_I2S_LRCLK,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = PIN_I2S_DIN};

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  // Espressif workaround for the SPH0645 BCLK dropout between DMA refills:
  // forces the I2S peripheral to keep BCLK driven and corrects MSB shift.
  REG_SET_BIT(I2S_TIMING_REG(I2S_PORT), BIT(9));
  REG_SET_BIT(I2S_CONF_REG(I2S_PORT), I2S_RX_MSB_SHIFT);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setupRecordControls() {
  pinMode(PIN_RECORD_BUTTON, INPUT_PULLUP);
  pinMode(PIN_RECORD_LED, OUTPUT);
  digitalWrite(PIN_RECORD_LED, LOW);
  lastButtonReading = digitalRead(PIN_RECORD_BUTTON);
  stableButtonState = lastButtonReading;
  lastButtonChangeMs = millis();
}

void pollRecordButton() {
  const bool reading = digitalRead(PIN_RECORD_BUTTON);
  const unsigned long now = millis();

  if (reading != lastButtonReading) {
    lastButtonReading = reading;
    lastButtonChangeMs = now;
  }

  if ((now - lastButtonChangeMs) < BUTTON_DEBOUNCE_MS || reading == stableButtonState) {
    return;
  }

  stableButtonState = reading;
  if (stableButtonState == LOW) {
    buttonEventSeq++;
    pendingButtonSeq = buttonEventSeq;
    buttonEventPending = true;
    Serial.printf("[BUTTON] BTN_REC pressed (seq %u)\n", (unsigned)buttonEventSeq);
  }
}

void setupBLE() {
  BLEDevice::init("HUDini-Mic");
  BLEDevice::setMTU(247);

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
  Serial.println("[BOOT] Starting BLE mic + HUD display streamer");
  esp_log_level_set("BLECharacteristic", ESP_LOG_NONE);
  esp_log_level_set("BLE2902", ESP_LOG_NONE);

  Serial.println("[BOOT] setupRecordControls...");
  setupRecordControls();
  Serial.println("[BOOT] setupBLE...");
  setupBLE();
  Serial.println("[BOOT] setupI2S...");
  setupI2S();
  Serial.println("[BOOT] showBootScreen (display.begin)...");
  showBootScreen();
  Serial.println("[BOOT] display ok");
  setStatusBanner("Waiting for BLE");
  Serial.println("[BOOT] ready");
}

void loopFirmware() {
  flushDisplayIfNeeded();
  pollRecordButton();
  // Run before any audio TX so the BLE controller queue is at its
  // emptiest when the status notification is enqueued.
  flushButtonEventIfPending();

  if (!deviceConnected || !streamEnabled || audioDataCharacteristic == nullptr) {
    delay(10);
    return;
  }

  if (!notificationsEnabled(audioDataCharacteristic)) {
    delay(10);
    return;
  }

  // Frame-style philosophy (NO AGC, NO HP filter), int16 wire format.
  // Mic runs at 16 kHz; we average each adjacent pair of samples (2-tap
  // boxcar AA filter) and decimate by 2 to produce 8 kHz on the wire.
  // SFSpeechRecognizer is fine with 8 kHz — telephone-band speech.
  //
  // Wire format: [ver=1][bitDepth=16][seq_lo][seq_hi][count_lo][count_hi][int16 PCM × count]
  // OUT_N=116 samples × 2 B + 6 B header = 238 B (≤244 B ATT payload at MTU 247).
  // 116 @ 8 kHz = 14.5 ms per packet → ~69 pkts/s, ~131 kbit/s on the wire.
  const int OUT_N = 116;
  const int IN_N = OUT_N * DECIMATION;
  int32_t i2sSamples[IN_N];
  int16_t pcm16[OUT_N];
  uint8_t packet[6 + (OUT_N * sizeof(int16_t))];

  size_t bytesRead = 0;
  esp_err_t readErr = i2s_read(I2S_PORT, (void *)i2sSamples, sizeof(i2sSamples), &bytesRead, portMAX_DELAY);
  if (readErr != ESP_OK) {
    Serial.printf("[AUDIO] i2s_read err=%d (0x%x)\n", (int)readErr, (unsigned)readErr);
    return;
  }

  int inCount = bytesRead / sizeof(int32_t);
  if (inCount <= 0) return;
  if (inCount > IN_N) inCount = IN_N;
  int count = inCount / DECIMATION;  // output sample count
  if (count <= 0) return;
  if (count != OUT_N) {
    Serial.printf("[AUDIO] short read: in=%d out=%d (expected %d/%d)\n",
                  inCount, count, IN_N, OUT_N);
  }

  // dcEstimate tracks at the int16 scale (post-`>>16`). Seed from the first
  // DMA buffer after START so the SPH0645's large DC bias doesn't bleed
  // into the first ~100 ms.
  if (!dcSettled) {
    int64_t sum = 0;
    for (int i = 0; i < inCount; i++) sum += (i2sSamples[i] >> 16);
    dcEstimate = (float)((double)sum / (double)inCount);
    dcSettled = true;
    Serial.printf("[AUDIO] DC seeded from %d samples: dcEstimate=%.0f (int16 scale)\n",
                  inCount, dcEstimate);
  }

  // Per-output-sample: average the adjacent 16 kHz pair (anti-alias),
  // subtract slow-tracking DC, apply fixed pre-gain, saturate to int16.
  int32_t sumAbs = 0;
  int32_t peakAbs = 0;
  int clipCount = 0;
  for (int i = 0; i < count; i++) {
    int32_t a16 = i2sSamples[i * 2]     >> 16;
    int32_t b16 = i2sSamples[i * 2 + 1] >> 16;
    int32_t avg = (a16 + b16) >> 1;
    dcEstimate += 0.001f * ((float)avg - dcEstimate);
    float centered = ((float)avg - dcEstimate) * PCM_GAIN;
    int32_t s = (int32_t)centered;
    if (s > 32767)  { s = 32767;  clipCount++; }
    if (s < -32768) { s = -32768; clipCount++; }
    pcm16[i] = (int16_t)s;
    int32_t mag = (s < 0) ? -s : s;
    sumAbs += mag;
    if (mag > peakAbs) peakAbs = mag;
  }

  // Periodic [AUDIO] diagnostic line. Fields at int16 scale (-32768..32767):
  //   peak: max |sample| in window (≥1500 audible, ≥10000 loud, ≥30000 clipping)
  //   avg:  mean |sample| in window (typical speech: 500–3000)
  //   dc:   slow-tracking DC estimate at int16 scale; should drift slowly
  //   clip: % of samples saturated (≥1% = signal too hot)
  //   sil:  % of packets whose avg was < 50 (true silence)
  audioPeakAccum = max(audioPeakAccum, (uint32_t)peakAbs);
  audioSumAbsAccum += (uint64_t)sumAbs;
  audioSamplesAccum += (uint32_t)count;
  audioRawClipAccum += (uint32_t)clipCount;
  if (count > 0 && (sumAbs / count) < 50) audioSilentWindows++;
  audioPacketsAccum++;

  if (audioPacketsAccum >= 128) {  // ~1.9 s at ~69 pkts/sec (8 kHz wire)
    uint32_t windowAvg = audioSamplesAccum > 0
        ? (uint32_t)(audioSumAbsAccum / audioSamplesAccum) : 0;
    float clipPct = audioSamplesAccum > 0
        ? (100.0f * (float)audioRawClipAccum / (float)audioSamplesAccum) : 0.0f;
    float silPct = (100.0f * (float)audioSilentWindows / (float)audioPacketsAccum);
    Serial.printf(
        "[AUDIO] pkts=%u peak=%u avg=%u dc=%d clip=%.1f%% sil=%.0f%%\n",
        (unsigned)packetSeq, (unsigned)audioPeakAccum, (unsigned)windowAvg,
        (int)dcEstimate, clipPct, silPct);
    audioPeakAccum = 0;
    audioSumAbsAccum = 0;
    audioSamplesAccum = 0;
    audioRawClipAccum = 0;
    audioSilentWindows = 0;
    audioPacketsAccum = 0;
  }

  packet[0] = 1;        // protocol version
  packet[1] = 16;       // bit depth (16 = int16 signed PCM)
  packet[2] = (uint8_t)(packetSeq & 0xFF);
  packet[3] = (uint8_t)((packetSeq >> 8) & 0xFF);
  packet[4] = (uint8_t)(count & 0xFF);
  packet[5] = (uint8_t)((count >> 8) & 0xFF);

  memcpy(packet + 6, pcm16, count * sizeof(int16_t));

  audioDataCharacteristic->setValue(packet, 6 + (count * sizeof(int16_t)));
  audioDataCharacteristic->notify();

  packetSeq++;

  // Bluedroid runs inbound writes and outbound notifies through a single
  // BTC task. Hammering notify() at 69 Hz starves the BTC task of cycles to
  // service inbound — STOP and SUGGEST_PH/EN writes get queued and dropped,
  // the link goes unidirectional, and ~10 s later iOS supervision-timeouts
  // and disconnects. Stepping aside for ~3 ms every 8 packets gives BTC a
  // guaranteed window to process inbound. Audio cost: ~3 ms / (8 × 14.5 ms)
  // ≈ 2.6 % wire-rate slowdown — well within budget.
  if ((packetSeq & 0x07) == 0) {
    vTaskDelay(pdMS_TO_TICKS(3));
  } else {
    taskYIELD();
  }
}

}  // namespace

void setup() {
  setupFirmware();
}

void loop() {
  loopFirmware();
}
