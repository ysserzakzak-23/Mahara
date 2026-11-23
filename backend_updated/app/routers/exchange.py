"""
Exchange Request / Proposal routes — the explicit request/propose/approve
barter workflow. See app/models/exchange.py and app/services/exchange_service.py.
"""
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user, get_current_user_optional
from app.models.user import User
from app.schemas.exchange import (
    DirectMatchResponse,
    ExchangeProposalCreateRequest,
    ExchangeProposalResponse,
    ExchangeRequestCreateRequest,
    ExchangeRequestRankedResponse,
    ExchangeRequestResponse,
)
from app.schemas.pagination import Page, PageParams, page_or_list, page_params
from app.services import exchange_service

router = APIRouter(prefix="/api/v1/exchange-requests", tags=["Exchange"])
proposals_router = APIRouter(prefix="/api/v1/exchange-proposals", tags=["Exchange"])


def _ranked(items: list[exchange_service.RankedRequest]) -> list[ExchangeRequestRankedResponse]:
    out: list[ExchangeRequestRankedResponse] = []
    for request, rating, review_count, relevance in items:
        base = ExchangeRequestResponse.model_validate(request)
        out.append(
            ExchangeRequestRankedResponse(
                **base.model_dump(),
                offered_service_rating=rating,
                offered_service_review_count=review_count,
                relevance_score=relevance,
            )
        )
    return out


@router.post("", response_model=ExchangeRequestResponse, status_code=201)
def create_exchange_request(
    payload: ExchangeRequestCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ExchangeRequestResponse:
    """Opens a new exchange request for one of the current user's own services."""
    request = exchange_service.create_request(db, current_user, payload)
    return ExchangeRequestResponse.model_validate(request)


@router.get("", response_model=list[ExchangeRequestResponse] | Page[ExchangeRequestResponse])
def list_open_exchange_requests(
    exclude_user_id: int | None = Query(
        default=None,
        description="Leave this user's own requests out (the Browse list hides yours)",
    ),
    params: PageParams = Depends(page_params()),
    db: Session = Depends(get_db),
) -> list[ExchangeRequestResponse] | Page[ExchangeRequestResponse]:
    """
    Public browse list of every open exchange request. Unauthenticated.

    `exclude_user_id` is a display filter and nothing else: it only ever
    removes rows, so it grants no access and is not an authorization
    mechanism — the same list minus one user's requests is strictly less
    than what any caller could already read here. Nothing else in the
    request is derived from it.

    It has to be given explicitly because this endpoint is public and the
    app sends no token with it, so there is no authenticated identity to
    take the id from. /search, which is sent the token when there is one,
    keeps deriving it from the caller instead.

    Absent, the list is exactly what it has always been — which is what an
    installed app build that filters its own requests client-side still
    expects.
    """
    requests, has_next = exchange_service.list_open_requests_page(
        db, exclude_user_id=exclude_user_id, params=params
    )
    items = [ExchangeRequestResponse.model_validate(r) for r in requests]
    return page_or_list(items, params, has_next)


@router.get(
    "/search",
    response_model=list[ExchangeRequestRankedResponse] | Page[ExchangeRequestRankedResponse],
)
def search_exchange_requests(
    q: str = Query(min_length=1, max_length=200, description="Free Arabic text, e.g. «تصليح مكيف»"),
    params: PageParams = Depends(page_params()),
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_current_user_optional),
) -> list[ExchangeRequestRankedResponse] | Page[ExchangeRequestRankedResponse]:
    """
    Smart Arabic search over the Browse list (every available open exchange
    request, any category), best match first. Uses the same engine as
    /search/smart but returns ExchangeRequest records. Public; a logged-in
    caller's own requests are left out.
    """
    exclude = current_user.id if current_user else None
    ranked, has_next = exchange_service.search_requests_page(
        db, q, exclude_user_id=exclude, params=params
    )
    return page_or_list(_ranked(ranked), params, has_next)


@router.get(
    "/interests",
    response_model=list[ExchangeRequestRankedResponse] | Page[ExchangeRequestRankedResponse],
)
def list_my_interests(
    q: str | None = Query(default=None, max_length=200, description="Optional smart-search text"),
    params: PageParams = Depends(page_params()),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ExchangeRequestRankedResponse] | Page[ExchangeRequestRankedResponse]:
    """
    «اهتماماتي»: open requests from other users who want a service the
    current user offers (derived from the user's own active services).
    Sorted by the offered service's average rating, highest first, unrated
    last. With `q`, smart-searches within that same set (best match first).
    """
    ranked, has_next = exchange_service.list_interests_page(
        db, current_user, q, params=params
    )
    return page_or_list(_ranked(ranked), params, has_next)


@router.get(
    "/me", response_model=list[ExchangeRequestResponse] | Page[ExchangeRequestResponse]
)
def list_my_exchange_requests(
    params: PageParams = Depends(page_params()),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ExchangeRequestResponse] | Page[ExchangeRequestResponse]:
    """
    «طلباتي»: the user's own requests, newest first (Group 3.3's ordering).

    Opt-in pagination: without `page`/`page_size` this returns every one of
    them as a plain array, exactly as it always has.
    """
    requests, has_next = exchange_service.list_my_requests_page(
        db, current_user, params=params
    )
    items = [ExchangeRequestResponse.model_validate(r) for r in requests]
    return page_or_list(items, params, has_next)


@router.get("/{request_id}/matches", response_model=list[DirectMatchResponse])
def get_matches_for_request(
    request_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[DirectMatchResponse]:
    """
    Runs the direct-matching algorithm and returns every other open
    request that directly matches this one. Only the request's owner may
    view this (see exchange_service.find_matches_for_request).
    """
    matches = exchange_service.find_matches_for_request(db, request_id, requesting_user=current_user)
    return [
        DirectMatchResponse(match_type="direct", other_request=ExchangeRequestResponse.model_validate(m))
        for m in matches
    ]


@router.delete("/{request_id}", status_code=204)
def close_exchange_request(
    request_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Withdraws the current user's own open request."""
    exchange_service.close_request(db, request_id, current_user)


@router.post("/{request_id}/proposals", response_model=ExchangeProposalResponse, status_code=201)
def create_proposal(
    request_id: int,
    payload: ExchangeProposalCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ExchangeProposalResponse:
    """Sends a concrete proposal (one of the current user's own services) to a request's owner."""
    proposal = exchange_service.create_proposal(db, request_id, current_user, payload)
    return ExchangeProposalResponse.model_validate(proposal)


@router.get("/{request_id}/proposals", response_model=list[ExchangeProposalResponse])
def list_proposals_for_request(
    request_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ExchangeProposalResponse]:
    """
    The proposals on one exchange request.

    The request's owner gets every proposal on it; anyone else gets only
    their own — the same visibility the detail screen used to assemble
    from /exchange-proposals/me, now decided in the query. An unknown
    request is a 404, as on every other /exchange-requests/{id} route.
    """
    proposals = exchange_service.list_proposals_for_request(db, request_id, current_user)
    return [ExchangeProposalResponse.model_validate(p) for p in proposals]


@proposals_router.get(
    "/me", response_model=list[ExchangeProposalResponse] | Page[ExchangeProposalResponse]
)
def list_my_proposals(
    sent: bool = Query(default=True, description="True: proposals I sent. False: proposals received on my requests."),
    params: PageParams = Depends(page_params()),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[ExchangeProposalResponse] | Page[ExchangeProposalResponse]:
    """
    The proposals I sent, or the ones received on my requests. The two
    sides are separate lists and page independently.

    Opt-in pagination: without `page`/`page_size` the whole side comes back
    as a plain array, as it always has.
    """
    proposals, has_next = exchange_service.list_my_proposals_page(
        db, current_user, sent=sent, params=params
    )
    items = [ExchangeProposalResponse.model_validate(p) for p in proposals]
    return page_or_list(items, params, has_next)


@proposals_router.post("/{proposal_id}/accept", response_model=ExchangeProposalResponse)
def accept_proposal(
    proposal_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ExchangeProposalResponse:
    proposal = exchange_service.respond_to_proposal(db, proposal_id, current_user, accept=True)
    return ExchangeProposalResponse.model_validate(proposal)


@proposals_router.post("/{proposal_id}/reject", response_model=ExchangeProposalResponse)
def reject_proposal(
    proposal_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ExchangeProposalResponse:
    proposal = exchange_service.respond_to_proposal(db, proposal_id, current_user, accept=False)
    return ExchangeProposalResponse.model_validate(proposal)
