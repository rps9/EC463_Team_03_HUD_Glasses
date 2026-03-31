# ESP32 BLE HUD Display

This folder is now the display-only ESP32 target.

It does not stream microphone audio. It only:

- drives the SSD1306 HUD OLED over SPI
- advertises a BLE service compatible with the app's existing HUD text send path
- receives `TEXT_BEGIN`, `TEXT_CHUNK:*`, `TEXT_END`, and `TEXT:*`
- renders the received text on the display
- logs the received text on serial for debugging

The intended flow is:

- the phone uses its own microphone
- the app transcribes and/or translates on the phone
- the app sends the final text back to this ESP32 display peripheral over BLE

## Wiring

- OLED `VCC` -> `3V3`
- OLED `GND` -> `GND`
- OLED `DIN` / `MOSI` -> `GPIO23`
- OLED `CLK` / `SCK` -> `GPIO18`
- OLED `CS` -> `GPIO5`
- OLED `DC` -> `D21` (`GPIO21`)
- OLED `RST` -> `D22` (`GPIO22`)

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/display`
3. Build once:
   `pio run -e esp32dev`

## Flash + monitor

`./run.sh`

If auto-detection fails:

`./run.sh /dev/cu.usbserial-0001`

## BLE protocol

- Device name: `HUDini-Display`
- Service UUID: `9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001`
- Audio characteristic UUID: `9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001`
- Control characteristic UUID: `9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001`
- Status characteristic UUID: `9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001`

Notes:

- On most ESP32 DevKit-style boards, `D23`, `D22`, `D21`, `D18`, and `D5`
  match `GPIO23`, `GPIO22`, `GPIO21`, `GPIO18`, and `GPIO5`.
- Some boards label `GPIO16` and `GPIO17` as `RX2` and `TX2` instead of `D16`
  and `D17`, which is why this display target avoids those pins.
- The audio characteristic is present only so the current app discovery path still recognizes the peripheral.
- This firmware does not send microphone packets.
- The app should use the phone mic path and send returned text over the BLE control characteristic.
