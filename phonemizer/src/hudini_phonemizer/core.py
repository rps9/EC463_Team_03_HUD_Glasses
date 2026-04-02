from __future__ import annotations

from .adapters import get_adapter
from .analysis import PronunciationTrace


def phoneticize(text: str, language_code: str) -> str:
    """Format foreign-language text into a stable, English-readable pronunciation string."""
    adapter = get_adapter(language_code)
    return adapter.phoneticize(text)


def analyze_pronunciation(text: str, language_code: str) -> PronunciationTrace:
    """Return pronunciation output plus trace metadata for coverage reporting."""
    adapter = get_adapter(language_code)
    return adapter.analyze(text)
