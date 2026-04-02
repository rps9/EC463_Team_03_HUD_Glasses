from __future__ import annotations

import json
from pathlib import Path

import pytest

from hudini_phonemizer import analyze_pronunciation, phoneticize
from hudini_phonemizer.exceptions import PHRASE_EXCEPTIONS
from hudini_phonemizer.style import is_word_token, normalize_lookup_key, split_tokens


BENCHMARKS_DIR = Path(__file__).parent / "benchmarks"


def _load_benchmark(path: Path) -> dict:
    return json.loads(path.read_text())


def _benchmark_paths() -> list[Path]:
    return sorted(BENCHMARKS_DIR.glob("*.json"))


def _is_single_word_case(text: str) -> bool:
    tokens = split_tokens(text)
    word_tokens = [token for token in tokens if is_word_token(token)]
    return len(word_tokens) == 1 and len(word_tokens) == len([token for token in tokens if not token.isspace()])


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_benchmark_cases_match_expected_outputs(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    language = benchmark["language"]
    for case in benchmark["cases"]:
        assert phoneticize(case["text"], language) == case["expected"]


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_benchmark_rule_family_metadata_is_complete(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    required = set(benchmark["required_rule_families"])
    present = {case["rule_family"] for case in benchmark["cases"]}
    assert required <= present


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_benchmark_has_holdout_cases(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    holdout_cases = [case for case in benchmark["cases"] if case["split"] == "holdout"]
    minimum_holdout_cases = benchmark["thresholds"]["minimum_holdout_cases"]
    assert len(holdout_cases) >= minimum_holdout_cases


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_benchmark_exception_dependency_stays_under_threshold(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    language = benchmark["language"]
    traces = [analyze_pronunciation(case["text"], language) for case in benchmark["cases"]]
    average_exception_dependency = sum(trace.exception_dependency_rate for trace in traces) / len(traces)
    assert average_exception_dependency <= benchmark["thresholds"]["max_exception_dependency_rate"]


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_holdout_cases_still_match_expected_outputs(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    language = benchmark["language"]
    holdout_cases = [case for case in benchmark["cases"] if case["split"] == "holdout"]
    for case in holdout_cases:
        assert phoneticize(case["text"], language) == case["expected"]


@pytest.mark.parametrize("benchmark_path", _benchmark_paths(), ids=lambda path: path.stem)
def test_single_word_holdout_cases_are_not_memorized_in_phrase_exceptions(benchmark_path: Path) -> None:
    benchmark = _load_benchmark(benchmark_path)
    language = benchmark["language"]
    language_exceptions = PHRASE_EXCEPTIONS.get(language, {})
    leaked_cases = [
        case["text"]
        for case in benchmark["cases"]
        if case["split"] == "holdout"
        and _is_single_word_case(case["text"])
        and normalize_lookup_key(case["text"]) in language_exceptions
    ]
    assert leaked_cases == []
