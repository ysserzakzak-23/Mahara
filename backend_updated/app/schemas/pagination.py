"""
Pydantic side of the shared pagination contract.

Pagination is OPT-IN. A request that sends neither `page` nor `page_size`
behaves exactly as it always has: the whole collection, as a bare JSON
array. This matters because installed copies of the app cannot be updated
in step with the backend, and the app sends no version header, so the
backend cannot tell an old build from a new one. An old build must keep
receiving complete data.

A request that sends either parameter opts in and receives an envelope:

    {"items": [...], "page": 1, "page_size": 20, "has_next": true}

`total` is deliberately absent: it costs a COUNT(*), and only the two admin
lists display a count. Those use [CountedPage]; everything else uses [Page],
whose shape is exactly four keys.

The query-side helpers live in app/core/pagination.py (they need a
SQLAlchemy Session, which does not belong in this layer).
"""
from typing import Annotated, Generic, Optional, TypeVar

from fastapi import Query
from pydantic import BaseModel, Field

T = TypeVar("T")

#: Rows per page when a request opts in without naming a size.
DEFAULT_PAGE_SIZE = 20

#: The largest page any endpoint may serve. Endpoints that already cap their
#: own results pass a lower value (see `page_params`), so a paginated request
#: can never return more rows than one of today's unpaginated responses.
MAX_PAGE_SIZE = 100


class PageParams(BaseModel):
    """
    `page` / `page_size` as sent by the client, plus what they mean.

    Both are optional, and leaving both out is the legacy request — see
    [requested].
    """
    page: Optional[int] = None
    page_size: Optional[int] = None
    default_page_size: int = DEFAULT_PAGE_SIZE

    @property
    def requested(self) -> bool:
        """True when the caller opted in to pagination."""
        return self.page is not None or self.page_size is not None

    @property
    def number(self) -> int:
        """The 1-based page asked for (1 when only `page_size` was sent)."""
        return self.page or 1

    @property
    def size(self) -> int:
        """Rows per page (the endpoint's default when only `page` was sent)."""
        return self.page_size or self.default_page_size

    @property
    def offset(self) -> int:
        return (self.number - 1) * self.size


def page_params(
    *,
    default_page_size: int = DEFAULT_PAGE_SIZE,
    max_page_size: int = MAX_PAGE_SIZE,
):
    """
    Builds the FastAPI dependency that reads `page` / `page_size`.

    `max_page_size` is the endpoint's own ceiling on ONE response, so an
    endpoint that caps its results today passes the same number here (50 for
    the smart and semantic searches, 100 for the nearby search). Out-of-range
    values are refused with 422 by FastAPI, like every other bad parameter.

        params: PageParams = Depends(page_params(max_page_size=50))
    """

    def dependency(
        page: Annotated[
            Optional[int],
            Query(ge=1, description="1-based page. Omit (with page_size) for the whole collection."),
        ] = None,
        page_size: Annotated[
            Optional[int],
            Query(ge=1, le=max_page_size, description=f"Rows per page (max {max_page_size})."),
        ] = None,
    ) -> PageParams:
        return PageParams(page=page, page_size=page_size, default_page_size=default_page_size)

    return dependency


class Page(BaseModel, Generic[T]):
    """One page of results: the envelope a paginated request receives."""

    items: list[T]
    page: int = Field(ge=1)
    page_size: int = Field(ge=1)
    has_next: bool


def page_or_list(
    items: list[T],
    params: PageParams,
    has_next: bool,
) -> list[T] | Page[T]:
    """
    The opt-in contract's two shapes, in one place.

    `items` unchanged when the request asked for no page — the bare array
    this endpoint has always returned — and one [Page] of them when it
    did. Every paginated endpoint ends in this call, so the shape of the
    envelope, and the decision between the two, is defined once.

    The list is returned as given: same objects, same order. Nothing is
    copied, sorted or filtered here — the rows and their order are the
    endpoint's business, decided by its query (or, for the ranked
    searches, by its ranking) long before this point.
    """
    if not params.requested:
        return items
    return Page(items=items, page=params.number, page_size=params.size, has_next=has_next)


class CountedPage(Page[T], Generic[T]):
    """
    [Page] plus the exact number of matching rows.

    Only for the admin lists, which display a count — it costs an extra
    COUNT(*) query that nothing else needs.
    """

    total: int = Field(ge=0)
