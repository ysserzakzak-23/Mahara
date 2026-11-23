"""
The smart search's speed-ups must never change a result.

arabic_search memoises its two fuzzy comparisons and skips candidates whose
length alone rules a match out. These tests compare them with difflib called
directly — every candidate, nothing remembered, exactly what the code did
before — over thousands of words, and compare whole rankings too.
"""
import random
from difflib import SequenceMatcher, get_close_matches
from functools import lru_cache

import pytest

from app.utils import arabic_search as A

LETTERS = "ابتثجحخدذرزسشصضطظعغفقكلمنهوي"


# ------------------------------------------------- reference implementations
def reference_domains_of_stem(token_stem: str) -> set[str]:
    exact = A._DOMAIN_INDEX.get(token_stem)
    if exact:
        return set(exact)
    if len(token_stem) >= 4:
        close = get_close_matches(token_stem, A._DOMAIN_STEMS, n=2, cutoff=A._FUZZY_DOMAIN_CUTOFF)
        found: set[str] = set()
        for word in close:
            found |= A._DOMAIN_INDEX[word]
        return found
    return set()


def reference_word_match(readings, stems) -> bool:
    if isinstance(readings, str):
        readings = (readings,)
    if any(word in stems for word in readings):
        return True
    return any(
        len(word) >= 4 and len(other) >= 4
        and SequenceMatcher(None, word, other).ratio() >= A._FUZZY_WORD_CUTOFF
        for word in readings
        for other in stems
    )


def _variants(word: str, rng: random.Random) -> list[str]:
    """Typos of a word: a letter dropped, added, replaced, two swapped, one doubled."""
    i = rng.randrange(len(word))
    out = [
        word[:i] + word[i + 1:],
        word[:i] + rng.choice(LETTERS) + word[i:],
        word[:i] + rng.choice(LETTERS) + word[i + 1:],
        word + rng.choice(LETTERS),
        word[:i] + word[i] * 2 + word[i + 1:],
    ]
    if len(word) > 2:
        j = rng.randrange(len(word) - 1)
        out.append(word[:j] + word[j + 1] + word[j] + word[j + 2:])
    return [w for w in out if w]


@pytest.fixture(scope="module")
def words() -> list[str]:
    rng = random.Random(2026)
    stems = rng.sample(A._DOMAIN_STEMS, 150)
    typos = [v for stem in stems for v in _variants(stem, rng)]
    noise = ["".join(rng.choice(LETTERS) for _ in range(rng.randint(2, 11))) for _ in range(250)]
    return sorted(set(stems + typos + noise))


@pytest.fixture(autouse=True)
def fresh_caches():
    for fn in (A._domains_of_stem, A._fuzzy_ratio_reaches_cutoff, A.analyze_doc):
        fn.cache_clear()
    yield


# --------------------------------------------------------- trade lookup
def test_domain_lookup_is_identical_to_difflib_over_every_candidate(words):
    assert len(words) > 900
    mismatches = [w for w in words if A._domains_of_stem(w) != reference_domains_of_stem(w)]
    assert mismatches == []
    # The sample really exercises every branch: exact hits, fuzzy hits, misses.
    found = [w for w in words if A._domains_of_stem(w)]
    fuzzy = [w for w in found if w not in A._DOMAIN_INDEX]
    assert len(found) > 150 and len(fuzzy) > 20 and len(found) < len(words)


@pytest.mark.parametrize("length", range(1, 16))
def test_length_groups_keep_exactly_what_difflib_would_keep(length):
    probe = "ا" * length
    kept_by_difflib = [
        stem for stem in A._DOMAIN_STEMS
        if SequenceMatcher(None, stem, probe).real_quick_ratio() >= A._FUZZY_DOMAIN_CUTOFF
    ]
    assert sorted(A._fuzzy_domain_candidates(length)) == sorted(kept_by_difflib)


def test_domain_lookup_is_remembered_and_cannot_be_corrupted():
    first = A._domains_of_stem("سباكه")           # a typo of سباكة
    before = A._domains_of_stem.cache_info()
    second = A._domains_of_stem("سباكه")
    after = A._domains_of_stem.cache_info()

    assert first == second and first
    assert after.hits == before.hits + 1 and after.misses == before.misses
    assert isinstance(first, frozenset)            # a cached value nobody can mutate
    # The knowledge base itself is untouched by lookups.
    assert all(isinstance(domains, set) and domains for domains in A._DOMAIN_INDEX.values())


def test_the_lookup_cache_is_bounded():
    assert A._domains_of_stem.cache_info().maxsize is not None
    assert A._fuzzy_ratio_reaches_cutoff.cache_info().maxsize is not None


# ----------------------------------------------------- word comparison
def test_near_miss_is_identical_to_a_direct_comparison(words):
    rng = random.Random(7)
    long_words = [w for w in words if len(w) >= 4]
    pairs = [(rng.choice(long_words), rng.choice(long_words)) for _ in range(4000)]
    # plus pairs that really are close (a word and its own typos)
    pairs += [(w, v) for w in long_words[:300] for v in _variants(w, rng) if len(v) >= 4]

    for word, other in pairs:
        expected = SequenceMatcher(None, word, other).ratio() >= A._FUZZY_WORD_CUTOFF
        assert A._near_miss(word, other) is expected, (word, other)
    assert any(A._near_miss(w, o) for w, o in pairs)          # some do match
    assert not all(A._near_miss(w, o) for w, o in pairs)


def test_comparison_order_is_kept():
    # SequenceMatcher.ratio() is not symmetric, so (a, b) and (b, a) are
    # remembered separately and each equals its own direct comparison.
    rng = random.Random(11)
    for _ in range(3000):
        a = "".join(rng.choice(LETTERS[:6]) for _ in range(rng.randint(4, 9)))
        b = "".join(rng.choice(LETTERS[:6]) for _ in range(rng.randint(4, 9)))
        assert A._fuzzy_ratio_reaches_cutoff(a, b) is (
            SequenceMatcher(None, a, b).ratio() >= A._FUZZY_WORD_CUTOFF)
        assert A._fuzzy_ratio_reaches_cutoff(b, a) is (
            SequenceMatcher(None, b, a).ratio() >= A._FUZZY_WORD_CUTOFF)


def test_word_match_is_identical_to_the_original(words):
    rng = random.Random(3)
    for _ in range(600):
        readings = frozenset(rng.sample(words, rng.randint(1, 3)))
        stems = frozenset(rng.sample(words, rng.randint(0, 25)))
        assert A._word_match(readings, stems) is reference_word_match(readings, stems)
    assert A._word_match("سباك", frozenset({"سباك"})) is True
    assert A._word_match("سباك", frozenset()) is False


# ------------------------------------------------------------ whole ranking
def _catalog(n: int) -> list[A.SearchDoc]:
    rng = random.Random(99)
    trade_words = sorted({w for text in A.DOMAINS.values() for w in text.split()})
    categories = list(A.DOMAINS)

    def text(k):
        picked = [rng.choice(trade_words) for _ in range(k)]
        return " ".join(rng.choice(_variants(w, rng)) if rng.random() < 0.2 else w for w in picked)

    return [
        A.SearchDoc(id=i, title=text(rng.randint(1, 3)), description=text(rng.randint(4, 12)),
                    category=rng.choice(categories), label=text(1) if i % 7 == 0 else "")
        for i in range(n)
    ]


QUERIES = ["بدي اصلح حنفية", "تصليح مكيف", "برمجه تطبيقات", "سباااك", "مصمم شعارات", "كهربائى منازل"]


def test_rankings_are_identical_to_the_original_implementation(monkeypatch):
    docs = _catalog(120)
    new = {q: A.rank(q, docs) for q in QUERIES}
    again = {q: A.rank(q, docs) for q in QUERIES}             # everything remembered now

    monkeypatch.setattr(A, "_domains_of_stem", reference_domains_of_stem)
    monkeypatch.setattr(A, "_word_match", reference_word_match)
    monkeypatch.setattr(A, "analyze_doc", lru_cache(maxsize=4096)(A.analyze_doc.__wrapped__))
    original = {q: A.rank(q, docs) for q in QUERIES}

    assert new == original                                    # ids, scores and order
    assert again == original
    assert sum(len(r) for r in original.values()) > 20        # the queries do find things


def test_label_equivalence_is_unchanged():
    # The exchange matching rules built on the same lookups.
    assert A.labels_equivalent("سباك", "تصليح حنفيات")
    assert A.labels_equivalent("مُبَرْمِج", "مبرمج")
    assert not A.labels_equivalent("سباك", "نجار")
    assert not A.labels_equivalent("", "سباك")


# --------------------------------------------------------- catalog cache
def test_the_document_cache_holds_a_catalog_larger_than_the_old_limit():
    # Above the former 4,096 entries every search evicted and re-analysed the
    # whole catalog; now a second search re-analyses nothing.
    docs = [A.SearchDoc(id=i, title=f"خدمة {i}", category="سباكة") for i in range(4500)]

    A.rank("سباك", docs)
    first = A.analyze_doc.cache_info()
    A.rank("سباك", docs)
    second = A.analyze_doc.cache_info()

    assert first.misses == 4500
    assert second.misses == first.misses                      # nothing recomputed
    assert second.hits == first.hits + 4500
