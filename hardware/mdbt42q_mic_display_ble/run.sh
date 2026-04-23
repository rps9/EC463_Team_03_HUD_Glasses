#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run.sh
#   ./run.sh /dev/cu.usbserial-0001

PORT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

export PLATFORMIO_CORE_DIR="${PLATFORMIO_CORE_DIR:-/tmp/pio-home}"

UPLOAD_LOG="$(mktemp)"

pio run -e mdbt42q -t upload >"${UPLOAD_LOG}" 2>&1 || {
  cat "${UPLOAD_LOG}"
  rm -f "${UPLOAD_LOG}"
  exit 1
}

cat "${UPLOAD_LOG}"

if grep -Eq "J-Link connection not established|FAILED: Failed to open DLL|CURRENT: upload_protocol = nrfutil|Auto-detected: /dev/cu.Bluetooth-Incoming-Port|No data received on serial port|Error:" "${UPLOAD_LOG}"; then
  echo "Upload failed. Firmware was built, but the MDBT42Q was not programmed." >&2
  echo "Attach the J-Link over USB and connect its SWD header to the MDBT42Q target." >&2
  rm -f "${UPLOAD_LOG}"
  exit 1
fi

rm -f "${UPLOAD_LOG}"

if [[ -n "${PORT}" ]]; then
  pio device monitor --port "${PORT}" --baud 115200
else
  echo "Upload complete."
  echo "Pass a USB-UART port to monitor logs, for example:"
  echo "  ./run.sh /dev/cu.usbserial-0001"
fi
