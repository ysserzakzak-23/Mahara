"""Tests for the per-trade synonyms sent to the embedding model."""
import pytest

from app.utils import trade_synonyms as ts
from app.utils.arabic_search import DOMAINS, tokenize


def _single_words():
    return [
        (trade, entry)
        for trade, entries in ts.TRADE_SYNONYMS.items()
        for entry in entries
        if len(tokenize(entry)) == 1
    ]


def test_every_trade_has_synonyms_and_nothing_else_does():
    """The trades are the category names (scripts/seed_categories.py seeds
    them from DOMAINS), so this is «every category of the app»."""
    assert set(ts.TRADE_SYNONYMS) == set(DOMAINS)
    assert all(ts.TRADE_SYNONYMS.values())


def test_every_trade_can_be_reached_by_at_least_one_word():
    for trade, entries in ts.TRADE_SYNONYMS.items():
        assert any(ts._trigger_stem(entry) for entry in entries), trade


@pytest.mark.parametrize("trade, word", _single_words())
def test_each_word_points_to_its_own_trade_only(trade, word):
    """Also proves no single word was silently dropped as too short/generic."""
    assert ts.trades_in(word) == {trade}


@pytest.mark.parametrize(
    "word",
    ["شاشة", "شعر", "طباخ", "براد", "ثلاجة", "معلم", "البرنامج", "الأكل",
     "تصليح", "خدمة", "صيانة"],
)
def test_ambiguous_or_generic_words_name_no_trade(word):
    assert ts.trades_in(word) == frozenset()


@pytest.mark.parametrize(
    "query, expected",
    [
        # «معلم» is the master craftsman here, not a teacher. Since «مجلى»
        # became a سباكة trigger (2026-11-20) this query names the trade the
        # craftsman is wanted for, which is what the module docstring says it
        # means; what it still proves is that «معلم» drags in no تعليم ودروس.
        ("بدي معلم يركب لي مجلى", {"سباكة"}),
        # the washing machine's cycle, not software
        ("الغسالة بتوقف بنص البرنامج", {"صيانة أجهزة منزلية"}),
        # «الكتروني» shares its stem with «إلكترونيات»: a website, not a repair
        ("بدي موقع الكتروني لمشروعي", {"برمجة وتطوير"}),
        # «رياضيات» shares its stem with «رياضة»: maths lessons, not a gym
        ("بدي مدرس رياضيات", {"تعليم ودروس"}),
        # the food going off, not a caterer
        ("البراد ما عم يبرد والأكل عم يخرب", frozenset()),
    ],
)
def test_words_with_two_meanings_do_not_pick_the_wrong_trade(query, expected):
    """Each of these was measured pulling the wrong listings to the top."""
    assert ts.trades_in(query) == expected


def test_core_words_are_the_ones_expand_sends():
    """Listings reuse these for their identity chunk (semantic_search_service
    ._searchable_chunks), so they have to be the same words a query gets."""
    core = ts.core_words("سباكة")
    assert core == ("سباك", "حنفية", "مواسير")
    expanded = ts.expand("حنفية").split()
    assert all(word in expanded for word in core)
    assert ts.core_words("أخرى") == ()              # a catch-all has no trade words
    assert ts.core_words("not a trade at all") == ()


def test_matching_is_exact_not_fuzzy():
    """«جميع» (all) is one letter off «تجميع» (assembling a PC). The lexical
    engine's typo tolerance read one as the other; this matcher must not."""
    assert ts.trades_in("جميع") == frozenset()
    assert ts.trades_in("تركيب وصيانة جميع انواع الاقفال") == {"أمن وأقفال"}


def test_phrases_give_meaning_but_never_trigger():
    """«تجميع كمبيوتر» is a phrase of صيانة حواسيب; «تجميع» alone is not a trigger."""
    assert ts._trigger_stem("تجميع كمبيوتر") is None
    assert ts.trades_in("تجميع") == frozenset()


@pytest.mark.parametrize(
    "query, trade",
    [
        ("جوال", "صيانة جوالات"),
        ("الموبايل", "صيانة جوالات"),
        ("بدي حدا يصلحلي الموبايل", "صيانة جوالات"),
        ("كمبيوتر", "صيانة حواسيب"),
        ("وين في حنفيات", "سباكة"),
        ("بالسيارة", "سيارات"),
    ],
)
def test_the_way_people_write_still_finds_the_trade(query, trade):
    assert ts.trades_in(query) == {trade}


def test_a_query_that_names_no_trade_is_sent_as_it_is():
    assert ts.expand("  شي ما بينعرف ") == "شي ما بينعرف"


def test_the_expansion_is_the_query_then_the_trade_and_three_of_its_words():
    assert ts.expand("جوال") == "جوال جوالات جوال موبايل هاتف"


def test_general_words_are_left_out_of_the_trade_name():
    """«صيانة» is in every repair listing: with it, «كمبيوتر» read as close to
    a locksmith who does «تركيب وصيانة» (0.331 with MiniLM, over the cut-off)."""
    assert ts._NAMES["صيانة حواسيب"] == "حواسيب"
    assert ts._NAMES["صيانة أجهزة منزلية"] == "أجهزة منزلية"
    assert ts._NAMES["خدمات مكتبية وقانونية"] == "مكتبية وقانونية"
    assert ts._NAMES["سباكة"] == "سباكة"
    assert "صيانة" not in ts.expand("كمبيوتر")
    assert all(ts._NAMES[trade] for trade in ts.TRADE_SYNONYMS)    # never empty


def test_only_a_few_words_are_embedded_so_the_query_is_not_drowned():
    """
    The whole list made «مدرس لغة انجليزية» read as "a teacher": the science
    tutor overtook the English one. On the 29-query set (MiniLM) the whole
    list gets 14/29 first, three words 18/29. The rest of the list still triggers the
    trade.
    """
    assert ts._CORE_WORDS == 3
    assert ts.trades_in("تلفون") == {"صيانة جوالات"}
    assert "تلفون" not in ts.expand("تلفون").split()[1:]


def test_the_core_words_are_three_different_words_of_the_trade():
    for trade, core in ts._CORE.items():
        stems = [ts._trigger_stem(word) for word in core]
        assert len(core) == ts._CORE_WORDS, trade
        assert None not in stems and len(set(stems)) == len(stems), trade
        assert all(word in ts.TRADE_SYNONYMS[trade] for word in core), trade


def test_only_this_dictionary_decides_the_expansion():
    """
    The keyword engine's knowledge base reads «البرنامج» (a washing-machine
    cycle) as programming. It no longer has a say: only the triggers here do.
    """
    text = ts.expand("الغسالة بتوقف بنص البرنامج")
    assert text == "الغسالة بتوقف بنص البرنامج أجهزة منزلية غسالة جلاية فرن"


def test_a_trade_is_expanded_once_and_the_order_is_stable():
    once = ts.expand("جوال موبايل")
    assert once == "جوال موبايل جوالات جوال موبايل هاتف"
    both = ts.expand("كمبيوتر جوال")
    assert both == ts.expand("كمبيوتر جوال")
    assert both.index("جوالات") < both.index("حواسيب")
