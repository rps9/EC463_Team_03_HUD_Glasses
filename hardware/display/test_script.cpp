#include <U8g2lib.h>
#include <SPI.h>

// Your wiring
// DIN  -> GP19
// CLK  -> GP18
// CS   -> GP17
// DC   -> GP16
// RST  -> GP20

#define PIN_CS   17
#define PIN_DC   16
#define PIN_RST  20

// Use SSD1306 driver (works with your Waveshare board and avoids the SSD1309 constructor issue)
U8G2_SSD1306_128X64_NONAME_F_4W_HW_SPI u8g2(
  U8G2_R0,
  PIN_CS,
  PIN_DC,
  PIN_RST
);

String line = "";

void setup() {
  Serial.begin(115200);

  u8g2.begin();
  u8g2.setFont(u8g2_font_5x7_tf);   // very small font
  u8g2.clearBuffer();
  u8g2.drawStr(0, 8, "Type text:");
  u8g2.sendBuffer();
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();

    if (c == '\n' || c == '\r') {

      u8g2.clearBuffer();
      u8g2.setFont(u8g2_font_5x7_tf);
      u8g2.drawStr(0, 8, line.c_str());
      u8g2.sendBuffer();

      line = "";
    } else {
      line += c;
    }
  }
}