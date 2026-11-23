"""
Query side of the shared pagination contract (the schemas live in
app/schemas/pagination.py).

Two jobs:

  * [fetch_page] runs a SELECT for one page, and
  * [slice_page] takes one page out of a list already in memory — for the
    searches that rank in Python, where the ranking must see every candidate
    before anything is sliced off.

Both answer "is there a next page?" by asking for ONE row more than the page
needs and checking whether it arrived. No COUNT(*) is involved; a count is
only run where a screen really shows one, through [count_rows].
"""
from typing import Optional, Sequence, TypeVar

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.schemas.pagination import PageParams

T = TypeVar("T")


def _window(params: PageParams, ceiling: Optional[int]) -> tuple[int, int]:
    """
    (offset, how many rows to ask for) for this page.

    One row more than the page needs, so a full page reveals whether another
    one follows. `ceiling` is the endpoint's own cap on the WHOLE result set
    (the existing `limit` / `max_results`): rows beyond it are not reachable,
    so the window never reaches past it and the last page inside it reports
    no next page.
    """
    probe = params.size + 1
    if ceiling is not None:
        probe = min(probe, max(0, ceiling - params.offset))
    return params.offset, probe


def _split(rows: Sequence[T], params: PageParams) -> tuple[list[T], bool]:
    """Drops the probe row and reports whether it was there."""
    return list(rows[: params.size]), len(rows) > params.size


def fetch_page(
    db: Session,
    stmt: Select,
    params: PageParams,
    *,
    ceiling: Optional[int] = None,
) -> tuple[list, bool]:
    """
    Returns (rows, has_next) for `stmt`.

    Without pagination (see `PageParams.requested`) the statement runs
    untouched and every row comes back — the legacy behaviour, which must
    not change for callers that send no parameters. `ceiling` is ignored
    there too: an endpoint that caps its own results keeps applying its own
    `limit`, exactly as it does today.

    `stmt` must already carry its filters, its eager loading and a
    deterministic ORDER BY; paging a query whose order can vary between
    calls duplicates and skips rows.
    """
    if not params.requested:
        return list(db.execute(stmt).scalars().all()), False

    offset, probe = _window(params, ceiling)
    if probe == 0:
        # Entirely past the ceiling: an empty page, and no query at all.
        return [], False

    rows = db.execute(stmt.offset(offset).limit(probe)).scalars().all()
    return _split(rows, params)


def slice_page(
    items: Sequence[T],
    params: PageParams,
    *,
    ceiling: Optional[int] = None,
) -> tuple[list[T], bool]:
    """
    One page out of an already-built list, with the same rules as
    [fetch_page] — for results ranked in Python, which have to be ranked in
    full before a page can be taken.
    """
    if not params.requested:
        return list(items), False

    offset, probe = _window(params, ceiling)
    if probe == 0:
        return [], False

    return _split(items[offset : offset + probe], params)


def count_rows(db: Session, stmt: Select) -> int:
    """
    How many rows `stmt` matches, ignoring any ordering or paging.

    Only for the endpoints that really display a count: this is the COUNT(*)
    that `has_next` exists to avoid.
    """
    return db.execute(select(func.count()).select_from(stmt.order_by(None).subquery())).scalar_one()
