# HUDini Phonemizer

Offline, text-only phonetic formatting pipeline for HUDini.

## House Style

The formatter uses one stable output style:

- Syllables are joined with `-`.
- The stressed syllable is written in `ALL CAPS` when the language has a useful stress cue.
- The output avoids IPA and uses simple English-readable chunks such as `ah`, `ee`, `ay`, `oh`, `oo`, `ow`, `sh`, `ch`, `zh`, and `ny`.
- Mandarin uses syllable formatting but does not force stress because lexical stress is not stable the way it is in Spanish.

Examples:

- `gracias` -> `GRAH-see-ahs`
- `bonjour` -> `bohn-ZHOOR`
- `你好` -> `nee-how`

## What Is Included

- `phoneticize(text, language_code) -> string`
- Eleven adapters:
  - Arabic: `ar`
  - Bengali: `bn`
  - German: `de`
  - French: `fr`
  - Hindi: `hi`
  - Indonesian: `id`
  - Mandarin: `zh`
  - Portuguese: `pt`
  - Russian: `ru`
  - Spanish: `es`
  - Urdu: `ur`
- Small exceptions dictionary for high-value phrases
- Phrase datasets for each language
- CLI for quick testing
- Offline backends:
  - Mandarin: `pypinyin`
  - Spanish/French: prefer `phonemizer` with `espeak` if available, otherwise fall back to `epitran`
  - Hindi, Bengali, Arabic, Urdu, Russian: `uroman`
  - Indonesian and Portuguese: lightweight Latin-script formatting plus overrides

## Setup

Create and use a local virtual environment inside this folder:

```bash
cd phonemizer
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install -e .
```

## Run

CLI:

```bash
cd phonemizer
source .venv/bin/activate
python cli.py --language ar --text "مرحبا"
python cli.py --language de --text "guten tag"
python cli.py --language hi --text "नमस्ते"
python cli.py --language es --text "gracias"
python cli.py --language fr --text "bonjour"
python cli.py --language zh --text "你好"
```

Import:

```python
from hudini_phonemizer import phoneticize

print(phoneticize("gracias", "es"))
print(phoneticize("bonjour", "fr"))
print(phoneticize("你好", "zh"))
print(phoneticize("привет", "ru"))
```

## Tests

```bash
cd phonemizer
source .venv/bin/activate
pytest
```

Coverage reporting:

```bash
cd phonemizer
source .venv/bin/activate
python coverage_report.py
python coverage_report.py --write-review-template review_template.csv
```

## Notes

- This module is intentionally narrow. It is not a full pronunciation engine.
- French and Spanish can use `phonemizer` plus `espeak` when that backend exists on the host, but the implementation is still fully usable offline without it because the Python-only fallbacks are bundled in the virtual environment.
- Arabic and Urdu are the weakest fully offline additions because ordinary script often omits short vowels. Common phrases are tuned with overrides, while unknown words fall back to romanization-oriented formatting.
- Fallback behavior:
  - Mandarin returns pinyin if readable mapping fails.
  - Other supported languages return the original token when the mapper cannot confidently improve it.
