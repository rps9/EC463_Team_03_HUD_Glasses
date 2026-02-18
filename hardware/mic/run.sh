#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run.sh
#   ./run.sh /dev/cu.SLAB_USBtoUART
#   ./run.sh /dev/cu.SLAB_USBtoUART captures/my_clip.mp3
PORT="${1:-}"
OUT_MP3="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ -z "${PORT}" ]]; then
  PORT="$(
    pio device list --json-output | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)

good_port = re.compile(r"(usb(serial|modem)|SLAB|ttyUSB|ttyACM)", re.I)
bad_port = re.compile(r"(debug-console|Bluetooth-Incoming-Port)", re.I)
good_desc = re.compile(r"(CP210|CH340|USB.*UART|FTDI|Silicon Labs)", re.I)

for d in devices:
    p = d.get("port", "")
    desc = d.get("description", "")
    if bad_port.search(p):
        continue
    if good_port.search(p) or good_desc.search(desc):
        print(p)
        raise SystemExit(0)

for d in devices:
    p = d.get("port", "")
    if bad_port.search(p):
        continue
    if p:
        print(p)
        raise SystemExit(0)
'
  )"
fi

if [[ -z "${PORT}" ]]; then
  echo "No serial device found. Pass port explicitly: ./run.sh /dev/cu.SLAB_USBtoUART" >&2
  exit 1
fi

if ! python3 -c "import serial" >/dev/null 2>&1; then
  echo "Missing Python package 'pyserial'." >&2
  echo "Activate your virtualenv and run: pip install -r requirements.txt" >&2
  exit 1
fi

if [[ -z "${OUT_MP3}" ]]; then
  mkdir -p captures
  OUT_MP3="captures/mic_$(date +%Y%m%d_%H%M%S).mp3"
fi

pio run -e esp32dev -t upload --upload-port "${PORT}"
python3 scripts/capture_mp3.py --port "${PORT}" --output "${OUT_MP3}"
