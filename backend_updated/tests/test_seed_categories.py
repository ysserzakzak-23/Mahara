"""Tests for scripts/seed_categories.py (the planning logic, no database)."""
from scripts import seed_categories as seed
from scripts.seed_categories import Action, Existing


def kinds(actions):
    return [(a.kind, a.name) for a in actions]


def test_an_empty_database_gets_every_trade():
    actions = seed.plan([])
    assert len(actions) == len(seed.wanted_trades()) == 41
    assert {a.kind for a in actions} == {"create"}


def test_the_catalogue_is_the_one_the_search_knows():
    from app.utils.arabic_search import DOMAINS

    assert seed.wanted_trades() == list(DOMAINS)


def test_existing_trades_are_left_alone():
    existing = [Existing(1, "سباكة"), Existing(2, "كهرباء")]
    names = [a.name for a in seed.plan(existing)]
    assert "سباكة" not in names and "كهرباء" not in names
    assert len(names) == 39


def test_running_it_twice_changes_nothing():
    everything = [Existing(i, name) for i, name in enumerate(seed.wanted_trades(), 1)]
    assert seed.plan(everything) == []


def test_a_similar_old_name_is_renamed_not_duplicated():
    actions = seed.plan([Existing(7, "دهان"), Existing(8, "ترجمة")])
    renames = {(a.old_name, a.name, a.category_id) for a in actions if a.kind == "rename"}
    assert renames == {("دهان", "دهان وديكور", 7), ("ترجمة", "ترجمة ولغات", 8)}
    assert ("create", "دهان وديكور") not in kinds(actions)
    assert ("create", "ترجمة ولغات") not in kinds(actions)


def test_two_old_names_for_the_same_trade_rename_only_one():
    actions = seed.plan([Existing(1, "برمجة"), Existing(2, "تطوير مواقع")])
    assert [a for a in actions if a.kind == "rename"] == [
        Action("rename", "برمجة وتطوير", category_id=1, old_name="برمجة")
    ]


def test_the_catch_all_category_is_never_touched():
    other = Existing(99, "أخرى", is_other=True)
    assert all(a.category_id != 99 for a in seed.plan([other]))
    assert all(a.name != "أخرى" for a in seed.plan([other]))


def test_an_other_category_named_like_an_alias_is_not_renamed():
    tricky = Existing(5, "دهان", is_other=True)
    assert not [a for a in seed.plan([tricky]) if a.kind == "rename"]


def test_a_switched_off_trade_is_reactivated():
    actions = seed.plan([Existing(3, "سباكة", is_active=False)])
    assert Action("reactivate", "سباكة", 3) in actions


def test_every_alias_points_to_a_real_trade():
    assert set(seed.ALIASES.values()) <= set(seed.wanted_trades())
