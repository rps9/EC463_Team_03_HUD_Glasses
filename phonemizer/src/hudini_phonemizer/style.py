from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

_COMBINING_MARKS = re.compile(r"[\u0300-\u036f]")
_WHITESPACE = re.compile(r"\s+")


@dataclass(frozen=True)
class StyledPronunciation:
    syllables: list[str]
    stress_index: int | None = None

    def render(self) -> str:
        parts: list[str] = []
        for index, syllable in enumerate(self.syllables):
            if not syllable:
                continue
            parts.append(syllable.upper() if index == self.stress_index else syllable.lower())
        return "-".join(parts)


def normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFC", text).strip()
    return _WHITESPACE.sub(" ", normalized)


def normalize_lookup_key(text: str) -> str:
    lowered = normalize_text(text).lower()
    lowered = lowered.replace("’", "'")
    return _WHITESPACE.sub(" ", lowered)


def strip_accents(text: str) -> str:
    decomposed = unicodedata.normalize("NFD", text)
    return _COMBINING_MARKS.sub("", decomposed)


def split_tokens(text: str) -> list[str]:
    tokens: list[str] = []
    current = ""
    current_kind: str | None = None

    for char in text:
        kind = _char_kind(char)
        if kind == "mark" and current_kind == "word":
            current += char
            continue

        if kind == "apostrophe" and current_kind == "word":
            current += char
            continue

        if current and kind != current_kind:
            tokens.append(current)
            current = ""
            current_kind = None

        if not current:
            current = char
            current_kind = "word" if kind in {"word", "mark", "apostrophe"} else kind
        else:
            current += char

    if current:
        tokens.append(current)

    return tokens


def is_word_token(token: str) -> bool:
    if not token:
        return False
    saw_letter = False
    for char in token:
        kind = _char_kind(char)
        if kind == "word":
            saw_letter = True
            continue
        if kind in {"mark", "apostrophe"}:
            continue
        return False
    return saw_letter


def _char_kind(char: str) -> str:
    if char.isspace():
        return "space"
    category = unicodedata.category(char)
    if category.startswith("L"):
        return "word"
    if category.startswith("M"):
        return "mark"
    if category == "Nd":
        return "digit"
    if char in {"'", "’"}:
        return "apostrophe"
    return "punct"


def collapse_spacing(text: str) -> str:
    text = re.sub(r"\s+([,.;:!?])", r"\1", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip()
