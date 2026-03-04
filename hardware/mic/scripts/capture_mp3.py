#!/usr/bin/env python3
import argparse
import pathlib
import re
import subprocess
import sys
import tempfile
import time

import serial


BEGIN_RE = re.compile(r"^AUDIO_BEGIN\s+(\d+)\s+(\d+)\s*$")


def read_line(ser: serial.Serial, timeout_s: float) -> str:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        line = ser.readline()
        if line:
            return line.decode("utf-8", errors="ignore").strip()
    raise TimeoutError("Timed out waiting for board output")


def read_exact(ser: serial.Serial, nbytes: int) -> bytes:
    chunks = []
    remaining = nbytes
    while remaining > 0:
        chunk = ser.read(remaining)
        if not chunk:
            raise TimeoutError(f"Serial read stalled with {remaining} bytes left")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture ESP32 mic clip and save as MP3")
    parser.add_argument("--port", required=True, help="Serial port, e.g. /dev/cu.SLAB_USBtoUART")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--output", required=True, help="Output MP3 path")
    args = parser.parse_args()

    output_path = pathlib.Path(args.output).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        ser = serial.Serial(args.port, args.baud, timeout=2)
    except Exception as exc:
        print(f"Failed to open serial port: {exc}", file=sys.stderr)
        return 1

    try:
        ser.reset_input_buffer()
        ser.setDTR(False)
        time.sleep(0.1)
        ser.setDTR(True)

        begin = ""
        for _ in range(60):
            line = read_line(ser, 1.0)
            m = BEGIN_RE.match(line)
            if m:
                begin = line
                break
        if not begin:
            print("Did not receive AUDIO_BEGIN marker", file=sys.stderr)
            return 1

        m = BEGIN_RE.match(begin)
        assert m is not None
        sample_rate = int(m.group(1))
        samples = int(m.group(2))
        raw = read_exact(ser, samples * 2)

        with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as tmp:
            tmp.write(raw)
            raw_path = pathlib.Path(tmp.name)

        ffmpeg_cmd = [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "s16le",
            "-ar",
            str(sample_rate),
            "-ac",
            "1",
            "-i",
            str(raw_path),
            str(output_path),
        ]
        try:
            subprocess.run(ffmpeg_cmd, check=True)
        except FileNotFoundError:
            print("ffmpeg not found. Install with: brew install ffmpeg", file=sys.stderr)
            return 1
        finally:
            raw_path.unlink(missing_ok=True)

        print(f"Saved MP3: {output_path}")
        return 0
    except Exception as exc:
        print(f"Capture failed: {exc}", file=sys.stderr)
        return 1
    finally:
        ser.close()


if __name__ == "__main__":
    raise SystemExit(main())
