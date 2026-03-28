# Pico 2 W Display Test

This is a display-only firmware target for the Raspberry Pi Pico 2 W. It does
not use Bluetooth. It just drives the OLED over SPI and renders any line you
send over USB serial.

## Wiring

- `DIN` -> `GP19`
- `CLK` -> `GP18`
- `CS` -> `GP17`
- `DC` -> `GP16`
- `RST` -> `GP20`

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/display`
3. Build once:
   `pio run -e pico2w`

## Flash

Put the Pico 2 W into BOOTSEL mode, then run:

`pio run -e pico2w -t upload`

Or use the helper script:

`./run.sh`

## Monitor

Open the serial monitor:

`pio device monitor -b 115200`

## Test

Type a line into the serial monitor and press Enter. The firmware will:

- print `Displayed: <your text>` on serial
- wrap the text across the 128x64 OLED
- update the screen immediately

Example:

`hello from pico 2 w`
