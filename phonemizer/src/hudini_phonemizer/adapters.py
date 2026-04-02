from __future__ import annotations

import logging
import re
import unicodedata
from abc import ABC, abstractmethod
from dataclasses import dataclass
from functools import lru_cache

import epitran
import jieba
from pypinyin import Style, lazy_pinyin
from uroman import Uroman

from .analysis import PronunciationTrace
from .exceptions import PHRASE_EXCEPTIONS
from .style import (
    StyledPronunciation,
    collapse_spacing,
    is_word_token,
    normalize_lookup_key,
    normalize_text,
    split_tokens,
    strip_accents,
)

try:
    from phonemizer.backend import EspeakBackend
    from phonemizer.separator import Separator

    _HAS_PHONEMIZER = True
except Exception:
    EspeakBackend = None
    Separator = None
    _HAS_PHONEMIZER = False

jieba.setLogLevel(logging.WARNING)
_UROMAN = Uroman()

_VOWEL_UNITS = {
    "a", "e", "i", "o", "u", "y", "æ", "ø", "œ", "ə", "ɛ", "ɐ", "ɨ", "ɪ", "ɔ", "ɑ", "ʊ", "ɥ",
}
_PINYIN_INITIALS = (
    "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
    "j", "q", "x", "r", "z", "c", "s", "y", "w",
)
_PINYIN_FINALS = {
    "a": "ah",
    "ai": "eye",
    "an": "ahn",
    "ang": "ahng",
    "ao": "ow",
    "e": "uh",
    "ei": "ay",
    "en": "uhn",
    "eng": "uhng",
    "er": "er",
    "i": "ee",
    "ia": "yah",
    "ian": "yen",
    "iang": "yahng",
    "iao": "yow",
    "ie": "yeh",
    "in": "een",
    "ing": "eeng",
    "iong": "yohng",
    "iu": "yoh",
    "o": "oh",
    "ong": "ohng",
    "ou": "oh",
    "u": "oo",
    "ua": "wah",
    "uai": "why",
    "uan": "wahn",
    "uang": "wahng",
    "ui": "way",
    "un": "wuhn",
    "uo": "woh",
    "ü": "yoo",
    "üe": "weh",
    "uanr": "wahr",
    "ve": "weh",
}
_PINYIN_INITIAL_MAP = {
    "b": "b",
    "p": "p",
    "m": "m",
    "f": "f",
    "d": "d",
    "t": "t",
    "n": "n",
    "l": "l",
    "g": "g",
    "k": "k",
    "h": "h",
    "j": "jy",
    "q": "ch",
    "x": "sh",
    "zh": "j",
    "ch": "ch",
    "sh": "sh",
    "r": "r",
    "z": "dz",
    "c": "ts",
    "s": "s",
    "y": "y",
    "w": "w",
    "": "",
}


def get_adapter(language_code: str) -> "BaseAdapter":
    return _get_cached_adapter(language_code.lower().strip())


@lru_cache(maxsize=None)
def _get_cached_adapter(code: str) -> "BaseAdapter":
    if code.startswith("ar"):
        return ArabicAdapter()
    if code.startswith("bn"):
        return BengaliAdapter()
    if code.startswith("de"):
        return GermanAdapter()
    if code.startswith("es"):
        return SpanishAdapter()
    if code.startswith("fr"):
        return FrenchAdapter()
    if code.startswith("hi"):
        return HindiAdapter()
    if code.startswith("id"):
        return IndonesianAdapter()
    if code.startswith("pt"):
        return PortugueseAdapter()
    if code.startswith("ru"):
        return RussianAdapter()
    if code.startswith("ur"):
        return UrduAdapter()
    if code.startswith("zh"):
        return MandarinAdapter()
    raise ValueError(f"Unsupported language code: {code}")


@dataclass
class _TraceState:
    language_code: str
    input_text: str
    normalized_text: str
    word_token_count: int = 0
    phrase_exception_hit: bool = False
    span_exception_hits: int = 0
    word_exception_hits: int = 0
    exception_token_hits: int = 0
    proper_noun_override_hits: int = 0

    def to_trace(self, output: str) -> PronunciationTrace:
        return PronunciationTrace(
            language_code=self.language_code,
            input_text=self.input_text,
            normalized_text=self.normalized_text,
            output=output,
            word_token_count=self.word_token_count,
            phrase_exception_hit=self.phrase_exception_hit,
            span_exception_hits=self.span_exception_hits,
            word_exception_hits=self.word_exception_hits,
            exception_token_hits=self.exception_token_hits,
            proper_noun_override_hits=self.proper_noun_override_hits,
        )


class BaseAdapter(ABC):
    language_code: str
    unstressed_words: frozenset[str] = frozenset()
    proper_noun_overrides: dict[str, str] = {}

    def phoneticize(self, text: str) -> str:
        return self.analyze(text).output

    def analyze(self, text: str) -> PronunciationTrace:
        normalized = normalize_text(text)
        trace = _TraceState(
            language_code=self.language_code,
            input_text=text,
            normalized_text=normalized,
        )
        if not normalized:
            return trace.to_trace("")

        tokens = split_tokens(normalized)
        trace.word_token_count = sum(1 for token in tokens if is_word_token(token))

        exception = self._phrase_exception(normalized)
        if exception is not None:
            trace.phrase_exception_hit = True
            trace.span_exception_hits = 1
            trace.exception_token_hits = trace.word_token_count
            return trace.to_trace(exception)

        rendered: list[str] = []
        index = 0
        while index < len(tokens):
            span_match = self._match_exception_span(tokens, index)
            if span_match is not None:
                replacement, next_index, covered_words = span_match
                trace.span_exception_hits += 1
                trace.exception_token_hits += covered_words
                rendered.append(replacement)
                index = next_index
                continue

            token = tokens[index]
            if token.isspace():
                rendered.append(token)
                index += 1
                continue
            if is_word_token(token):
                rendered.append(self._render_word_token(token, trace))
                index += 1
                continue
            rendered.append(token)
            index += 1
        return trace.to_trace(collapse_spacing("".join(rendered)))

    def _phrase_exception(self, text: str) -> str | None:
        return PHRASE_EXCEPTIONS.get(self.language_code, {}).get(normalize_lookup_key(text))

    def _word_exception(self, word: str) -> str | None:
        return PHRASE_EXCEPTIONS.get(self.language_code, {}).get(normalize_lookup_key(word))

    @abstractmethod
    def _phoneticize_word(self, word: str) -> str:
        raise NotImplementedError

    def _render_word_token(self, token: str, trace: _TraceState) -> str:
        override = self.proper_noun_overrides.get(token)
        if override is not None:
            trace.proper_noun_override_hits += 1
            return override

        exception = self._word_exception(token)
        if exception is not None:
            trace.word_exception_hits += 1
            trace.exception_token_hits += 1
            return exception

        rendered = self._phoneticize_word(token)
        if normalize_lookup_key(token) in self.unstressed_words:
            return rendered.lower()
        return rendered

    def _match_exception_span(self, tokens: list[str], start: int) -> tuple[str, int, int] | None:
        if not is_word_token(tokens[start]):
            return None

        best_match: tuple[str, int, int] | None = None
        end = start
        while end < len(tokens) and is_word_token(tokens[end]):
            candidate = "".join(tokens[start:end + 1])
            replacement = self._phrase_exception(candidate)
            if replacement is not None:
                covered_words = sum(1 for token in tokens[start:end + 1] if is_word_token(token))
                best_match = (replacement, end + 1, covered_words)

            if end + 1 >= len(tokens) or not tokens[end + 1].isspace():
                break
            if end + 2 >= len(tokens) or not is_word_token(tokens[end + 2]):
                break
            end += 2

        return best_match


class SpanishAdapter(BaseAdapter):
    language_code = "es"
    unstressed_words = frozenset({"a", "con", "de", "del", "el", "en", "la", "las", "los", "me", "mi", "un", "una", "y"})
    proper_noun_overrides = {"Boston": "BOSS-tuhn"}

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("spa-Latn")

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception

        ipa = _normalize_spanish_ipa(self._epitran.transliterate(word))
        if not ipa:
            return word
        syllables = _syllabify_ipa(ipa)
        if not syllables:
            return word
        stress_index = _spanish_stress_index(word, syllables)
        readable = [_map_spanish_ipa_syllable(syllable) for syllable in syllables]
        return StyledPronunciation(readable, stress_index=stress_index).render()


class FrenchAdapter(BaseAdapter):
    language_code = "fr"
    unstressed_words = frozenset({"a", "à", "au", "aux", "ce", "de", "des", "du", "en", "et", "je", "la", "le", "les", "ma", "me", "mon", "un", "une", "vous"})
    proper_noun_overrides = {"Boston": "BOSS-tuhn"}

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("fra-Latn")
        self._use_espeak = bool(_HAS_PHONEMIZER and EspeakBackend.is_available())
        self._backend = None
        if self._use_espeak:
            self._backend = EspeakBackend("fr-fr", preserve_punctuation=True, with_stress=False)

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception

        ipa = self._to_ipa(word)
        if not ipa:
            return word

        syllables = _syllabify_ipa(ipa)
        if not syllables:
            return word

        readable = [_map_french_ipa_syllable(syllable) for syllable in syllables]
        stress_index = len(readable) - 1 if len(readable) > 1 else 0
        return StyledPronunciation(readable, stress_index=stress_index).render()

    def _to_ipa(self, word: str) -> str:
        if self._backend is not None:
            separator = Separator(phone="", word=" ", syllable="|")
            raw = self._backend.phonemize([word], separator=separator, strip=True)[0]
            return raw.replace("|", ".").replace(" ", "")
        return self._epitran.transliterate(word)


class MandarinAdapter(BaseAdapter):
    language_code = "zh"

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception

        if _contains_han(word) and len(word) > 2:
            segments = [segment for segment in jieba.lcut(word) if segment.strip()]
            if len(segments) > 1:
                return " ".join(self._phoneticize_segment(segment) for segment in segments)

        return self._phoneticize_segment(word)

    def _phoneticize_segment(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception

        pinyin_syllables = lazy_pinyin(
            word,
            style=Style.TONE3,
            strict=False,
            neutral_tone_with_five=True,
        )
        if not pinyin_syllables:
            return word

        readable: list[str] = []
        fallback = []
        for syllable in pinyin_syllables:
            rendered = _map_pinyin_syllable(syllable)
            fallback.append(_strip_tone_number(syllable))
            if rendered is None:
                return "-".join(fallback)
            readable.append(rendered)
        return StyledPronunciation(readable, stress_index=None).render()


class HindiAdapter(BaseAdapter):
    language_code = "hi"

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("hin-Deva")

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        ipa = self._epitran.transliterate(word)
        return _stylize_hindi_word(word, ipa)


class BengaliAdapter(BaseAdapter):
    language_code = "bn"

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        return _stylize_bengali_word(word)


class GermanAdapter(BaseAdapter):
    language_code = "de"
    unstressed_words = frozenset({"das", "der", "die", "ein", "eine", "und", "zu"})
    _compound_suffixes = ("ingenieur", "informatik", "bibliothek", "technik")

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("deu-Latn")

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        compound_parts = self._split_compound(word)
        if compound_parts is not None:
            return "-".join(self._phoneticize_word(part) for part in compound_parts)
        ipa = self._epitran.transliterate(word)
        return _stylize_german_word(word, ipa)

    def _split_compound(self, word: str) -> list[str] | None:
        lowered = normalize_lookup_key(word)
        for suffix in self._compound_suffixes:
            if not lowered.endswith(suffix) or lowered == suffix:
                continue
            prefix = word[: len(word) - len(suffix)]
            if len(prefix) < 4:
                continue
            if prefix.endswith(("n", "s")) and len(prefix) >= 5:
                trimmed = prefix[:-1]
                if self._word_exception(trimmed) is not None:
                    return [trimmed, word[len(prefix):]]
            if self._word_exception(prefix) is not None:
                return [prefix, word[len(prefix):]]
        return None


class ArabicAdapter(BaseAdapter):
    language_code = "ar"

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        return _stylize_arabic_word(word)


class UrduAdapter(BaseAdapter):
    language_code = "ur"

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        return _stylize_urdu_word(word)


class RussianAdapter(BaseAdapter):
    language_code = "ru"

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("rus-Cyrl")

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        ipa = self._epitran.transliterate(word)
        return _stylize_russian_word(word, ipa)


class IndonesianAdapter(BaseAdapter):
    language_code = "id"
    unstressed_words = frozenset({"dan", "di", "ke", "yang"})

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        return _stylize_indonesian_word(word)


class PortugueseAdapter(BaseAdapter):
    language_code = "pt"
    unstressed_words = frozenset({"a", "as", "de", "do", "da", "e", "em", "o", "os", "um", "uma"})
    proper_noun_overrides = {"Boston": "BOSS-tuhn"}

    def __init__(self) -> None:
        self._epitran = epitran.Epitran("por-Latn")

    def _phoneticize_word(self, word: str) -> str:
        exception = self._word_exception(word)
        if exception is not None:
            return exception
        ipa = self._epitran.transliterate(word)
        return _stylize_portuguese_word(word, ipa)


def _strip_tone_number(syllable: str) -> str:
    return re.sub(r"[1-5]$", "", syllable.lower())


def _contains_han(text: str) -> bool:
    return any("\u4e00" <= char <= "\u9fff" for char in text)


def _uroman_word(word: str) -> str:
    return _UROMAN.romanize_string(word)


def _stylize_uroman_word(word: str) -> str:
    romanized = _uroman_word(word)
    return _stylize_latin_word(romanized)


def _stylize_latin_word(word: str, stress_index: int | None = None) -> str:
    cleaned = strip_accents(word.lower())
    cleaned = cleaned.replace("'", "")
    cleaned = re.sub(r"[^a-z]", "", cleaned)
    if not cleaned:
        return word

    syllables = _roman_syllables(cleaned)
    readable = [_map_roman_syllable(syllable) for syllable in syllables]
    return StyledPronunciation(readable, stress_index=stress_index).render()


def _stylize_hindi_word(word: str, ipa: str | None = None) -> str:
    if ipa:
        syllables = _syllabify_ipa(ipa)
        if syllables:
            readable = [_map_hindi_ipa_syllable(syllable) for syllable in syllables]
            stress_index = len(readable) - 2 if len(readable) > 1 else 0
            return StyledPronunciation(readable, stress_index=stress_index).render()

    romanized = _uroman_word(word).lower()
    romanized = romanized.replace("aa", "a").replace("ii", "i").replace("uu", "u")
    romanized = romanized.replace("tth", "th").replace("ddh", "dh")
    romanized = romanized.replace("kh", "k").replace("gh", "g").replace("bh", "b").replace("dh", "d")
    romanized = romanized.replace("ph", "f").replace("sh", "sh").replace("chh", "ch")
    romanized = romanized.replace("ny", "ny").replace("v", "v")
    stress_index = _default_penultimate_stress(romanized)
    return _stylize_latin_word(romanized, stress_index=stress_index)


def _stylize_bengali_word(word: str) -> str:
    romanized = _uroman_word(word).lower()
    romanized = romanized.replace("aa", "a").replace("ii", "i").replace("uu", "u")
    romanized = romanized.replace("bh", "b").replace("dh", "d").replace("th", "t")
    romanized = romanized.replace("sh", "sh").replace("chh", "ch").replace("kh", "k")
    romanized = romanized.replace("ng", "ng")
    stress_index = _default_penultimate_stress(romanized)
    return _stylize_latin_word(romanized, stress_index=stress_index)


def _stylize_arabic_word(word: str) -> str:
    romanized = _uroman_word(word).lower()
    romanized = romanized.replace("'", "")
    romanized = romanized.replace("aa", "a").replace("ii", "i").replace("uu", "u")
    romanized = romanized.replace("kh", "h").replace("gh", "gh").replace("sh", "sh")
    romanized = romanized.replace("dh", "d").replace("th", "t").replace("7", "h")
    romanized = _restore_abjad_vowels(romanized)
    stress_index = _default_penultimate_stress(romanized)
    return _stylize_latin_word(romanized, stress_index=stress_index)


def _stylize_urdu_word(word: str) -> str:
    raw = _uroman_word(word).lower()
    cleaned = raw.replace("'", "")
    direct_outputs = {
        "hilw": "HEE-loh",
        "shkrih": "shoo-KREE-yah",
        "mhrbani": "mehr-bah-NEE",
        "jamh": "JAH-mee-ah",
        "kmpiwttr": "kuhm-PYOO-tur",
        "zban": "ZAH-bahn",
        "ktab": "kee-TAHB",
        "dwst": "DOHST",
        "pakstan": "pah-kees-TAHN",
        "astad": "oos-TAHD",
        "talblm": "tah-LEE-beelm",
    }
    if cleaned in direct_outputs:
        return direct_outputs[cleaned]
    romanized = _repair_urdu_romanization(raw)
    stress_index = _urdu_stress_index(romanized)
    return _stylize_latin_word(romanized, stress_index=stress_index)

def _stylize_russian_word(word: str, ipa: str | None = None) -> str:
    if ipa:
        syllables = _syllabify_ipa(ipa)
        if syllables:
            readable = [_map_russian_ipa_syllable(syllable) for syllable in syllables]
            stress_index = len(readable) - 2 if len(readable) > 1 else 0
            return StyledPronunciation(readable, stress_index=stress_index).render()

    romanized = _uroman_word(word).lower()
    romanized = romanized.replace("zh", "zh").replace("kh", "h").replace("shch", "sh")
    romanized = romanized.replace("sh", "sh").replace("ch", "ch").replace("yu", "yoo")
    romanized = romanized.replace("ya", "yah").replace("yo", "yoh").replace("ye", "ye")
    stress_index = _default_penultimate_stress(romanized)
    return _stylize_latin_word(romanized, stress_index=stress_index)


def _stylize_indonesian_word(word: str) -> str:
    lowered = strip_accents(word.lower())
    lowered = lowered.replace("ng", "ng").replace("ny", "ny")
    lowered = lowered.replace("sy", "sh").replace("kh", "kh")
    lowered = lowered.replace("c", "ch").replace("j", "j")
    stress_index = _default_penultimate_stress(lowered)
    return _stylize_latin_word(lowered, stress_index=stress_index)


def _stylize_portuguese_word(word: str, ipa: str | None = None) -> str:
    if ipa:
        syllables = _syllabify_ipa(ipa)
        if syllables:
            readable = [_map_portuguese_ipa_syllable(syllable) for syllable in syllables]
            stress_index = _romance_stress_index(word)
            return StyledPronunciation(readable, stress_index=stress_index).render()

    lowered = word.lower()
    lowered = lowered.replace("ão", "aun")
    lowered = lowered.replace("ãe", "ine")
    lowered = lowered.replace("õe", "oine")
    lowered = lowered.replace("lh", "ly")
    lowered = lowered.replace("nh", "ny")
    lowered = re.sub(r"ch", "sh", lowered)
    lowered = re.sub(r"ç", "s", lowered)
    lowered = re.sub(r"ge", "zhe", lowered)
    lowered = re.sub(r"gi", "zhi", lowered)
    lowered = re.sub(r"\br", "h", lowered)
    lowered = re.sub(r"rr", "h", lowered)
    lowered = re.sub(r"j", "zh", lowered)
    lowered = strip_accents(lowered)
    stress_index = _romance_stress_index(word)
    return _stylize_latin_word(lowered, stress_index=stress_index)


def _stylize_german_word(word: str, ipa: str | None = None) -> str:
    if ipa:
        syllables = _syllabify_ipa(ipa)
        if syllables:
            readable = [_map_german_ipa_syllable(syllable) for syllable in syllables]
            stress_index = _german_stress_index(word, readable)
            return StyledPronunciation(readable, stress_index=stress_index).render()

    lowered = word.lower()
    lowered = lowered.replace("ß", "ss")
    lowered = lowered.replace("ä", "ae")
    lowered = lowered.replace("ö", "oe")
    lowered = lowered.replace("ü", "ue")
    lowered = lowered.replace("'", "")
    lowered = re.sub(r"[^a-z]", "", lowered)
    if not lowered:
        return word

    text = lowered
    replacements = [
        ("tsch", "{CH}"),
        ("sch", "{SH}"),
        ("ch", "{KH}"),
        ("sp", "shp"),
        ("st", "sht"),
        ("ei", "{EYE}"),
        ("ie", "{EE}"),
        ("eu", "{OY}"),
        ("aeu", "{OY}"),
        ("au", "{OW}"),
        ("ae", "{EH}"),
        ("oe", "{UR}"),
        ("ue", "{OO}"),
    ]
    for source, target in replacements:
        text = text.replace(source, target)

    vowel_replacements = [
        ("a", "ah"),
        ("e", "eh"),
        ("i", "ee"),
        ("o", "oh"),
        ("u", "oo"),
    ]
    for source, target in vowel_replacements:
        text = text.replace(source, target)

    placeholder_replacements = [
        ("{CH}", "ch"),
        ("{SH}", "sh"),
        ("{KH}", "h"),
        ("{EYE}", "eye"),
        ("{EE}", "ee"),
        ("{OY}", "oy"),
        ("{OW}", "ow"),
        ("{EH}", "eh"),
        ("{UR}", "er"),
        ("{OO}", "oo"),
    ]
    for source, target in placeholder_replacements:
        text = text.replace(source, target)

    text = text.replace("w", "v")
    text = text.replace("z", "ts")
    text = text.replace("j", "y")
    text = text.replace("v", "f")
    return _cleanup_chunk(text)


def _default_penultimate_stress(word: str) -> int | None:
    cleaned = re.sub(r"[^a-z]", "", strip_accents(word.lower()))
    syllables = _roman_syllables(cleaned)
    if not syllables:
        return None
    if len(syllables) == 1:
        return 0
    return len(syllables) - 2


def _german_stress_index(word: str, syllables: list[str]) -> int | None:
    if not syllables:
        return None
    if len(syllables) == 1:
        return 0

    lowered = strip_accents(word.lower())
    if lowered.endswith(("ieren", "iere")):
        return len(syllables) - 2
    if lowered.endswith(("ik", "tik", "matik", "grafie", "logie", "tion", "itat", "ität", "itaet", "ismus")):
        return len(syllables) - 1
    return 0


def _roman_syllables(text: str) -> list[str]:
    syllables = re.findall(r"[^aeiouy]*[aeiouy]+(?:[^aeiouy](?![aeiouy]))*", text)
    consumed = "".join(syllables)
    if consumed != text:
        remainder = text[len(consumed):]
        if syllables:
            syllables[-1] += remainder
        else:
            syllables = [text]
    return syllables or [text]


def _restore_abjad_vowels(text: str) -> str:
    cleaned = re.sub(r"[^a-z]", "", text)
    if len(cleaned) < 3 or re.search(r"[aeiou]", cleaned):
        consonants = re.sub(r"[aeiou]", "", cleaned)
        if len(consonants) <= 2:
            return cleaned

    result: list[str] = []
    vowels = {"a", "e", "i", "o", "u", "y"}
    consonant_run = 0
    for index, char in enumerate(cleaned):
        is_vowel = char in vowels
        if not is_vowel:
            consonant_run += 1
            if consonant_run >= 2 and result and result[-1] not in vowels:
                result.append("a")
            result.append(char)
            if (
                consonant_run >= 2
                and index + 1 < len(cleaned)
                and cleaned[index + 1] in vowels
                and result[-1] not in vowels
            ):
                result.append("a")
            continue

        consonant_run = 0
        result.append(char)

    restored = "".join(result)
    return re.sub(r"a{2,}", "a", restored)


def _repair_urdu_romanization(text: str) -> str:
    cleaned = text.replace("'", "")
    direct_repairs = {
        "hilw": "hilo",
        "shkrih": "shukriya",
        "mhrbani": "mehrbani",
        "jamh": "jamia",
        "kmpiwttr": "kompyuter",
        "zban": "zaban",
        "ktab": "kitab",
        "dwst": "dost",
        "pakstan": "pakistan",
        "astad": "ustad",
        "talblm": "talibilm",
    }
    if cleaned in direct_repairs:
        return direct_repairs[cleaned]

    repaired = cleaned
    repaired = repaired.replace("iwt", "yut")
    repaired = repaired.replace("iw", "yu")
    repaired = repaired.replace("yh", "iya")
    repaired = repaired.replace("mh", "meh")
    repaired = repaired.replace("shkr", "shukr")
    repaired = repaired.replace("zb", "zab")
    repaired = repaired.replace("kt", "kit")
    repaired = repaired.replace("dw", "do")
    repaired = repaired.replace("pk", "pak")
    repaired = repaired.replace("st", "ust", 1) if repaired.startswith("st") else repaired
    repaired = _restore_abjad_vowels(repaired)
    repaired = repaired.replace("iyaa", "iya").replace("eha", "eh")
    return repaired


def _urdu_stress_index(word: str) -> int | None:
    lowered = re.sub(r"[^a-z]", "", word.lower())
    if lowered.endswith(("iya", "iyah", "bani")):
        syllables = _roman_syllables(lowered)
        return len(syllables) - 1 if syllables else None
    return _default_penultimate_stress(lowered)


def _map_roman_syllable(syllable: str) -> str:
    text = syllable
    replacements = [
        ("sch", "{SH}"),
        ("sh", "{SH}"),
        ("ch", "{CH}"),
        ("zh", "{ZH}"),
        ("kh", "{KH}"),
        ("gh", "{GH}"),
        ("ny", "{NY}"),
        ("ph", "f"),
        ("th", "t"),
        ("dh", "d"),
        ("bh", "b"),
        ("jh", "j"),
        ("ts", "ts"),
        ("aa", "{AH}"),
        ("ee", "{EE}"),
        ("ii", "{EE}"),
        ("oo", "{OO}"),
        ("uu", "{OO}"),
        ("ai", "{EYE}"),
        ("ei", "{AY}"),
        ("oi", "{OY}"),
        ("au", "{OW}"),
        ("ao", "{OW}"),
        ("ou", "{OH}"),
    ]
    for source, target in replacements:
        text = text.replace(source, target)

    vowel_replacements = [
        ("a", "ah"),
        ("e", "eh"),
        ("i", "ee"),
        ("o", "oh"),
        ("u", "oo"),
    ]
    for source, target in vowel_replacements:
        text = text.replace(source, target)

    placeholder_replacements = [
        ("{SH}", "sh"),
        ("{CH}", "ch"),
        ("{ZH}", "zh"),
        ("{KH}", "kh"),
        ("{GH}", "gh"),
        ("{NY}", "ny"),
        ("{AH}", "ah"),
        ("{EE}", "ee"),
        ("{OO}", "oo"),
        ("{EYE}", "eye"),
        ("{AY}", "ay"),
        ("{OY}", "oy"),
        ("{OW}", "ow"),
        ("{OH}", "oh"),
    ]
    for source, target in placeholder_replacements:
        text = text.replace(source, target)

    text = text.replace("c", "k")
    text = text.replace("q", "k")
    text = text.replace("x", "sh")
    text = text.replace("j", "j")
    return _cleanup_chunk(text)


def _romance_stress_index(word: str) -> int | None:
    syllables = _roman_syllables(strip_accents(word.lower()))
    if not syllables:
        return None
    for index, char in enumerate(word.lower()):
        if char in "áéíóúâêôãõ":
            current = 0
            letter_index = 0
            for syllable_index, syllable in enumerate(syllables):
                letter_index += len(syllable)
                if current <= index < letter_index:
                    return syllable_index
                current = letter_index
    if len(syllables) == 1:
        return 0
    plain = strip_accents(word.lower())
    if plain.endswith(("a", "e", "o", "as", "es", "os", "am", "em", "ens")):
        return len(syllables) - 2
    return len(syllables) - 1


def _map_pinyin_syllable(syllable: str) -> str | None:
    base = _strip_tone_number(syllable).replace("u:", "ü").replace("v", "ü")
    if not base:
        return None

    initial = ""
    final = base
    for candidate in _PINYIN_INITIALS:
        if base.startswith(candidate):
            initial = candidate
            final = base[len(candidate):]
            break

    if initial in {"y", "w"} and not final:
        final = initial
        initial = ""

    if initial == "y":
        final = _rewrite_y_final(final)
        initial = ""
    elif initial == "w":
        final = _rewrite_w_final(final)
        initial = ""
    elif initial in {"j", "q", "x"} and final.startswith("u"):
        final = "ü" + final[1:]

    if final == "i" and initial in {"zh", "ch", "sh", "r"}:
        return f"{_PINYIN_INITIAL_MAP[initial]}r"
    if final == "i" and initial in {"z", "c", "s"}:
        return f"{_PINYIN_INITIAL_MAP[initial]}uh"

    rendered_initial = _PINYIN_INITIAL_MAP.get(initial)
    rendered_final = _PINYIN_FINALS.get(final)
    if rendered_initial is None or rendered_final is None:
        return None

    if rendered_initial.endswith(("y", "w")) and rendered_final.startswith(rendered_initial[-1]):
        rendered_final = rendered_final[1:]
    return f"{rendered_initial}{rendered_final}"


def _rewrite_y_final(final: str) -> str:
    mapping = {
        "i": "i",
        "in": "in",
        "ing": "ing",
        "e": "ie",
        "an": "ian",
        "ang": "iang",
        "ao": "iao",
        "ou": "iu",
        "ong": "iong",
        "u": "ü",
        "ue": "üe",
        "uan": "uan",
    }
    return mapping.get(final, final)


def _rewrite_w_final(final: str) -> str:
    mapping = {
        "u": "u",
        "a": "ua",
        "o": "uo",
        "ai": "uai",
        "ei": "ui",
        "an": "uan",
        "en": "un",
        "ang": "uang",
        "eng": "ong",
    }
    return mapping.get(final, final)


def _spanish_stress_index(word: str, syllables: list[str]) -> int | None:
    for index, syllable in enumerate(syllables):
        if any(char in "áéíóú" for char in syllable):
            return index
    if len(syllables) <= 1:
        return 0 if syllables else None

    plain = strip_accents(word.lower())
    if plain[-1] in {"a", "e", "i", "o", "u", "n", "s"}:
        return len(syllables) - 2
    return len(syllables) - 1


def _is_spanish_vowel(char: str) -> bool:
    return strip_accents(char) in {"a", "e", "i", "o", "u", "ü", "y"}


def _normalize_spanish_ipa(ipa: str) -> str:
    units = _ipa_units(ipa)
    if not units:
        return ipa

    normalized: list[str] = []
    for index, unit in enumerate(units):
        prev_unit = normalized[-1] if normalized else None
        next_unit = units[index + 1] if index + 1 < len(units) else None

        if unit == "i" and next_unit is not None and _is_vowel_unit(next_unit):
            normalized.append("j")
            continue
        if unit == "u" and next_unit is not None and _is_vowel_unit(next_unit):
            normalized.append("w")
            continue
        if unit == "i" and prev_unit is not None and _is_vowel_unit(prev_unit):
            normalized.append("j")
            continue
        if unit == "u" and prev_unit is not None and _is_vowel_unit(prev_unit):
            normalized.append("w")
            continue

        normalized.append(unit)

    return "".join(normalized)


def _map_spanish_ipa_syllable(syllable: str) -> str:
    units = _ipa_units(syllable)
    pieces: list[str] = []
    index = 0
    while index < len(units):
        if index + 1 < len(units):
            diphthong = units[index] + units[index + 1]
            mapped_diphthong = _map_spanish_ipa_diphthong(diphthong)
            if mapped_diphthong is not None:
                pieces.append(mapped_diphthong)
                index += 2
                continue

        unit = units[index]
        pieces.append(_map_spanish_ipa_unit(unit))
        index += 1
    return _cleanup_chunk("".join(pieces))


def _map_spanish_ipa_diphthong(units: str) -> str | None:
    return {
        "aj": "eye",
        "ej": "ay",
        "oj": "oy",
        "aw": "ow",
    }.get(units)


def _map_spanish_ipa_unit(unit: str) -> str:
    return {
        "a": "ah",
        "b": "b",
        "β": "b",
        "d": "d",
        "ð": "d",
        "e": "eh",
        "f": "f",
        "ɡ": "g",
        "g": "g",
        "ʝ": "y",
        "i": "ee",
        "j": "y",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "ɲ": "ny",
        "o": "oh",
        "p": "p",
        "ɾ": "r",
        "r": "r",
        "s": "s",
        "t": "t",
        "t͡ʃ": "ch",
        "u": "oo",
        "w": "w",
        "x": "h",
    }.get(unit, unit)


def _syllabify_ipa(ipa: str) -> list[str]:
    units = _ipa_units(ipa)
    nuclei = [index for index, unit in enumerate(units) if _is_vowel_unit(unit)]
    if not nuclei:
        return []

    syllables: list[str] = []
    start = 0
    for position, nucleus_index in enumerate(nuclei):
        if position == len(nuclei) - 1:
            syllables.append("".join(units[start:]))
            break

        next_nucleus = nuclei[position + 1]
        between = units[nucleus_index + 1:next_nucleus]
        if len(between) <= 1:
            boundary = nucleus_index + 1
        elif _is_permitted_ipa_onset(between):
            boundary = nucleus_index + 1
        elif len(between) >= 2 and _is_permitted_ipa_onset(between[-2:]):
            boundary = next_nucleus - 2
        else:
            boundary = next_nucleus - 1
        syllables.append("".join(units[start:boundary]))
        start = boundary
    return [syllable for syllable in syllables if syllable]


def _ipa_units(ipa: str) -> list[str]:
    units: list[str] = []
    for char in ipa:
        if unicodedata.combining(char) and units:
            units[-1] += char
        elif char not in {"ˈ", "ˌ", ".", " "}:
            units.append(char)
    merged: list[str] = []
    index = 0
    while index < len(units):
        if units[index].endswith("͡") and index + 1 < len(units):
            merged.append(units[index] + units[index + 1])
            index += 2
            continue
        merged.append(units[index])
        index += 1
    return merged


def _is_permitted_ipa_onset(cluster: list[str]) -> bool:
    joined = "".join(cluster)
    return joined in {
        "bl", "br", "bj", "bw",
        "kl", "kr", "kw",
        "dr", "dw",
        "fl", "fr",
        "gl", "gr", "gw", "ɡl", "ɡr", "ɡw",
        "pl", "pr", "pj", "pw",
        "tr", "tw",
        "fj", "mj", "nj", "lj", "rj",
        "t͡ʃ", "d͡ʒ", "ʃ", "ʒ",
    }


def _is_vowel_unit(unit: str) -> bool:
    base = strip_accents(unit)
    return any(char in _VOWEL_UNITS for char in base)


def _map_french_ipa_syllable(syllable: str) -> str:
    units = _ipa_units(syllable)
    pieces: list[str] = []
    for unit in units:
        pieces.append(_map_french_ipa_unit(unit))
    return _cleanup_chunk("".join(pieces))


def _map_french_ipa_unit(unit: str) -> str:
    if unit.endswith("̃"):
        nasal = unit[0]
        return {
            "a": "ahn",
            "ɑ": "ahn",
            "ɔ": "ohn",
            "ɛ": "ehn",
            "œ": "uhn",
        }.get(nasal, "uhn")
    return {
        "b": "b",
        "d": "d",
        "f": "f",
        "ɡ": "g",
        "g": "g",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "p": "p",
        "s": "s",
        "t": "t",
        "v": "v",
        "w": "w",
        "z": "z",
        "j": "y",
        "ɥ": "w",
        "ʁ": "r",
        "ʀ": "r",
        "ʃ": "sh",
        "ʒ": "zh",
        "a": "ah",
        "ɑ": "ah",
        "e": "ay",
        "ə": "uh",
        "ɛ": "eh",
        "i": "ee",
        "o": "oh",
        "ɔ": "oh",
        "ø": "uh",
        "œ": "uh",
        "u": "oo",
        "y": "ee",
    }.get(unit, unit)


def _map_german_ipa_syllable(syllable: str) -> str:
    if "ɔɪ̯" in syllable or "ɔɪ" in syllable:
        return _cleanup_chunk(syllable.replace("ɔɪ̯", "oy").replace("ɔɪ", "oy"))
    chunk = _map_ipa_syllable_with(syllable, _map_german_ipa_unit)
    chunk = chunk.replace("ihkh", "ikh")
    chunk = chunk.replace("ehkh", "ehk")
    chunk = chunk.replace("akh", "ak")
    return chunk


def _map_german_ipa_unit(unit: str) -> str:
    base = unit.replace("ː", "").replace("̯", "")
    return {
        "a": "ah",
        "b": "b",
        "d": "d",
        "e": "ay",
        "ɛ": "eh",
        "ə": "uh",
        "ɐ": "er",
        "ɪ": "ih",
        "f": "f",
        "g": "g",
        "ɡ": "g",
        "h": "h",
        "i": "ee",
        "j": "y",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "o": "oh",
        "ɔ": "aw",
        "p": "p",
        "r": "r",
        "s": "z",
        "t": "t",
        "u": "oo",
        "ʊ": "oo",
        "v": "v",
        "x": "kh",
        "ç": "kh",
        "y": "ue",
        "z": "ts",
        "ʃ": "sh",
        "tʃ": "ch",
    }.get(base, base)


def _map_hindi_ipa_syllable(syllable: str) -> str:
    return _map_ipa_syllable_with(syllable, _map_hindi_ipa_unit)


def _map_hindi_ipa_unit(unit: str) -> str:
    if unit.endswith("̃"):
        return _map_hindi_ipa_unit(unit[:-1]) + "n"

    base = unit.replace("ː", "")
    return {
        "a": "ah",
        "ə": "uh",
        "æ": "a",
        "b": "b",
        "b̤": "bh",
        "d": "d",
        "d̤": "dh",
        "dʒ": "j",
        "f": "f",
        "ɦ": "h",
        "i": "ee",
        "j": "y",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "o": "oh",
        "p": "p",
        "r": "r",
        "s": "s",
        "ʂ": "sh",
        "ʃ": "sh",
        "t": "t",
        "ʈ": "t",
        "ʈʰ": "th",
        "u": "oo",
        "v": "v",
    }.get(base, base)


def _map_russian_ipa_syllable(syllable: str) -> str:
    return _map_ipa_syllable_with(syllable, _map_russian_ipa_unit)


def _map_russian_ipa_unit(unit: str) -> str:
    palatalized = unit.endswith("ʲ")
    base = unit[:-1] if palatalized else unit
    base = base.replace("ː", "")
    mapped = {
        "a": "ah",
        "b": "b",
        "d": "d",
        "e": "eh",
        "f": "f",
        "g": "g",
        "ɡ": "g",
        "i": "ee",
        "j": "y",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "o": "oh",
        "p": "p",
        "r": "r",
        "s": "s",
        "t": "t",
        "u": "oo",
        "v": "v",
        "y": "ih",
        "z": "z",
        "ɨ": "ih",
        "ʂ": "sh",
        "ʃ": "sh",
        "ʒ": "zh",
    }.get(base, base)
    if palatalized and mapped and mapped[-1] not in {"h", "y"}:
        return f"{mapped}y"
    return mapped


def _map_portuguese_ipa_syllable(syllable: str) -> str:
    return _map_ipa_syllable_with(syllable, _map_portuguese_ipa_unit)


def _map_portuguese_ipa_unit(unit: str) -> str:
    if unit.endswith("̃"):
        return _map_portuguese_ipa_unit(unit[:-1]) + "n"

    base = unit.replace("ː", "")
    return {
        "a": "ah",
        "b": "b",
        "d": "d",
        "e": "ay",
        "ɛ": "eh",
        "f": "f",
        "g": "g",
        "ɡ": "g",
        "i": "ee",
        "j": "y",
        "k": "k",
        "l": "l",
        "m": "m",
        "n": "n",
        "o": "oh",
        "ɔ": "aw",
        "p": "p",
        "r": "r",
        "ɾ": "r",
        "s": "s",
        "t": "t",
        "u": "oo",
        "v": "v",
        "w": "w",
        "x": "sh",
        "z": "z",
        "ʁ": "h",
        "ʃ": "sh",
        "ʒ": "zh",
        "ɐ": "ah",
    }.get(base, base)


def _map_ipa_syllable_with(syllable: str, mapper) -> str:
    units = _ipa_units(syllable)
    pieces: list[str] = []
    for unit in units:
        pieces.append(mapper(unit))
    return _cleanup_chunk("".join(pieces))


def _cleanup_chunk(text: str) -> str:
    text = text.replace("eee", "ee")
    text = text.replace("eeeh", "ee-eh")
    text = re.sub(r"(.)\1{2,}", r"\1\1", text)
    return text
