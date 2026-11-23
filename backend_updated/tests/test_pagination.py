"""
The shared pagination helper (Phase 4, Group 0).

Nothing is wired into an endpoint yet: these cover the helper itself —
the opt-in rule, the envelope, how `has_next` is decided without a
COUNT(*), the ceiling that keeps a paginated request inside the result set
an unpaginated one would have returned, and the validation bounds.

Runs against a throwaway in-memory SQLite database; the project's
PostgreSQL database is never opened.
"""
import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import Integer, String, create_engine, event, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from app.core.pagination import count_rows, fetch_page, slice_page
from app.schemas.pagination import (
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    CountedPage,
    Page,
    PageParams,
    page_or_list,
    page_params,
)


class Base(DeclarativeBase):
    pass


class Row(Base):
    """A table of our own, so the helper is tested apart from any model."""
    __tablename__ = "rows"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(20))


@pytest.fixture
def db():
    """(session, statements) — every SQL statement sent is recorded."""
    engine = create_engine("sqlite://")
    statements: list[str] = []

    @event.listens_for(engine, "before_cursor_execute")
    def _record(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(Row(id=i, name=f"row {i}") for i in range(1, 46))   # 45 rows
    session.commit()
    statements.clear()
    yield session, statements
    session.close()


def ordered():
    """The statement under test: deterministic, as every paged query must be."""
    return select(Row).order_by(Row.id)


def ids(rows):
    return [r.id for r in rows]


def paged(page=None, page_size=None, default=DEFAULT_PAGE_SIZE):
    return PageParams(page=page, page_size=page_size, default_page_size=default)


# ======================================================= opt-in (the legacy path)

def test_without_parameters_nothing_is_paginated(db):
    session, statements = db

    rows, has_next = fetch_page(session, ordered(), paged())

    assert len(rows) == 45                      # the whole collection
    assert has_next is False
    assert len(statements) == 1
    sql = statements[0].upper()
    assert "LIMIT" not in sql and "OFFSET" not in sql
    assert "COUNT" not in sql


def test_a_ceiling_does_not_touch_the_legacy_path(db):
    # An endpoint that caps its own results keeps doing that itself.
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(), ceiling=10)
    assert len(rows) == 45 and has_next is False


@pytest.mark.parametrize("params, requested", [
    (paged(), False),
    (paged(page=1), True),
    (paged(page_size=5), True),
    (paged(page=2, page_size=5), True),
])
def test_either_parameter_opts_in(params, requested):
    assert params.requested is requested


def test_the_defaults_fill_in_the_missing_half():
    assert paged(page=3).size == DEFAULT_PAGE_SIZE          # page only
    assert paged(page_size=7).number == 1                   # size only
    assert paged(page=3, page_size=7).offset == 14
    assert paged(page=2, default=50).size == 50             # the endpoint's own default


# ============================================================== paging a query

def test_the_first_page_reports_that_more_follows(db):
    session, statements = db

    rows, has_next = fetch_page(session, ordered(), paged(page=1, page_size=20))

    assert ids(rows) == list(range(1, 21))
    assert has_next is True
    assert len(statements) == 1


def test_pages_run_to_the_end_without_gaps_or_repeats(db):
    session, _ = db
    seen, page = [], 1
    while True:
        rows, has_next = fetch_page(session, ordered(), paged(page=page, page_size=20))
        seen += ids(rows)
        if not has_next:
            break
        page += 1

    assert seen == list(range(1, 46))           # every row, once, in order
    assert page == 3                            # 20 + 20 + 5


def test_the_last_page_reports_no_next(db):
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(page=3, page_size=20))
    assert ids(rows) == list(range(41, 46))
    assert has_next is False


def test_an_exactly_full_last_page_still_reports_no_next(db):
    # 45 rows, 15 per page: page 3 ends exactly on the last row.
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(page=3, page_size=15))
    assert ids(rows) == list(range(31, 46))
    assert has_next is False


def test_a_page_past_the_end_is_empty_not_an_error(db):
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(page=9, page_size=20))
    assert rows == [] and has_next is False


def test_an_empty_collection_pages_to_nothing(db):
    session, _ = db
    rows, has_next = fetch_page(session, select(Row).where(Row.id < 0).order_by(Row.id),
                                paged(page=1, page_size=20))
    assert rows == [] and has_next is False


# ===================================== has_next without COUNT(*) (audit requirement)

def test_has_next_costs_one_query_and_no_count(db):
    session, statements = db

    fetch_page(session, ordered(), paged(page=1, page_size=20))

    assert len(statements) == 1, statements
    assert "COUNT" not in statements[0].upper()


def test_has_next_asks_for_one_row_more_than_the_page_and_hides_it(db):
    """The probe row is what makes a COUNT unnecessary — and it must not
    appear in the page."""
    session, statements = db

    rows, has_next = fetch_page(session, ordered(), paged(page=2, page_size=20))

    sql = statements[0].upper()
    assert "LIMIT" in sql and "OFFSET" in sql
    assert ids(rows) == list(range(21, 41))     # the offset was applied...
    assert len(rows) == 20                      # ...and the 21st row is not here
    assert has_next is True                     # but it was fetched, so we know


@pytest.mark.parametrize("page_size", [1, 7, 20, 44, 45, 46])
def test_has_next_is_right_for_every_page_size(db, page_size):
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(page=1, page_size=page_size))

    assert len(rows) == min(page_size, 45)
    assert has_next is (page_size < 45)


# ====================================== the ceiling (an endpoint's existing limit)

def test_the_ceiling_bounds_the_whole_result_set(db):
    """`limit` keeps meaning "at most this many results", paged or not."""
    session, _ = db

    first, more = fetch_page(session, ordered(), paged(page=1, page_size=20), ceiling=30)
    second, even_more = fetch_page(session, ordered(), paged(page=2, page_size=20), ceiling=30)

    assert ids(first) == list(range(1, 21)) and more is True
    assert ids(second) == list(range(21, 31))    # stops at the ceiling, not at 40
    assert even_more is False


def test_a_page_beyond_the_ceiling_runs_no_query_at_all(db):
    session, statements = db

    rows, has_next = fetch_page(session, ordered(), paged(page=3, page_size=20), ceiling=30)

    assert rows == [] and has_next is False
    assert statements == []                      # nothing to ask the database


def test_a_ceiling_below_the_page_size_gives_one_short_page(db):
    # The semantic search's shape: a ceiling of 10 under a 20-row page.
    session, _ = db
    rows, has_next = fetch_page(session, ordered(), paged(page=1, page_size=20), ceiling=10)
    assert ids(rows) == list(range(1, 11))
    assert has_next is False


def test_paging_never_returns_more_than_the_ceiling_allows(db):
    session, _ = db
    total = []
    for page in range(1, 6):
        rows, _ = fetch_page(session, ordered(), paged(page=page, page_size=20), ceiling=30)
        total += ids(rows)
    assert total == list(range(1, 31))


# ============================================ slicing a list ranked in memory

RANKED = [f"result {i}" for i in range(1, 46)]


def test_a_list_is_sliced_by_the_same_rules():
    assert slice_page(RANKED, paged()) == (RANKED, False)             # legacy: all of it
    assert slice_page(RANKED, paged(page=1, page_size=20)) == (RANKED[:20], True)
    assert slice_page(RANKED, paged(page=3, page_size=20)) == (RANKED[40:], False)
    assert slice_page(RANKED, paged(page=9, page_size=20)) == ([], False)


def test_slicing_respects_the_ceiling_too():
    assert slice_page(RANKED, paged(page=1, page_size=20), ceiling=30) == (RANKED[:20], True)
    assert slice_page(RANKED, paged(page=2, page_size=20), ceiling=30) == (RANKED[20:30], False)
    assert slice_page(RANKED, paged(page=1, page_size=20), ceiling=10) == (RANKED[:10], False)


def test_slicing_an_empty_ranking():
    assert slice_page([], paged(page=1, page_size=20)) == ([], False)


def test_the_slice_is_the_ranking_untouched():
    """Order and membership come from the ranking; paging only cuts it up."""
    pages = []
    for page in (1, 2, 3):
        items, _ = slice_page(RANKED, paged(page=page, page_size=20))
        pages += items
    assert pages == RANKED


# ====================================================================== count

def test_count_rows_counts_matching_rows_only(db):
    session, statements = db

    assert count_rows(session, ordered()) == 45
    assert count_rows(session, select(Row).where(Row.id <= 10)) == 10
    assert all("COUNT" in s.upper() for s in statements)


def test_count_rows_is_only_run_when_asked(db):
    """The COUNT(*) that has_next exists to avoid never runs by itself."""
    session, statements = db

    fetch_page(session, ordered(), paged(page=1, page_size=20))
    slice_page(RANKED, paged(page=1, page_size=20))

    assert not any("COUNT" in s.upper() for s in statements)


# =================================================================== envelope

def test_the_envelope_has_exactly_four_keys():
    page = Page[str](items=["a", "b"], page=1, page_size=2, has_next=True)
    assert page.model_dump() == {
        "items": ["a", "b"], "page": 1, "page_size": 2, "has_next": True,
    }


def test_the_counted_envelope_adds_total_for_the_admin_lists():
    page = CountedPage[str](items=["a"], page=2, page_size=1, has_next=False, total=7)
    assert page.model_dump() == {
        "items": ["a"], "page": 2, "page_size": 1, "has_next": False, "total": 7,
    }


@pytest.mark.parametrize("bad", [
    {"items": [], "page": 0, "page_size": 20, "has_next": False},
    {"items": [], "page": 1, "page_size": 0, "has_next": False},
])
def test_the_envelope_refuses_impossible_numbers(bad):
    with pytest.raises(ValueError):
        Page[str](**bad)


def test_a_counted_envelope_cannot_have_a_negative_total():
    with pytest.raises(ValueError):
        CountedPage[str](items=[], page=1, page_size=20, has_next=False, total=-1)


# ========================================= the dependency and its validation

def _app(**kwargs):
    """A throwaway app that exposes nothing but the dependency under test."""
    api = FastAPI()

    @api.get("/items")
    def read(params: PageParams = Depends(page_params(**kwargs))):
        return {
            "requested": params.requested,
            "page": params.number,
            "page_size": params.size,
            "offset": params.offset,
        }

    return TestClient(api)


def test_no_parameters_is_not_a_paginated_request():
    body = _app().get("/items").json()
    assert body["requested"] is False
    assert body["page_size"] == DEFAULT_PAGE_SIZE


def test_the_parameters_are_read_and_combined():
    assert _app().get("/items?page=3&page_size=10").json() == {
        "requested": True, "page": 3, "page_size": 10, "offset": 20,
    }
    assert _app().get("/items?page=2").json()["page_size"] == DEFAULT_PAGE_SIZE
    assert _app().get("/items?page_size=5").json()["page"] == 1


@pytest.mark.parametrize("query", [
    "page=0", "page=-1", "page_size=0", "page_size=-5",
    f"page_size={MAX_PAGE_SIZE + 1}", "page=abc", "page_size=abc", "page=1.5",
])
def test_bad_values_are_refused_with_422(query):
    assert _app().get(f"/items?{query}").status_code == 422


def test_an_endpoint_may_lower_the_maximum_page_size():
    # The searches cap one response at what they already cap it at today.
    client = _app(max_page_size=50)
    assert client.get("/items?page_size=50").status_code == 200
    assert client.get("/items?page_size=51").status_code == 422


def test_an_endpoint_may_set_its_own_default_page_size():
    client = _app(default_page_size=50)
    assert client.get("/items?page=1").json()["page_size"] == 50
    assert client.get("/items").json()["requested"] is False      # still opt-in


def test_the_biggest_allowed_page_is_a_hundred():
    assert MAX_PAGE_SIZE == 100
    assert _app().get(f"/items?page_size={MAX_PAGE_SIZE}").status_code == 200


# ================================================== page_or_list (Phase 6 B)
#
# The response side of the opt-in contract, which every paginated endpoint
# now ends in: the bare list when no page was asked for, one Page when it
# was. Nine endpoints used to decide this themselves — seven inline, two
# through a private helper that only knew one response type.

def test_without_pagination_it_returns_the_list_itself():
    items = ["a", "b", "c"]

    result = page_or_list(items, paged(), has_next=False)

    assert isinstance(result, list)
    assert not isinstance(result, Page)
    assert result == ["a", "b", "c"]


def test_without_pagination_has_next_is_ignored():
    """A legacy answer has no envelope to carry it."""
    assert page_or_list(["a"], paged(), has_next=True) == ["a"]


def test_with_pagination_it_returns_a_page_of_the_items():
    result = page_or_list(["a", "b"], paged(page=1, page_size=2), has_next=False)

    assert isinstance(result, Page)
    assert result.items == ["a", "b"]


def test_the_page_carries_the_requested_number_and_size():
    result = page_or_list(["a"], paged(page=3, page_size=7), has_next=False)

    assert result.page == 3
    assert result.page_size == 7


def test_page_size_alone_still_reports_page_one():
    result = page_or_list(["a"], paged(page_size=5), has_next=False)

    assert result.page == 1
    assert result.page_size == 5


def test_page_alone_reports_the_default_size():
    result = page_or_list(["a"], paged(page=2), has_next=False)

    assert result.page == 2
    assert result.page_size == DEFAULT_PAGE_SIZE


@pytest.mark.parametrize("has_next", [True, False])
def test_has_next_is_passed_through_unchanged(has_next):
    result = page_or_list(["a"], paged(page=1, page_size=1), has_next=has_next)

    assert result.has_next is has_next


def test_an_empty_list_without_pagination_is_an_empty_list():
    assert page_or_list([], paged(), has_next=False) == []


def test_an_empty_page_is_a_page_with_no_items():
    result = page_or_list([], paged(page=9, page_size=20), has_next=False)

    assert isinstance(result, Page)
    assert result.items == []
    assert result.page == 9
    assert result.has_next is False


def test_the_envelope_has_exactly_the_four_keys():
    """No `total`: this helper never adds one, and never counts."""
    result = page_or_list(["a"], paged(page=1, page_size=1), has_next=True)

    assert set(result.model_dump()) == {"items", "page", "page_size", "has_next"}


def test_the_items_are_neither_reordered_nor_copied_away():
    items = ["c", "a", "b"]

    legacy = page_or_list(items, paged(), has_next=False)
    page = page_or_list(items, paged(page=1, page_size=3), has_next=False)

    # The order the caller supplied — which is the order its query or its
    # ranking decided — is the order that comes back, both shapes.
    assert legacy == ["c", "a", "b"]
    assert page.items == ["c", "a", "b"]
    # And the caller's own list is left alone.
    assert items == ["c", "a", "b"]


def test_it_does_not_mutate_the_list_it_was_given():
    items = [1, 2, 3]

    result = page_or_list(items, paged(page=1, page_size=2), has_next=True)
    result.items.append(99)

    # Pydantic validated the field into its own list, so appending to the
    # page cannot reach back into the caller's.
    assert items == [1, 2, 3]


def test_it_is_generic_over_the_item_type():
    """Generic over the item type: the endpoints pass response models."""
    rows = [Page(items=[], page=1, page_size=1, has_next=False)]

    result = page_or_list(rows, paged(page=1, page_size=1), has_next=False)

    assert isinstance(result, Page)
    assert result.items == rows
