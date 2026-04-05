# HUDini Frame App

This directory contains the Frame-side HUDini app implemented in Lua.

It is designed around the host/device split described in `FRAME_NOTES.txt`:

- Frame handles microphone capture, on-device rendering, tap gestures, and saved display preferences.
- The iPhone app remains the host for speech recognition, translation, suggestions, and BLE orchestration.

## Files

- `main.lua`: the Frame app entry point. If installed as `/main.lua`, Frame will start it automatically after reset or reboot.

## What the Lua app does

- Streams 8 kHz / 16-bit mono microphone audio to the phone.
- Renders partial captions and final captions with separate colors.
- Stores display preferences in `/hudini/prefs.txt`.
- Shows up to 3 suggestions and lets the wearer cycle them with a tap.
- Tracks device states like `disconnected`, `listening`, `translating`, `muted`, and `idle`.

## Host protocol

After the Frame app is running, the host should communicate with it using raw BLE payloads on the Frame TX characteristic. Each host message is UTF-8 text with tab-separated fields.

Commands from phone to Frame:

- `PING`
- `SET_STATE\t<status>`
- `SET_MODE\t<translation|transcription|meeting|pronunciation>`
- `SET_PREFS\tbrightness=1;partials=1;position=bottom;layout=focus;transcription_color=GREY;translation_color=SKYBLUE`
- `SHOW_TRANSCRIPT\t<text>`
- `SHOW_CAPTION\tpartial\t<text>`
- `SHOW_CAPTION\tfinal\t<text>`
- `CLEAR_CAPTION`
- `SHOW_SUGGESTIONS\t<text~phonetic>\t<text~phonetic>\t<text~phonetic>`
- `CLEAR_SUGGESTIONS`
- `CYCLE_SUGGESTIONS`
- `MUTE\t0|1`
- `MIC_START`
- `MIC_STOP`

Events from Frame to phone:

- `EVT\tBOOT\t<firmwareVersion>\t<maxPayloadBytes>`
- `EVT\tREADY\t<firmwareVersion>\t<maxPayloadBytes>`
- `EVT\tSTATUS\t<status>`
- `EVT\tMODE\t<mode>`
- `EVT\tPREFS_SAVED`
- `EVT\tSUGGESTION_INDEX\t<1-3>`
- `EVT\tTAP\tcycle`

Audio packets from Frame to phone are binary:

- Byte `0`: `0x20`
- Bytes `1-2`: little-endian sequence number
- Remaining bytes: signed little-endian PCM16 mono samples captured at 8 kHz

On the BLE transport itself:

- Host-to-Frame raw payloads must be written with the `0x01` raw-data prefix described in the official Bluetooth spec.
- Frame-to-host raw payloads arrive with that same transport prefix before the inner payload above.

## Install options

1. Manual development install:
   Use Brilliant AR Studio / the official Lua workflow to push `main.lua` to Frame as `/main.lua`, then reset the glasses.

2. App-driven install:
   The iOS app can upload the same Lua source over BLE by writing the file through the Lua REPL, then sending the reset signal (`0x04`).

## References

- Frame SDK overview: https://docs.brilliant.xyz/frame/frame-sdk/
- Bluetooth spec: https://docs.brilliant.xyz/frame/frame-sdk-bluetooth-specs/
- Lua API: https://docs.brilliant.xyz/frame/frame-sdk-lua/
- Brilliant realtime audio example: https://github.com/brilliantlabsAR/frame_realtime_gemini_voicevision/blob/main/assets/frame_app.lua
