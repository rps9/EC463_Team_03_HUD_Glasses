from __future__ import annotations

import json
from pathlib import Path

import pytest

from hudini_phonemizer import phoneticize


FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> list[dict[str, str]]:
    return json.loads((FIXTURES_DIR / name).read_text())


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        ("gracias", "es", "GRAH-see-ahs"),
        ("bonjour", "fr", "bohn-ZHOOR"),
        ("你好", "zh", "nee-how"),
        ("ni hao", "zh", "nee-how"),
    ],
)
def test_core_examples(text: str, language: str, expected: str) -> None:
    assert phoneticize(text, language) == expected


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        ("llamas", "es", "YAH-mahs"),
        ("yo", "es", "YOH"),
        ("huevo", "es", "WEH-boh"),
        ("ciudad", "es", "syoo-DAHD"),
        ("oigo", "es", "OY-goh"),
    ],
)
def test_spanish_rule_regressions(text: str, language: str, expected: str) -> None:
    assert phoneticize(text, language) == expected


@pytest.mark.parametrize(
    "fixture_name,language",
    [
        ("ar.json", "ar"),
        ("bn.json", "bn"),
        ("de.json", "de"),
        ("es.json", "es"),
        ("fr.json", "fr"),
        ("hi.json", "hi"),
        ("id.json", "id"),
        ("pt.json", "pt"),
        ("ru.json", "ru"),
        ("ur.json", "ur"),
        ("zh.json", "zh"),
    ],
)
def test_phrase_fixtures(fixture_name: str, language: str) -> None:
    for case in _load_fixture(fixture_name):
        assert phoneticize(case["text"], language) == case["expected"]


def test_unsupported_language_raises() -> None:
    with pytest.raises(ValueError):
        phoneticize("ciao", "it")


def test_mandarin_fallback_returns_pinyin_when_mapping_fails() -> None:
    assert phoneticize("嗯", "zh") == "n"


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        ("مدرسة", "ar", "mah-dah-RAH-sah"),
        ("ভাষা", "bn", "BAHS-sah"),
        ("wunderbar", "de", "VOON-dehr-bah"),
        ("familia", "es", "fah-MEE-lyah"),
        ("fromage", "fr", "froh-MAHZH"),
        ("भारत", "hi", "BHAH-ruht"),
        ("bahasa", "id", "bah-HAH-sah"),
        ("cidade", "pt", "see-DAH-deh"),
        ("музыка", "ru", "moo-ZIH-kah"),
        ("زبان", "ur", "ZAH-bahn"),
        ("老师", "zh", "low-shr"),
        ("مكتبة", "ar", "mah-kah-TAH-bah"),
        ("trabalho", "pt", "trah-BAH-loh"),
        ("Ich", "de", "IKH"),
        ("Technische", "de", "TEHK-nih-shuh"),
    ],
)
def test_rule_layer_examples(text: str, language: str, expected: str) -> None:
    assert phoneticize(text, language) == expected


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        (
            "Ich studiere Technische Informatik.",
            "de",
            "IKH shtoo-DEE-ruh TEHK-nih-shuh ihn-fohr-mah-TEEK.",
        ),
        (
            "Me voy a graduar de la Universidad de Boston en mayo con un título en ingeniería informática.",
            "es",
            "meh voy ah grah-DWAHR deh lah oo-nee-behr-see-DAHD deh BOSS-tuhn ehn MY-oh kohn oon TEE-too-loh ehn een-heh-nyeh-REE-ah een-fohr-MAH-tee-kah.",
        ),
        (
            "Je vais obtenir mon diplôme de l'Université de Boston en mai avec un diplôme en informatique.",
            "fr",
            "zhuh vay ohb-tuh-NEER mohn dee-PLOHM duh l'ee-nee-vehr-see-TAY duh BOSS-tuhn ahn MEH ah-VEHK uhn dee-PLOHM ahn een-fohr-mah-TEEK.",
        ),
        (
            "我五月将从波士顿大学毕业，获得计算机工程学位。",
            "zh",
            "woh woo-yeh jyahng tsohng BOH-shr-dwuhn dah-shweh bee-yeh，hwoh-duhr jyee-swahn-jyee gohng-chrng shweh-way。",
        ),
    ],
)
def test_sentence_level_outputs(text: str, language: str, expected: str) -> None:
    assert phoneticize(text, language) == expected


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        ("سيارة", "ar", "SYAH-rah"),
        ("শহর", "bn", "shoh-HOH-roh"),
        ("schön", "de", "SHUHN"),
        ("acción", "es", "AHKS-yohn"),
        ("croissant", "fr", "krwah-SAHN"),
        ("pakistan", "id", "pah-KEES-tahn"),
        ("queijo", "pt", "KAY-zhoh"),
        ("учитель", "ru", "oo-CHEE-tehl"),
        ("پاکستان", "ur", "pah-kees-TAHN"),
        ("学生", "zh", "shweh-shuhng"),
    ],
)
def test_additional_generalization_examples(text: str, language: str, expected: str) -> None:
    assert phoneticize(text, language) == expected
