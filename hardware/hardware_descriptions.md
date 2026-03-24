# Hardware Notes

## ESP32 path

- `hardware/mic_to_bluetooth_testing` is the original ESP32 BLE microphone path.
- It uses an I2S MEMS microphone and ESP32-specific BLE/I2S APIs.

## MDBT42Q path

- `hardware/mdbt42q_mic_ble` is the nRF52832 / MDBT42Q BLE microphone port.
- It preserves the BLE UUIDs, control commands, and packet format expected by the iOS app.
- It currently targets a PDM microphone on the Nordic side to keep the port practical on the Bluefruit/Arduino stack.
- If the exact same I2S microphone breakout must be retained, an `nrfx_i2s` capture backend still needs to be added for the MDBT42Q firmware.
