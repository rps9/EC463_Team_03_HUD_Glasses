#include <Arduino.h>
#include <SPI.h>
#include <U8g2lib.h>

namespace {

constexpr uint8_t PIN_CS = 17;
constexpr uint8_t PIN_DC = 16;
constexpr uint8_t PIN_RST = 20;

constexpr size_t MAX_TEXT_LEN = 160;
constexpr uint8_t LINE_HEIGHT = 10;
constexpr uint8_t MAX_LINES = 6;

U8G2_SSD1306_128X64_NONAME_F_4W_HW_SPI display(U8G2_R0, PIN_CS, PIN_DC, PIN_RST);

String inputLine;
String currentText = "Type text in serial monitor";

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
  display.begin();
  display.clearBuffer();
  display.setFont(u8g2_font_5x7_tf);
  display.drawStr(0, 8, "HUDini display test");
  display.drawStr(0, 18, "Pico 2 W ready");
  display.drawStr(0, 28, "Send a line over USB");
  display.sendBuffer();
}

void handleCompletedLine(String line) {
  line.trim();
  if (line.isEmpty()) {
    return;
  }

  if (line.length() > MAX_TEXT_LEN) {
    line.remove(MAX_TEXT_LEN);
  }

  currentText = line;
  drawWrappedText(currentText);

  Serial.print("Displayed: ");
  Serial.println(currentText);
}

void pollSerial() {
  while (Serial.available()) {
    const char c = static_cast<char>(Serial.read());

    if (c == '\r') {
      continue;
    }

    if (c == '\n') {
      handleCompletedLine(inputLine);
      inputLine = "";
      continue;
    }

    if (inputLine.length() < MAX_TEXT_LEN) {
      inputLine += c;
    }
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(500);

  showBootScreen();
  Serial.println("HUDini display test ready");
  Serial.println("Send one line over serial to render it on the OLED");
}

void loop() {
  pollSerial();
}
