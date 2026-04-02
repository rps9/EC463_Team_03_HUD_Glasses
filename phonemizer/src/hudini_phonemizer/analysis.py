from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PronunciationTrace:
    language_code: str
    input_text: str
    normalized_text: str
    output: str
    word_token_count: int
    phrase_exception_hit: bool
    span_exception_hits: int
    word_exception_hits: int
    exception_token_hits: int
    proper_noun_override_hits: int

    @property
    def direct_rule_token_count(self) -> int:
        return max(0, self.word_token_count - self.exception_token_hits)

    @property
    def exception_dependency_rate(self) -> float:
        if self.word_token_count == 0:
            return 0.0
        return self.exception_token_hits / self.word_token_count
