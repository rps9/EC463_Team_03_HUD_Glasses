#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from hudini_phonemizer import analyze_pronunciation
from hudini_phonemizer.exceptions import PHRASE_EXCEPTIONS
from hudini_phonemizer.style import is_word_token, normalize_lookup_key, split_tokens


REPO_ROOT = Path(__file__).resolve().parent
BENCHMARKS_DIR = REPO_ROOT / "tests" / "benchmarks"


def load_benchmarks() -> list[dict]:
    return [json.loads(path.read_text()) for path in sorted(BENCHMARKS_DIR.glob("*.json"))]


def is_single_word_case(text: str) -> bool:
    tokens = split_tokens(text)
    word_tokens = [token for token in tokens if is_word_token(token)]
    non_space_tokens = [token for token in tokens if not token.isspace()]
    return len(word_tokens) == 1 and len(word_tokens) == len(non_space_tokens)


def summarize_benchmark(benchmark: dict) -> dict[str, object]:
    language = benchmark["language"]
    cases = benchmark["cases"]
    traces = [analyze_pronunciation(case["text"], language) for case in cases]
    language_exceptions = PHRASE_EXCEPTIONS.get(language, {})

    total_cases = len(cases)
    holdout_cases = [case for case in cases if case["split"] == "holdout"]
    holdout_traces = [analyze_pronunciation(case["text"], language) for case in holdout_cases]
    rule_families = {case["rule_family"] for case in cases}
    average_exception_dependency = sum(trace.exception_dependency_rate for trace in traces) / total_cases
    phrase_exception_hits = sum(trace.phrase_exception_hit for trace in traces)
    word_exception_hits = sum(trace.word_exception_hits for trace in traces)
    direct_rule_cases = sum(trace.exception_dependency_rate < 1.0 for trace in traces)
    holdout_direct_rule_cases = sum(trace.exception_dependency_rate < 1.0 for trace in holdout_traces)
    memorized_single_word_cases = sum(
        1
        for case in cases
        if is_single_word_case(case["text"]) and normalize_lookup_key(case["text"]) in language_exceptions
    )
    memorized_single_word_holdouts = sum(
        1
        for case in holdout_cases
        if is_single_word_case(case["text"]) and normalize_lookup_key(case["text"]) in language_exceptions
    )

    return {
        "language": language,
        "total_cases": total_cases,
        "holdout_cases": len(holdout_cases),
        "rule_families": len(rule_families),
        "required_rule_families": len(benchmark["required_rule_families"]),
        "average_exception_dependency": average_exception_dependency,
        "phrase_exception_hits": phrase_exception_hits,
        "word_exception_hits": word_exception_hits,
        "direct_rule_cases": direct_rule_cases,
        "holdout_direct_rule_cases": holdout_direct_rule_cases,
        "memorized_single_word_cases": memorized_single_word_cases,
        "memorized_single_word_holdouts": memorized_single_word_holdouts,
    }


def write_review_template(output_path: Path, benchmarks: list[dict]) -> None:
    with output_path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "language",
                "text",
                "expected",
                "rule_family",
                "split",
                "stress_score",
                "syllable_score",
                "readability_score",
                "misleading_chunks",
                "notes",
            ],
        )
        writer.writeheader()
        for benchmark in benchmarks:
            for case in benchmark["cases"]:
                if case["split"] != "holdout":
                    continue
                writer.writerow(
                    {
                        "language": benchmark["language"],
                        "text": case["text"],
                        "expected": case["expected"],
                        "rule_family": case["rule_family"],
                        "split": case["split"],
                    }
                )


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize per-language pronunciation benchmark coverage.")
    parser.add_argument(
        "--write-review-template",
        type=Path,
        help="Optional CSV path for a human-review template of holdout cases.",
    )
    args = parser.parse_args()

    benchmarks = load_benchmarks()
    summaries = [summarize_benchmark(benchmark) for benchmark in benchmarks]

    header = (
        f"{'lang':<4} {'cases':>5} {'hold':>5} {'rules':>5} "
        f"{'direct':>6} {'hold_direct':>11} {'exc_rate':>9} {'phrase_exc':>10} {'word_exc':>8} {'mem_all':>8} {'mem_hold':>9}"
    )
    print(header)
    print("-" * len(header))
    for summary in summaries:
        print(
            f"{summary['language']:<4} "
            f"{summary['total_cases']:>5} "
            f"{summary['holdout_cases']:>5} "
            f"{summary['rule_families']:>2}/{summary['required_rule_families']:<2} "
            f"{summary['direct_rule_cases']:>6} "
            f"{summary['holdout_direct_rule_cases']:>11} "
            f"{summary['average_exception_dependency']:>9.2f} "
            f"{summary['phrase_exception_hits']:>10} "
            f"{summary['word_exception_hits']:>8} "
            f"{summary['memorized_single_word_cases']:>8} "
            f"{summary['memorized_single_word_holdouts']:>9}"
        )

    if args.write_review_template is not None:
        write_review_template(args.write_review_template, benchmarks)
        print(f"\nWrote review template to {args.write_review_template}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
