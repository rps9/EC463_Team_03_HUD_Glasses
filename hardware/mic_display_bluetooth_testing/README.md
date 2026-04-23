# ESP32 Mic + HUD BLE Test

This firmware combines the current `mic_to_bluetooth_testing` BLE microphone
stream with the OLED HUD display path, all on one ESP32.

The ESP32 still:

- streams PCM audio to the iPhone app over BLE
- receives rendered text back from the app over the BLE control characteristic
- logs the returned text on serial
- renders that returned text on the HUD OLED

## Wiring

### I2S microphone

- `VCC` -> `3V3`
- `GND` -> `GND`
- `SCK` / `BCLK` -> `GPIO26`
- `WS` / `LRCLK` -> `GPIO25`
- `SD` / `DOUT` -> `GPIO33`

### OLED HUD display (SSD1306 SPI)

- `VCC` -> `3V3`
- `GND` -> `GND`
- `DIN` / `MOSI` -> `GPIO23`
- `CLK` / `SCK` -> `GPIO18`
- `CS` -> `GPIO5`
- `DC` -> `GPIO21`
- `RST` -> `GPIO22`

Notes:

- `MISO` is not used by this display.
- If your OLED has no `CS` pin and is hard-wired for SPI, this target is not the
  right one without editing the display constructor.
- Keep the microphone and OLED grounds tied to the same ESP32 ground.

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/mic_display_bluetooth_testing`
3. Build once to install toolchains:
   `pio run -e esp32dev`

## Flash + run

`./run.sh`

If auto-detection fails, pass serial port explicitly:

`./run.sh /dev/cu.usbserial-0001`

## Expected behavior

After boot:

- the OLED shows a boot screen and pin summary
- the ESP32 advertises as `HUDini-Mic`
- the iPhone app can connect and start audio streaming as before
- when the app sends translated/rendered text back using `TEXT_BEGIN`,
  `TEXT_CHUNK:*`, and `TEXT_END`, the ESP32:
  - prints it to serial
  - wraps it across the 128x64 OLED

Serial examples:

- `[BLE RX] TEXT_BEGIN`
- `[BLE RX] TEXT_END`
- `[BLE RX] hello from the app`

## BLE protocol

- Service UUID: `9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001`
- Audio data characteristic (Notify): `9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001`
- Control characteristic (Write): `9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001`
- Status characteristic (Read/Notify): `9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001`

Control commands:

- `START`
- `STOP`
- `TEXT_BEGIN`
- `TEXT_CHUNK:<utf8 text>`
- `TEXT_END`
- `TEXT:<utf8 text>`
