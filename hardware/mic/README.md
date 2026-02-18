# ESP32 Mic Demo (PlatformIO)

This folder is configured to run the ESP32 I2S mic demo without Arduino IDE.
Source code lives in `src/main.cpp`.

## One-time setup

1. Install PlatformIO Core:
   `brew install platformio`
2. Enter this folder:
   `cd hardware/mic`
3. Create and activate a Python virtual environment:
   `python3 -m venv .venv`
   `source .venv/bin/activate`
4. Install Python dependencies:
   `pip install -r requirements.txt`
5. Install FFmpeg (used to encode MP3):
   `brew install ffmpeg`
6. Build once to install the ESP32 platform/toolchain:
   `pio run -e esp32dev`

## Repeated use (one command)

From this folder:

`./run.sh`

If auto-detection fails, pass your serial port:

`./run.sh /dev/cu.SLAB_USBtoUART`

Optionally set output path:

`./run.sh /dev/cu.SLAB_USBtoUART captures/test.mp3`

This command compiles, uploads, captures 5 seconds of mic audio, and writes an MP3 on your computer.
