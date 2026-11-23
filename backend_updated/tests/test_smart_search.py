"""Tests for the smart search service: ranked by meaning alone (model mocked)."""
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from app.core.exceptions import ServiceUnavailableError
from app.schemas.semantic_search import SmartSearchParams
from app.services import semantic_search_service as sem
from app.services import smart_search_service as smart
from tests.helpers import make_result, where_clause


def svc(id, title, description="", category="", label=None):
    return SimpleNamespace(
        id=id,
        title=title,
        description=description,
        custom_category_label=label,
        category=SimpleNamespace(name=category),
    )


# The query always embeds to [1, 0, 0]; each service's cosine is then its
# first coordinate. #3 follows close behind #1 so it survives the relative
# floor (see RELATIVE_THRESHOLD); #2 is unrelated and fails the absolute one.
VECTORS = {1: [1.0, 0.0, 0.0], 2: [0.0, 1.0, 0.0], 3: [0.8, 0.6, 0.0]}


@pytest.fixture
def db():
    return MagicMock(name="Session")


@pytest.fixture
def seen(monkeypatch):
    """The texts sent to the model, in order."""
    texts = []
    monkeypatch.setattr(smart, "_semantic_failed", False)
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", True)
    monkeypatch.setattr(sem, "_embed", lambda text: texts.append(text) or [1.0, 0.0, 0.0])
    monkeypatch.setattr(sem, "_calibration_centroid", lambda lang: [0.0, 0.0, 0.0])
    monkeypatch.setattr(sem, "_cached_chunk_embeddings", lambda s: [(VECTORS[s.id], "نص")])
    # Ratings are read for the whole result page in one call.
    monkeypatch.setattr(sem, "service_ratings", lambda db, ids: {i: (4.5, 3) for i in ids})
    return texts


@pytest.fixture
def catalog(db, seen):
    services = [
        svc(1, "سباك محترف", "تصليح حنفيات وتسريب مياه", "سباكة"),
        svc(2, "كهربائي منازل", "صيانة لوحات", "كهرباء"),
        svc(3, "صيانة مكيفات", "تعبئة غاز", "تكييف"),
    ]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    return services


def run(db, **params):
    params.setdefault("q", "بدي اصلح حنفية")
    return smart.search_services_smart(db, SmartSearchParams(**params))


def test_results_are_ranked_by_meaning_and_cut_at_the_threshold(db, catalog):
    results = run(db)
    assert [(s.id, score) for s, score, _ in results] == [(1, 1.0), (3, 0.8)]   # 2 scores 0.0


def test_a_result_far_under_the_best_one_is_dropped(db, catalog, monkeypatch):
    """A neighbouring trade clears the absolute floor while sitting far below
    the right answer — «حنفية» was answered with a plumber at 0.85 and then a
    locksmith at 0.59. The relative floor is what removes it, and no absolute
    one can: 0.59 is above the scores «مغسلة» and «جوال» legitimately get."""
    assert smart.RELATIVE_THRESHOLD == 0.75

    monkeypatch.setitem(VECTORS, 3, [0.74, 0.0, 0.6726])    # 0.74: over 0.45, under 0.75 of 1.0
    assert [s.id for s, _, _ in run(db)] == [1]

    monkeypatch.setitem(VECTORS, 3, [0.76, 0.0, 0.6499])    # 0.76: just inside, so kept
    assert [s.id for s, _, _ in run(db)] == [1, 3]


def test_the_relative_floor_is_measured_against_the_best_result_not_a_constant(
    db, catalog, monkeypatch
):
    """With a weak best result everything scales down with it, so a second
    listing just behind it still counts — the floor is per query, not fixed."""
    monkeypatch.setitem(VECTORS, 1, [0.50, 0.0, 0.866])     # cosine 0.50
    monkeypatch.setitem(VECTORS, 3, [0.48, 0.0, 0.8773])    # cosine 0.48 = 0.96 of the best
    assert [s.id for s, _, _ in run(db)] == [1, 3]


def test_the_cut_off_is_045(db, catalog, monkeypatch):
    """Measured on the 29-query set (see SIMILARITY_THRESHOLD)."""
    assert smart.SIMILARITY_THRESHOLD == 0.45
    monkeypatch.setitem(VECTORS, 1, [0.46, 0.0, 0.89])     # cosine 0.4592
    monkeypatch.setitem(VECTORS, 3, [0.44, 0.0, 0.90])     # cosine 0.4392
    assert [(s.id, score) for s, score, _ in run(db)] == [(1, 0.4592)]


def test_sharing_a_word_does_not_keep_a_service(db, seen, monkeypatch):
    """No keyword path any more: the electrician's text contains the very
    words of the query, but it means something else to the model."""
    services = [svc(2, "كهربائي", "تصليح حنفيات كهربائية", "كهرباء")]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    monkeypatch.setattr(
        sem, "_cached_chunk_embeddings", lambda s: [(VECTORS[s.id], f"{s.title} {s.description}")]
    )
    assert run(db, q="تصليح حنفيات") == []


def test_a_service_with_no_shared_word_is_found_by_meaning(db, seen):
    services = [svc(1, "خدمة غريبة", "وصف عادي", "أخرى")]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    assert [s.id for s, _, _ in run(db, q="شي ما بينعرف")] == [1]


def test_rating_and_rounded_score_are_attached(db, catalog, monkeypatch):
    monkeypatch.setitem(VECTORS, 3, [0.9, 0.123456, 0.0])  # cosine 0.99073...
    results = run(db)
    assert [(s.id, score) for s, score, _ in results] == [(1, 1.0), (3, 0.9907)]
    assert all(rating == (4.5, 3) for _, _, rating in results)


def test_equal_scores_are_ordered_by_id(db, seen, monkeypatch):
    services = [svc(i, f"سباك رقم {i}", "تصليح حنفيات", "سباكة") for i in (3, 1, 2)]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    monkeypatch.setattr(sem, "_cached_chunk_embeddings", lambda s: [([1.0, 0.0, 0.0], "نص")])
    assert [s.id for s, _, _ in run(db)] == [1, 2, 3]


def test_without_the_model_search_is_unavailable(db, catalog, monkeypatch):
    """There is nothing left to fall back to, so it says so instead of
    answering «no results»."""
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", False)
    with pytest.raises(ServiceUnavailableError, match="غير مفعّل"):
        run(db)
    db.execute.assert_not_called()


def test_a_broken_model_answers_503_and_is_not_reloaded(db, catalog, monkeypatch):
    calls = []

    def broken(text):
        calls.append(text)
        raise RuntimeError("model failed to load")

    monkeypatch.setattr(sem, "_embed", broken)

    with pytest.raises(ServiceUnavailableError, match="تعذّر تشغيل موديل البحث"):
        run(db)
    assert smart._semantic_failed is True

    db.execute.reset_mock()
    with pytest.raises(ServiceUnavailableError, match="تعذّر تشغيل موديل البحث"):
        run(db)
    assert len(calls) == 1                       # not retried on every search
    db.execute.assert_not_called()


def test_the_query_reaches_the_model_with_its_trade_words(db, catalog, seen):
    """«جوال» alone is nowhere near a phone-repair listing for the model."""
    run(db, q="جوال")
    assert seen == ["جوال جوالات جوال موبايل هاتف"]


def test_the_keyword_knowledge_base_adds_nothing(db, catalog, seen):
    """It reads «البرنامج» (a washing-machine cycle) as programming."""
    run(db, q="الغسالة بتوقف بنص البرنامج")
    assert "برمجة" not in seen[0]
    assert seen[0].startswith("الغسالة بتوقف بنص البرنامج أجهزة منزلية غسالة")


def test_limit_truncates_the_ranking(db, seen, monkeypatch):
    services = [svc(i, f"سباك رقم {i}", "تصليح حنفيات", "سباكة") for i in range(1, 6)]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    monkeypatch.setattr(sem, "_cached_chunk_embeddings", lambda s: [([1.0, 0.0, 0.0], "نص")])
    assert [s.id for s, _, _ in run(db, limit=2)] == [1, 2]


@pytest.mark.parametrize("query", ["   ", "بدي حدا", "!!!"])
def test_meaningless_queries_do_not_touch_the_database_or_the_model(db, catalog, seen, query):
    assert run(db, q=query) == []
    db.execute.assert_not_called()
    assert seen == []


def test_no_services_means_no_results_and_no_model_call(db, seen):
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: []))
    assert run(db) == []
    assert seen == []


def test_category_and_city_filters_are_part_of_the_query(db, catalog):
    run(db)
    clause = where_clause(db.execute.call_args.args[0])
    assert ":category_id_1" not in clause and "city" not in clause

    run(db, category_id=4, city="دمشق")
    clause = where_clause(db.execute.call_args.args[0])
    assert ":category_id_1" in clause and "city" in clause
