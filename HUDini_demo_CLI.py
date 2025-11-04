#!/usr/bin/env python3
"""
HUDini Multilang Demo — EN → [target] translate → IPA/romanize → ERP
No drama, minimal latency, readable output.

Priority:
  1) CJK: romanizers (Pinyin/Hepburn/RR) for readability
  2) Epitran (pure Python G2P to IPA) for many languages
  3) phonemizer + espeak-ng as a fallback for anything else

Run:
  pip install -r requirements.txt
  python hudini_multilang_cli.py
"""

import os
import re
from typing import Dict, List, Optional, Tuple

from rich.console import Console
from rich.panel import Panel
from rich.prompt import Prompt
from rich.table import Table
from rich import box

# Translation
from deep_translator import GoogleTranslator

# Epitran (pure Python orthography→IPA for many langs)
import epitran

# Optional fallback phonemizer (requires espeak-ng)
try:
    from phonemizer import phonemize
    from phonemizer.separator import Separator
    _HAS_PHONEMIZER = True
except Exception:
    _HAS_PHONEMIZER = False

# CJK romanizers
try:
    from pypinyin import pinyin, Style
    _HAS_PYPINYIN = True
except Exception:
    _HAS_PYPINYIN = False

try:
    import pykakasi
    _HAS_KAKASI = True
except Exception:
    _HAS_KAKASI = False

try:
    from hangul_romanize import Transliter
    from hangul_romanize.rule import academic
    _HAS_HANGUL = True
    _HANGUL_XLIT = Transliter(academic)
except Exception:
    _HAS_HANGUL = False

console = Console()

# Safety: don’t name this file after packages
if os.path.splitext(os.path.basename(__file__))[0].lower() in {"phonemizer", "rich", "deep_translator", "epitran"}:
    raise RuntimeError("Rename this file. Its name collides with an imported package.")

# -----------------------------------------------------------------------------
# IPA → English-Readable Pronunciation (ERP) mapping
# Use placeholders to avoid double replacement.
# -----------------------------------------------------------------------------

DIPHTHONGS = [
    (r"aɪ", "{EYE}"),
    (r"aʊ", "{OW}"),
    (r"ɔɪ", "{OY}"),
    (r"oʊ", "{OH}"),
    (r"eɪ", "{AY}"),
]

CONSONANTS: List[Tuple[str, str]] = [
    (r"d͡ʒ", "j"), (r"t͡ʃ", "ch"),
    (r"dʒ", "j"),  (r"tʃ", "ch"),
    (r"ʃ", "sh"),  (r"ʒ", "zh"),
    (r"θ", "th"),  (r"ð", "dh"),
    (r"ɲ", "ny"),  (r"ŋ", "ng"),
    (r"ç", "hy"),
    (r"[xχ]", "kh"),
    (r"ɣ", "gh"),
    (r"[ʁʀ]", "r"),
    (r"ɾ", "r"),
    (r"ʔ", "’"),
    (r"ɬ", "hl"),
    (r"͡", ""),  # tie bar
]

VOWELS: List[Tuple[str, str]] = [
    (r"\bi\b", "ee"),
    (r"i", "ee"),
    (r"ɪ", "ih"),
    (r"e", "ay"),
    (r"ɛ", "eh"),
    (r"æ", "a"),
    (r"[aɑ]", "ah"),
    (r"ɒ", "aw"),
    (r"ɔ", "aw"),
    (r"o", "oh"),
    (r"u", "oo"),
    (r"ʊ", "uh"),
    (r"[ʌɘɵɞ]", "uh"),
    (r"ə", "uh"),
    (r"[ɚɝɜ]", "er"),
    # do NOT map plain 'y' here; it breaks 'ay/oy/eye'
]

COMBINING_NASAL = re.compile(r"([aeiouyɔæɐɑɛœɜɞøo])\u0303")
PLACEHOLDER_FINALS = {"{EYE}": "eye", "{OW}": "ow", "{OY}": "oy", "{OH}": "oh", "{AY}": "ay"}

def ipa_to_erp(ipa: str) -> str:
    s = ipa.strip()
    s = s.replace("ˌ", "")         # secondary stress off
    s = s.replace("ˈ", "'")        # keep primary stress as apostrophe
    s = s.replace(".", "-")        # syllable dot → hyphen
    s = COMBINING_NASAL.sub(lambda m: m.group(1) + "n", s)

    for pat, ph in DIPHTHONGS:
        s = re.sub(pat, ph, s)

    for pat, repl in CONSONANTS:
        s = re.sub(pat, repl, s)

    for pat, repl in VOWELS:
        s = re.sub(pat, repl, s)

    for ph, out in PLACEHOLDER_FINALS.items():
        s = s.replace(ph, out)

    # Readability tweaks
    s = re.sub(r"([bcdfghjklmnpqrstvwxyz])eye\b", r"\1ye", s, flags=re.IGNORECASE)
    s = re.sub(r"eye(?=uh)", "ye-", s)

    s = re.sub(r"-{2,}", "-", s)
    s = re.sub(r"\s{2,}", " ", s)
    return _uppercase_stress(s).strip()

def _uppercase_stress(erp: str) -> str:
    chars = list(erp)
    i = 0
    while i < len(chars):
        if chars[i] == "'":
            j = i + 1
            while j < len(chars) and chars[j] not in "- ,.;:!?":
                chars[j] = chars[j].upper()
                j += 1
            i = j
        else:
            i += 1
    return "".join(chars)

# -----------------------------------------------------------------------------
# CJK helpers: Pinyin → ERP for “English-y” Mandarin, romanizers for JA/KO
# -----------------------------------------------------------------------------

CJK_ENGLISHY_ERP = True

_PINYIN_SYL = re.compile(r"([a-züv]+)([1-5])?$", re.IGNORECASE)
_INITIAL_MAP = {
    "zh": "zh", "ch": "ch", "sh": "sh",
    "j": "jy", "q": "chy", "x": "shy",
    "z": "z", "c": "ts", "s": "s", "r": "r",
    "b": "b", "p": "p", "m": "m", "f": "f",
    "d": "d", "t": "t", "n": "n", "l": "l",
    "g": "g", "k": "k", "h": "h", "w": "w", "y": "y"
}
_FINAL_MAP = {
    "a": "ah", "ai": "eye", "an": "ahn", "ang": "ahng", "ao": "ow",
    "e": "uh", "ei": "ay", "en": "uhn", "eng": "uhng", "er": "ar",
    "i": "ee", "ia": "yah", "ian": "yen", "iang": "yahng", "iao": "yow",
    "ie": "yeh", "in": "een", "ing": "eeng", "iong": "yong", "iu": "yo",
    "o": "oh", "ong": "ohng", "ou": "oh",
    "u": "oo", "ua": "wah", "uai": "why", "uan": "wahn", "uang": "wahng",
    "ui": "way", "uo": "woh", "un": "oon",
    "ü": "yue", "v": "yue", "ue": "weh",
}
def _split_pinyin_syllable(syl: str):
    syl = syl.lower().replace("u:", "ü").replace("v", "ü")
    for ini2 in ("zh", "ch", "sh"):
        if syl.startswith(ini2):
            return ini2, syl[len(ini2):]
    if syl and syl[0] in "bpmfdtnlgkhjqxrzcswy":
        return syl[0], syl[1:]
    return "", syl

def _map_initial_final(ini: str, fin: str) -> str:
    if ini == "r" and fin == "ui":
        return "ray"
    if ini == "" and fin == "i":
        return "ee"
    ini_m = _INITIAL_MAP.get(ini, ini)
    fin_m = _FINAL_MAP.get(fin, fin)
    if fin_m.startswith(("y", "w")) and ini_m.endswith(("y", "w")):
        fin_m = fin_m[1:]
    return ini_m + fin_m

def pinyin_to_erp(pinyin_with_tones: str) -> str:
    out_tokens = []
    for tok in re.split(r"(\s+|[^a-zA-Z0-9üÜ]+)", pinyin_with_tones):
        if not tok or tok.isspace():
            out_tokens.append(tok)
            continue
        m = _PINYIN_SYL.match(tok)
        if not m:
            out_tokens.append(tok)
            continue
        base, tone = m.groups()
        ini, fin = _split_pinyin_syllable(base)
        erp_syl = _map_initial_final(ini, fin)
        if tone:
            erp_syl += tone
        out_tokens.append(erp_syl)
    return "".join(out_tokens)

def romanize_cjk(text: str, target_lang_key: str) -> Optional[str]:
    k = target_lang_key.lower()
    if k.startswith("zh") and _HAS_PYPINYIN:
        syls = pinyin(text, style=Style.TONE3, strict=False)
        return " ".join(s for [s] in syls if s)
    if k == "ja" and _HAS_KAKASI:
        kakasi = pykakasi.kakasi()
        kakasi.setMode("H", "a"); kakasi.setMode("K", "a"); kakasi.setMode("J", "a")
        kakasi.setMode("r", "Hepburn")
        conv = kakasi.getConverter()
        return conv.do(text)
    if k == "ko" and _HAS_HANGUL:
        return _HANGUL_XLIT.transliterate(text)
    return None

# -----------------------------------------------------------------------------
# Language codes and backends
# -----------------------------------------------------------------------------

# What we show vs how engines want codes
LANG_CHOICES: Dict[str, Dict[str, str]] = {
    "es": {"name": "Spanish",  "phon_lang": "es"},
    "fr": {"name": "French",   "phon_lang": "fr-fr"},
    "de": {"name": "German",   "phon_lang": "de"},
    "it": {"name": "Italian",  "phon_lang": "it"},
    "pt": {"name": "Portuguese","phon_lang": "pt"},
    "ru": {"name": "Russian",  "phon_lang": "ru"},
    "ar": {"name": "Arabic",   "phon_lang": "ar"},
    "hi": {"name": "Hindi",    "phon_lang": "hi"},
    "tr": {"name": "Turkish",  "phon_lang": "tr"},
    "th": {"name": "Thai",     "phon_lang": "th"},
    "vi": {"name": "Vietnamese","phon_lang": "vi"},
    # CJK keys
    "zh":    {"name": "Chinese (alias → zh-CN)", "phon_lang": "zh"},
    "zh-CN": {"name": "Chinese (Simplified)",    "phon_lang": "zh"},
    "zh-TW": {"name": "Chinese (Traditional)",   "phon_lang": "zh"},
    "ja":    {"name": "Japanese",                "phon_lang": "ja"},
    "ko":    {"name": "Korean",                  "phon_lang": "ko"},
}

# Google translator wants specific codes
TRANSLATOR_CODE_MAP = {
    "zh": "zh-CN",
    "zh-cn": "zh-CN",
    "zh-hans": "zh-CN",
    "zh-tw": "zh-TW",
    "zh-hant": "zh-TW",
    "he": "iw",  # legacy alias
}

def _translator_code(user_code: str) -> str:
    key = user_code.strip()
    return TRANSLATOR_CODE_MAP.get(key, key)

# Epitran language tags (orthography→IPA)
EPITRAN_CODE_MAP = {
    "es": "spa-Latn",
    "fr": "fra-Latn",
    "de": "deu-Latn",
    "it": "ita-Latn",
    "pt": "por-Latn",
    "ru": "rus-Cyrl",
    "ar": "ara-Arab",
    "hi": "hin-Deva",
    "tr": "tur-Latn",
    "th": "tha-Thai",
    "vi": "vie-Latn",
    "zh": "cmn-Hans",     # alias to Simplified
    "zh-CN": "cmn-Hans",
    "zh-TW": "cmn-Hant",
    # Japanese/Korean better via romanizers; Epitran support is limited/varies
}

# -----------------------------------------------------------------------------
# Engines
# -----------------------------------------------------------------------------

def translate_en_to(text: str, target_lang_key: str) -> str:
    tcode = _translator_code(target_lang_key)
    return GoogleTranslator(source="en", target=tcode).translate(text)

def ipa_via_epitran(text: str, target_lang_key: str) -> Optional[str]:
    code = EPITRAN_CODE_MAP.get(target_lang_key)
    if not code:
        return None
    try:
        epi = epitran.Epitran(code)
        ipa = epi.transliterate(text)
        return ipa.strip() or None
    except Exception:
        return None

def ipa_via_phonemizer(text: str, phon_lang: str) -> Optional[str]:
    if not _HAS_PHONEMIZER:
        return None
    try:
        sep = Separator(phone=" ", syllable="-", word=" | ")
        out = phonemize(
            text,
            language=phon_lang,
            backend="espeak",
            strip=True,
            preserve_punctuation=False,
            with_stress=True,
            separator=sep
        )
        return out.replace(" | ", " ").strip()
    except Exception:
        return None

def to_erp_from_text(target_text: str, target_lang_key: str) -> Tuple[str, str]:
    """
    Returns (debug_row, erp). debug_row shows romanization/IPA for inspection.
    """
    k = target_lang_key.lower()

    # CJK path
    if k.startswith("zh") or k in {"ja", "ko"}:
        rom = romanize_cjk(target_text, target_lang_key)  # prefer romanizer
        if not rom:
            # fallback to Epitran (Mandarin only) or phonemizer if romanizer missing
            ipa = ipa_via_epitran(target_text, target_lang_key) or \
                  ipa_via_phonemizer(target_text, LANG_CHOICES[target_lang_key]["phon_lang"]) or "(unavailable)"
            debug = ipa
            if k.startswith("zh") and CJK_ENGLISHY_ERP and ipa != "(unavailable)":
                # If we got IPA (rare for zh), just ERP it
                return debug, ipa_to_erp(ipa)
            # No romanizer: ERP from IPA if present
            return debug, (ipa_to_erp(ipa) if ipa != "(unavailable)" else "(unavailable)")
        # Have romanization
        debug = rom
        if k.startswith("zh") and CJK_ENGLISHY_ERP:
            return debug, pinyin_to_erp(rom)
        return debug, rom

    # Non-CJK: try Epitran first
    ipa = ipa_via_epitran(target_text, target_lang_key)
    if ipa:
        return ipa, ipa_to_erp(ipa)

    # Fallback: phonemizer + espeak-ng
    ipa = ipa_via_phonemizer(target_text, LANG_CHOICES[target_lang_key]["phon_lang"])
    if ipa:
        return ipa, ipa_to_erp(ipa)

    # Nothing worked
    return "(unavailable)", "(phonemization unavailable — install espeak-ng or check Epitran support)"

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

HELP = """\
Type English. I’ll:
  • Translate to the target language
  • Get pronunciation (romanization for CJK, IPA for others)
  • Show an English-readable respelling (ERP)

If a language shows “phonemization unavailable,” install espeak-ng or use a supported target.
"""

def print_header():
    langs = Table(box=box.SIMPLE_HEAVY, title="Target languages")
    langs.add_column("Code", justify="center", style="cyan", no_wrap=True)
    langs.add_column("Language", style="white")
    for code, meta in LANG_CHOICES.items():
        langs.add_row(code, meta["name"])

    console.print(Panel.fit(
        "[bold]HUDini Multilang Demo[/] • EN → [target] translate → pronounce → ERP",
        box=box.ROUNDED
    ))
    console.print(Panel.fit(HELP, box=box.SQUARE))
    console.print(langs)

def demo_once():
    text = Prompt.ask("[bold green]Enter English text[/]").strip()
    if not text:
        console.print("[yellow]Empty input. Try again.[/]")
        return
    target = Prompt.ask(
        "[bold green]Target language code[/]",
        choices=list(LANG_CHOICES.keys()),
        default="es"
    )

    try:
        translated = translate_en_to(text, target)
    except Exception as e:
        hint = _translator_code(target)
        console.print(Panel.fit(
            f"[red]Translation failed:[/] {e}\n"
            f"Hint: mapping '{target}' → '{hint}' for the translator may help.",
            border_style="red", box=box.SQUARE
        ))
        return

    debug_row, erp = to_erp_from_text(translated, target)

    t = Table(box=box.SIMPLE_HEAVY, show_header=False)
    t.add_row("[dim]Input (EN):[/]", text)
    t.add_row("[dim]Translation:[/]", translated)
    t.add_row("[dim]Phonemes/Romanization:[/]", debug_row)
    t.add_row("[bold magenta]ERP[/]:", f"[white]{erp}[/]")
    console.print(t)

def main():
    print_header()
    while True:
        try:
            cmd = Prompt.ask("[bold]Command[/]", default="run").strip().lower()
        except (EOFError, KeyboardInterrupt):
            console.print("\n[dim]Bye.[/]")
            break

        if cmd in {"quit", "exit", "q"}:
            console.print("[dim]Bye.[/]")
            break
        if cmd in {"run", ""}:
            demo_once()
            continue
        if cmd == "help":
            console.print(Panel.fit(HELP, box=box.SQUARE))
            continue
        console.print("[yellow]Commands: run, help, quit[/]")

if __name__ == "__main__":
    main()
