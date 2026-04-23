#!/usr/bin/env python3

from __future__ import annotations

import argparse

from hudini_phonemizer import phoneticize


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline HUDini phonetic formatter")
    parser.add_argument("--language", "-l", required=True, help="Language code: es, fr, zh")
    parser.add_argument("--text", "-t", required=True, help="Foreign-language input text")
    args = parser.parse_args()

    print(phoneticize(args.text, args.language))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
