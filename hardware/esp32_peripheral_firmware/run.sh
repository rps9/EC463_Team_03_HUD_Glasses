#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run.sh
#   ./run.sh /dev/cu.usbserial-0001
PORT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ -z "${PORT}" ]]; then
  PORT="$(pio device list --json-output | python3 -c '
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
')"
fi

if [[ -z "${PORT}" ]]; then
  echo "No serial device found. Pass port explicitly: ./run.sh /dev/cu.usbserial-0001" >&2
  exit 1
fi

pio run -e esp32dev -t upload --upload-port "${PORT}"
pio device monitor --port "${PORT}" --baud 115200
