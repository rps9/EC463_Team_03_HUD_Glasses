# MDBT42Q Mic + HUD BLE Test

This folder is the `MDBT42Q` / `nRF52832` port of
`hardware/mic_display_bluetooth_testing`.

It keeps the same app-facing behavior as the ESP32 firmware:

- streams mono PCM audio to the iPhone app over BLE
- receives rendered text back from the app over the BLE control characteristic
- logs returned text on serial
- renders that returned text on the HUD OLED
- preserves the same BLE UUIDs, packet header, and `START` / `STOP` / `TEXT_*`
  control commands

## Important hardware difference

The original ESP32 firmware uses an **I2S** microphone.

This `MDBT42Q` port uses a **PDM** microphone input instead. The BLE behavior,
packet format, and OLED behavior stay the same, but the microphone wiring does
not. This keeps the port practical on the nRF52832 Arduino/Bluefruit stack.

If you must keep the exact same I2S microphone breakout, this project still
needs a dedicated `nrfx_i2s` capture backend.

## Wiring

The Raytac module exposes Nordic GPIO names like `P0.02`, `P0.13`, etc. Use
those labels on your board.

Raytac’s MDBT42Q spec shows the module supports both `PDM` and `I2S`, and it
also warns that `P0.22` through `P0.30` should only be used for low-frequency
I/O, so this pin map avoids those pins for the display bus.

Sources:

- Raytac MDBT42Q-DB-32 product page: https://www.raytac.com/product/ins.php?index_id=82
- Raytac MDBT42Q-512KV2 spec PDF: https://www.raytac.com/download/index.php?index_id=27

### PDM microphone

- `VCC` -> `3V3`
- `GND` -> `GND`
- `CLK` -> `P0.02`
- `DAT` / `DOUT` -> `P0.03`

### OLED HUD display (SSD1306 SPI)

- `VCC` -> `3V3`
- `GND` -> `GND`
- `DIN` / `MOSI` -> `P0.14`
- `CLK` / `SCK` -> `P0.13`
- `CS` -> `P0.15`
- `DC` -> `P0.16`
- `RST` -> `P0.17`

### Optional serial logging

If your MDBT42Q carrier exposes UART or RTT logging, connect that per your
carrier/debugger. This folder leaves the standard Arduino `Serial` logging calls
in place, but raw MDBT42Q boards do not provide USB serial by themselves.

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/mdbt42q_mic_display_ble`
3. Build once to install the Nordic toolchain:
   `PLATFORMIO_CORE_DIR=/tmp/pio-home pio run -e mdbt42q`

## Flash + run

This environment is configured for `J-Link` upload because the exact Raytac
board is an nRF52832 module board, not an ESP32-style USB flash target.

- Flash:
  `./run.sh`
- Flash and monitor an external USB-UART adapter:
  `./run.sh /dev/cu.usbserial-0001`

## Expected behavior

After boot:

- the OLED shows a boot screen and pin summary
- the board advertises as `HUDini-Mic`
- the iPhone app can connect and start audio streaming as before
- when the app sends translated/rendered text back using `TEXT_BEGIN`,
  `TEXT_CHUNK:*`, and `TEXT_END`, the firmware:
  - prints it to serial
  - wraps it across the 128x64 OLED

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
