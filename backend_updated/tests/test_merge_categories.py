"""Tests for scripts/merge_categories.py (planning only, no database)."""
import pytest

from scripts import merge_categories as merge
from scripts.merge_categories import Cat


def targets(categories, overrides=None):
    return {item.legacy.name: item.target for item in merge.plan(categories, overrides)}


def test_english_leftovers_map_to_the_matching_trade():
    cats = [Cat(1, "Plumbing"), Cat(2, "Electrical"), Cat(3, "Painting"), Cat(4, "Cleaning"), Cat(5, "Carpentry")]
    assert targets(cats) == {
        "Plumbing": "سباكة",
        "Electrical": "كهرباء",
        "Painting": "دهان وديكور",
        "Cleaning": "تنظيف",
        "Carpentry": "نجارة",
    }


def test_older_arabic_names_map_through_the_aliases():
    cats = [Cat(1, "دهان"), Cat(2, "تنسيق حدائق"), Cat(3, "ترجمة"), Cat(4, "تعليم")]
    assert targets(cats) == {
        "دهان": "دهان وديكور",
        "تنسيق حدائق": "حدائق وزراعة",
        "ترجمة": "ترجمة ولغات",
        "تعليم": "تعليم ودروس",
    }


def test_a_spelling_variant_of_a_trade_is_recognised():
    assert targets([Cat(1, "الكترونيات")]) == {"الكترونيات": "إلكترونيات"}


def test_trades_and_the_catch_all_are_never_legacy():
    cats = [Cat(1, "سباكة"), Cat(2, "كهرباء"), Cat(9, "أخرى", is_other=True), Cat(10, "Others", is_other=True)]
    assert merge.plan(cats) == []


def test_an_unknown_category_has_no_target():
    assert targets([Cat(1, "تصليح دراجات")]) == {"تصليح دراجات": None}


def test_the_map_option_decides_when_the_script_cannot_guess():
    assert targets([Cat(1, "تصليح دراجات")], {"تصليح دراجات": "سيارات"}) == {"تصليح دراجات": "سيارات"}


def test_the_map_option_wins_over_the_built_in_guess():
    assert targets([Cat(1, "Plumbing")], {"Plumbing": "كهرباء"}) == {"Plumbing": "كهرباء"}


def test_parse_maps():
    assert merge.parse_maps(["Foo=سباكة", " بيبي = رعاية أطفال "]) == {"Foo": "سباكة", "بيبي": "رعاية أطفال"}
    with pytest.raises(SystemExit):
        merge.parse_maps(["no-equals-sign"])


def test_every_alias_target_is_a_real_trade():
    from app.utils.arabic_search import DOMAINS

    for name in ["Plumbing", "Painting", "دهان", "ترجمة", "برمجة"]:
        assert merge.resolve_target(name, set(DOMAINS)) in DOMAINS
