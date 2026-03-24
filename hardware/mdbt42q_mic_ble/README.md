# MDBT42Q Mic BLE Streamer (PlatformIO)

This firmware ports the HUDini BLE microphone peripheral from the ESP32 to an
`MDBT42Q`-class nRF52832 target while keeping the iPhone app contract the same:

- Service UUID: `9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001`
- Audio data characteristic (Notify): `9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001`
- Control characteristic (Write / Write Without Response): `9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001`
- Status characteristic (Read / Notify): `9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001`

The packet format and `START` / `STOP` / `TEXT_*` commands match the existing
iOS app and the ESP32 firmware.

## Important hardware note

The ESP32 demo in `hardware/mic_to_bluetooth_testing` captures from an **I2S**
microphone. This nRF52832 port uses a **PDM** microphone because it is the most
reliable path on the `MDBT42Q` with the Arduino/Bluefruit stack.

That means:

- The iOS app behavior stays the same.
- The BLE protocol stays the same.
- The microphone hardware interface changes from `I2S` to `PDM` for this port.

If you must keep the exact same I2S mic breakout, an `nrfx_i2s` backend still
needs to be added for the MDBT42Q.

## Default pin assumptions

Update these in `src/main.cpp` to match your carrier board:

- `PDM_CLK` -> GPIO `2`
- `PDM_DIN` -> GPIO `3`

## Toolchain assumptions

The PlatformIO env targets `adafruit_feather_nrf52832` because it shares the
same `nRF52832` MCU family and Bluefruit stack. For a bare `MDBT42Q` module you
still need:

- a compatible bootloader or SWD flashing path
- pin remapping for your board
- final BLE throughput validation against an iPhone

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/mdbt42q_mic_ble`
3. Build once to install the Nordic toolchain:
   `PLATFORMIO_CORE_DIR=/tmp/pio-home pio run -e mdbt42q`

## Flash + monitor

How you flash depends on your `MDBT42Q` carrier/bootloader.

- If you have a Bluefruit-compatible serial bootloader:
  `PLATFORMIO_CORE_DIR=/tmp/pio-home pio run -e mdbt42q -t upload`
- To monitor logs:
  `PLATFORMIO_CORE_DIR=/tmp/pio-home pio device monitor -b 115200`

## Behavior

- Captures mono PDM audio at 16 kHz internally.
- Downsamples to 8 kHz mono PCM to preserve the current app contract.
- Sends 80 samples every 10 ms, matching the existing iOS BLE parser.
- Applies the same light DC removal and AGC shaping used by the ESP32 path.

## BLE throughput warning

This stream is intentionally aggressive for BLE notifications. The firmware
requests a short connection interval and high peripheral bandwidth, but you
should still validate on hardware:

- sustained notification success
- packet drops
- app-side transcript latency
- iPhone-negotiated MTU / connection interval

## Serial logs

When the app sends rendered text back over BLE, the firmware prints:

- `[BLE RX] TEXT_BEGIN`
- `[BLE RX] TEXT_END`
- `[BLE RX] <translated text>`

