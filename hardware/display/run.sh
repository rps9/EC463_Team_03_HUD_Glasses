#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run.sh
#   ./run.sh /dev/cu.usbmodemXXXX

PORT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

find_serial_port() {
  pio device list --json-output | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)

good_port = re.compile(r"(usb(serial|modem)|ttyUSB|ttyACM|ACM)", re.I)
bad_port = re.compile(r"(debug-console|Bluetooth-Incoming-Port)", re.I)
good_desc = re.compile(r"(RP2|Pico|USB.*Serial|CDC)", re.I)

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
}

echo "Put the Pico 2 W into BOOTSEL mode if upload is needed."
pio run -e pico2w -t upload

if [[ -z "${PORT}" ]]; then
  sleep 2
  PORT="$(find_serial_port || true)"
fi

if [[ -z "${PORT}" ]]; then
  echo "Upload finished, but no serial port was detected automatically." >&2
  echo "Open the monitor manually with: pio device monitor -b 115200" >&2
  exit 0
fi

pio device monitor --port "${PORT}" --baud 115200
