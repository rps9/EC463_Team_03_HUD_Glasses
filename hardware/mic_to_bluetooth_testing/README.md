# ESP32 Mic BLE Streamer (PlatformIO)

This firmware captures audio from the I2S microphone and streams PCM audio over BLE to the iPhone app.

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/mic_to_bluetooth_testing`
3. Build once to install toolchains:
   `pio run -e esp32dev`

## Flash + run

`./run.sh`

If auto-detection fails, pass serial port explicitly:

`./run.sh /dev/cu.usbserial-0001`

## BLE protocol (matches iOS app)

- Service UUID: `9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001`
- Audio data characteristic (Notify): `9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001`
- Control characteristic (Write): `9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001`
- Status characteristic (Read/Notify): `9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001`

Control commands:
- `START`
- `STOP`

Audio packet format sent in notifications:
- byte 0: protocol version (`1`)
- byte 1: flags (`0` for now)
- byte 2-3: packet sequence (`uint16`, little endian)
- byte 4-5: sample count (`uint16`, little endian)
- bytes 6+: `int16` PCM mono payload (8kHz)
