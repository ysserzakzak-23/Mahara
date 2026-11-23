"""
Exchange Request / Proposal service layer.

Implements the explicit "اطلب/اقترح/وافق" (request/propose/approve)
workflow: a user opens an ExchangeRequest for one of their own services,
the direct-matching algorithm (app/algorithms/direct_match.py) surfaces
compatible open requests, and either side can turn a match into a
concrete ExchangeProposal that the request's owner accepts or rejects.

On top of that it serves the Exchange hub's discovery features:
  * «اهتماماتي» (My Interests) — open requests from other users whose
    WANTED service is one the current user actually offers, derived live
    from the user's own active services (no saved-interest table);
  * smart search over ExchangeRequest records (Browse and My Interests),
    reusing app/utils/arabic_search.py's normalisation/trade/fuzzy ranking;
  * direct matches that require a full two-way exchange, comparing the
    «أخرى» (Other) custom labels and not just category ids.

"Available" requests — the only ones these features show — are OPEN, owned
by an active account, and offer a service that is still ACTIVE.
"""
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.algorithms.direct_match import RequestEdge, is_direct_match
from app.core.exceptions import NotFoundError, PermissionDeniedError, ValidationError
from app.core.pagination import fetch_page, slice_page
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)
from app.models.notification import NotificationType
from app.models.review import Review
from app.models.service import Service, ServiceStatus
from app.models.user import User
from app.schemas.pagination import PageParams
from app.schemas.exchange import ExchangeProposalCreateRequest, ExchangeRequestCreateRequest
from app.services import notification_service
from app.services.category_service import get_category_by_id
from app.services.service_service import _resolve_custom_category_label, get_service_by_id
from app.utils import arabic_search

# (request, offered-service average rating or None if unrated, review count,
#  search relevance or None when there was no search text)
RankedRequest = tuple[ExchangeRequest, Optional[float], int, Optional[float]]

def _query_requests_with_relations():
    return select(ExchangeRequest).options(
        selectinload(ExchangeRequest.user).selectinload(User.profile),
        selectinload(ExchangeRequest.offered_service).selectinload(Service.category),
        selectinload(ExchangeRequest.offered_service).selectinload(Service.provider).selectinload(
            User.profile
        ),
        selectinload(ExchangeRequest.offered_category),
        selectinload(ExchangeRequest.wanted_category),
    )


def _query_proposals_with_relations():
    return select(ExchangeProposal).options(
        selectinload(ExchangeProposal.proposer).selectinload(User.profile),
        selectinload(ExchangeProposal.proposed_service).selectinload(Service.category),
        selectinload(ExchangeProposal.proposed_service).selectinload(Service.provider).selectinload(
            User.profile
        ),
        selectinload(ExchangeProposal.request).selectinload(ExchangeRequest.user).selectinload(
            User.profile
        ),
        selectinload(ExchangeProposal.request).selectinload(ExchangeRequest.offered_service).selectinload(
            Service.category
        ),
        selectinload(ExchangeProposal.request).selectinload(ExchangeRequest.offered_category),
        selectinload(ExchangeProposal.request).selectinload(ExchangeRequest.wanted_category),
    )


def get_request_by_id(db: Session, request_id: int) -> ExchangeRequest:
    stmt = _query_requests_with_relations().where(ExchangeRequest.id == request_id)
    request = db.execute(stmt).scalar_one_or_none()
    if request is None:
        raise NotFoundError("طلب التبادل غير موجود")
    return request


def create_request(
    db: Session, user: User, payload: ExchangeRequestCreateRequest
) -> ExchangeRequest:
    service = get_service_by_id(db, payload.offered_service_id)
    if service.provider_id != user.id:
        raise PermissionDeniedError("يمكنك عرض خدمة تملكها فقط")
        
    wanted_category = get_category_by_id(db, payload.wanted_category_id)
    wanted_custom_category_label = _resolve_custom_category_label(
        wanted_category, payload.wanted_custom_category_label
    )
    request = ExchangeRequest(
        user_id=user.id,
        offered_service_id=service.id,
        offered_category_id=service.category_id,
        wanted_category_id=payload.wanted_category_id,
        wanted_custom_category_label=wanted_custom_category_label,
    )
    db.add(request)
    db.commit()
    db.refresh(request)

    # Best-effort: tell BOTH sides right away, instead of either of them
    # only finding out next time they check GET /exchange-requests/{id}/matches.
    # A two-way match is news for the person whose request was already open
    # AND for the one who just published — each gets the other's request as
    # the entity to look at, and a message written from their own side.
    # find_matches_for_request excludes the owner's own requests, so the two
    # recipients are always different people.
    matches = find_matches_for_request(db, request.id, requesting_user=user)
    for match in matches:
        notification_service.notify_user(
            db,
            user_id=match.user_id,
            notification_type=NotificationType.EXCHANGE_MATCH_FOUND,
            title="تم العثور على مطابقة تبادل جديدة",
            message="هناك من يريد ما تعرضه، ويعرض ما تحتاجه.",
            related_entity_id=request.id,
        )
        notification_service.notify_user(
            db,
            user_id=request.user_id,
            notification_type=NotificationType.EXCHANGE_MATCH_FOUND,
            title="تم العثور على مطابقة تبادل جديدة",
            message=(
                f"'{match.offered_service.display_title}' يطابق ما تبحث عنه، "
                f"وصاحبه يريد '{service.display_title}' الذي تعرضه."
            ),
            related_entity_id=match.id,
        )

    return get_request_by_id(db, request.id)


def _open_requests_query(exclude_user_id: int | None):
    """
    Every available open request (see module docstring): OPEN, owner
    active, offered service ACTIVE. A request whose service was paused or
    whose owner was deactivated can't actually be exchanged, so it is not
    offered to anyone. Newest first, by id -- unchanged, and deterministic
    already, which is what lets a page boundary be drawn here.

    `exclude_user_id` leaves one user's own requests out (Group 3.2); it is
    applied with the rest of the filters, before any page is cut.
    """
    stmt = (
        _query_requests_with_relations()
        .join(Service, ExchangeRequest.offered_service_id == Service.id)
        .join(User, ExchangeRequest.user_id == User.id)
        .where(
            ExchangeRequest.status == ExchangeRequestStatus.OPEN,
            Service.status == ServiceStatus.ACTIVE,
            User.is_active.is_(True),
        )
        .order_by(ExchangeRequest.id.desc())
    )
    if exclude_user_id is not None:
        stmt = stmt.where(ExchangeRequest.user_id != exclude_user_id)
    return stmt


def list_open_requests_page(
    db: Session,
    exclude_user_id: int | None = None,
    params: PageParams | None = None,
) -> tuple[list[ExchangeRequest], bool]:
    """
    One page of the Browse list, cut in SQL: (requests, has_next).

    Without pagination that is every matching request and False -- the
    behaviour this endpoint has always had, and what the ranked searches
    below need, since they must see every candidate before ranking.
    """
    return fetch_page(db, _open_requests_query(exclude_user_id), params or PageParams())


def list_open_requests(db: Session, exclude_user_id: int | None = None) -> list[ExchangeRequest]:
    """Every available open request. See [list_open_requests_page]."""
    requests, _has_next = list_open_requests_page(db, exclude_user_id=exclude_user_id)
    return requests


def _my_requests_query(user: User):
    """
    The user's own exchange requests, whatever their status, newest first.

    Explicitly ordered: until now this query had no ORDER BY, so the rows
    arrived in whatever order the database found convenient and «طلباتي»
    could reshuffle between two openings. Neither the response schema nor
    the Flutter model carries a timestamp, so the server's order is the
    only order there is.

    `created_at` is the primary key of the sort because it is what the
    list means — when I opened this request — and `id` breaks ties, which
    two requests created in the same transaction really do have. Newest
    first matches the Browse list and every other list in the app.
    """
    stmt = (
        _query_requests_with_relations()
        .where(ExchangeRequest.user_id == user.id)
        .order_by(ExchangeRequest.created_at.desc(), ExchangeRequest.id.desc())
    )
    return stmt


def list_my_requests_page(
    db: Session, user: User, params: PageParams | None = None
) -> tuple[list[ExchangeRequest], bool]:
    """
    One page of the user's own requests, cut in SQL: (requests, has_next).

    The ownership filter, every status and the Group 3.3 ordering are all
    in the statement, so the page is cut after them. Without pagination,
    every request and False.
    """
    return fetch_page(db, _my_requests_query(user), params or PageParams())


def list_my_requests(db: Session, user: User) -> list[ExchangeRequest]:
    """The user's own requests. See [list_my_requests_page]."""
    requests, _has_next = list_my_requests_page(db, user)
    return requests


def close_request(db: Session, request_id: int, user: User) -> None:
    request = get_request_by_id(db, request_id)
    if request.user_id != user.id:
        raise PermissionDeniedError("ليس لديك صلاحية لإغلاق هذا الطلب")
    request.status = ExchangeRequestStatus.CLOSED
    db.commit()


def _offered_label(request: ExchangeRequest) -> Optional[str]:
    """The offered service's «أخرى» label, or None for a regular category."""
    if not request.offered_category.is_other:
        return None
    return request.offered_service.custom_category_label or ""


def _wanted_label(request: ExchangeRequest) -> Optional[str]:
    """The wanted «أخرى» label, or None for a regular category."""
    if not request.wanted_category.is_other:
        return None
    return request.wanted_custom_category_label or ""


def _edge(request: ExchangeRequest) -> RequestEdge:
    return RequestEdge(
        id=request.id,
        user_id=request.user_id,
        offered_category_id=request.offered_category_id,
        wanted_category_id=request.wanted_category_id,
        offered_service_id=request.offered_service_id,
        offered_label=_offered_label(request),
        wanted_label=_wanted_label(request),
    )


def find_matches_for_request(
    db: Session, request_id: int, requesting_user: User | None = None
) -> list[ExchangeRequest]:
    """
    Every other available open request that forms a complete two-way
    exchange with this one (app/algorithms/direct_match.is_direct_match):
    it offers what this request wants AND wants what this request offers —
    for «أخرى» the custom labels must match too, not only the category id.

    One-sided ("similar") requests, the request itself, the owner's own
    other requests, and closed/matched requests are never returned. A
    request that is no longer open has no matches. Ordered by id.
    """
    target = get_request_by_id(db, request_id)
    if requesting_user is not None and target.user_id != requesting_user.id:
        # Anyone can view open requests, but "find my matches" is scoped
        # to your own request to avoid leaking who's interested in whom.
        raise PermissionDeniedError("يمكنك عرض المطابقات الخاصة بطلبك فقط")
    if target.status != ExchangeRequestStatus.OPEN:
        return []

    target_edge = _edge(target)
    seen: set[int] = set()
    matches: list[ExchangeRequest] = []
    for candidate in list_open_requests(db, exclude_user_id=target.user_id):
        if candidate.id in seen:
            continue
        if is_direct_match(target_edge, _edge(candidate)):
            seen.add(candidate.id)
            matches.append(candidate)
    matches.sort(key=lambda r: r.id)
    return matches


# ------------------------------------------------------------------ ratings

def service_ratings(db: Session, service_ids: list[int]) -> dict[int, tuple[float, int]]:
    """
    {service_id: (average_rating, review_count)} for the given services, in
    ONE grouped query (no per-row lookups). Services without any review are
    simply absent from the result — they are unrated, not rated 0.
    """
    if not service_ids:
        return {}
    rows = db.execute(
        select(Review.service_id, func.avg(Review.rating), func.count(Review.id))
        .where(Review.service_id.in_(sorted(set(service_ids))))
        .group_by(Review.service_id)
    ).all()
    return {
        service_id: (round(float(avg), 2), int(count))
        for service_id, avg, count in rows
        if avg is not None and count
    }


def _rating_sort_key(item: RankedRequest) -> tuple:
    """Rated before unrated; higher average first; then more reviews; then
    newer request (higher id) first — so ties always resolve the same way."""
    request, rating, count, _ = item
    return (rating is None, -(rating or 0.0), -count, -request.id)


def _with_ratings(db: Session, requests: list[ExchangeRequest]) -> list[RankedRequest]:
    ratings = service_ratings(db, [r.offered_service_id for r in requests])
    out: list[RankedRequest] = []
    for r in requests:
        avg, count = ratings.get(r.offered_service_id, (None, 0))
        out.append((r, avg, count, None))
    return out


# ------------------------------------------------------------- smart search

def _search_doc(request: ExchangeRequest) -> arabic_search.SearchDoc:
    """
    An ExchangeRequest flattened for app/utils/arabic_search.rank: the
    offered service (title, custom label, category) and the wanted service
    (category, custom label) are strong fields; the offered service's
    description is the weak one.
    """
    offered = request.offered_service
    labels = " ".join(
        x for x in (offered.custom_category_label, request.wanted_custom_category_label) if x
    )
    categories = " ".join(
        x.name for x in (request.offered_category, request.wanted_category) if x is not None
    )
    return arabic_search.SearchDoc(
        id=request.id,
        title=offered.title or "",
        description=offered.description or "",
        category=categories,
        label=labels,
    )


def _rank_by_query(
    db: Session, requests: list[ExchangeRequest], query: str
) -> list[RankedRequest]:
    """Keeps only requests relevant to `query`, best match first (ties by
    offered-service rating). Same scoring and cut-off as the main search."""
    if not requests:
        return []
    by_id = {r.id: r for r in requests}
    ranked = arabic_search.rank(query, [_search_doc(r) for r in requests])
    if not ranked:
        return []
    ratings = service_ratings(db, [by_id[rid].offered_service_id for rid, _ in ranked])
    out: list[RankedRequest] = []
    for request_id, score in ranked:
        request = by_id[request_id]
        avg, count = ratings.get(request.offered_service_id, (None, 0))
        out.append((request, avg, count, score))
    out.sort(key=lambda item: (-(item[3] or 0.0),) + _rating_sort_key(item))
    return out


def search_requests_page(
    db: Session,
    query: str,
    exclude_user_id: int | None = None,
    params: PageParams | None = None,
) -> tuple[list[RankedRequest], bool]:
    """
    One page of the Browse smart search: (ranked requests, has_next).

    The ranking runs over every candidate first and the page is taken out
    of the finished ranking, never out of the rows. Scoring in SQL is not
    possible here -- the Arabic engine is Python -- and slicing before it
    would rank only part of the candidates and answer a different
    question. There is no result ceiling on this search (arabic_search.rank
    returns everything scoring at least MIN_SCORE), so none is imposed:
    every match stays reachable by paging on.
    """
    if arabic_search.analyze_query(query).is_empty:
        return [], False
    ranked = _rank_by_query(
        db, list_open_requests(db, exclude_user_id=exclude_user_id), query
    )
    return slice_page(ranked, params or PageParams())


def search_requests(
    db: Session, query: str, exclude_user_id: int | None = None
) -> list[RankedRequest]:
    """
    Smart search over the Browse list: every available open request
    (whatever its category), minus the caller's own, ranked against
    `query` with the main search's Arabic engine. Returns ExchangeRequest
    rows — never catalog services. See [search_requests_page].
    """
    ranked, _has_next = search_requests_page(db, query, exclude_user_id=exclude_user_id)
    return ranked


# ------------------------------------------------------------- my interests

def _my_offers(db: Session, user: User) -> list[tuple[int, Optional[str]]]:
    """(category_id, «أخرى» label or None) for each ACTIVE service the user
    owns — read live, so the result follows the user's services as they
    are added, edited, paused or deleted."""
    stmt = (
        select(Service)
        .options(selectinload(Service.category))
        .where(Service.provider_id == user.id, Service.status == ServiceStatus.ACTIVE)
    )
    offers: list[tuple[int, Optional[str]]] = []
    for service in db.execute(stmt).scalars().all():
        is_other = bool(service.category and service.category.is_other)
        key = (service.category_id, (service.custom_category_label or "") if is_other else None)
        if key not in offers:
            offers.append(key)
    return offers


def _wants_one_of(request: ExchangeRequest, offers: list[tuple[int, Optional[str]]]) -> bool:
    wanted_label = _wanted_label(request)
    for category_id, offered_label in offers:
        if request.wanted_category_id != category_id:
            continue
        if wanted_label is None and offered_label is None:
            return True
        if arabic_search.labels_equivalent(wanted_label, offered_label):
            return True
    return False


def list_interests_page(
    db: Session,
    user: User,
    query: str | None = None,
    params: PageParams | None = None,
) -> tuple[list[RankedRequest], bool]:
    """
    One page of «اهتماماتي»: (ranked requests, has_next).

    Which requests qualify, and in what order, is decided exactly as
    before and in full; only then is a page taken out of the finished
    list. Both of those steps are Python -- the match is a category/custom
    label comparison and the sort is by the offered service's rating (or
    by relevance when searching) -- so a SQL OFFSET here would cut into
    candidates, not results, and change which requests qualify. There is
    no result ceiling, so none is introduced.
    """
    offers = _my_offers(db, user)
    if not offers:
        return [], False
    interesting = [
        r for r in list_open_requests(db, exclude_user_id=user.id) if _wants_one_of(r, offers)
    ]
    if query and query.strip():
        if arabic_search.analyze_query(query).is_empty:
            return [], False
        ranked = _rank_by_query(db, interesting, query)
    else:
        ranked = sorted(_with_ratings(db, interesting), key=_rating_sort_key)
    return slice_page(ranked, params or PageParams())


def list_interests(
    db: Session, user: User, query: str | None = None
) -> list[RankedRequest]:
    """
    «اهتماماتي»: available open requests from OTHER users who are looking
    for a service the current user offers (any of their active services;
    for «أخرى» the custom labels must match). One-way on purpose — what
    those users offer in return doesn't matter here.

    Without `query`: sorted by the offered service's own average rating,
    highest first, unrated last (see _rating_sort_key). With `query`: only
    requests from that same set that are relevant to it, best match first.
    See [list_interests_page].
    """
    ranked, _has_next = list_interests_page(db, user, query)
    return ranked


def create_proposal(
    db: Session, request_id: int, proposer: User, payload: ExchangeProposalCreateRequest
) -> ExchangeProposal:
    request = get_request_by_id(db, request_id)
    if request.status != ExchangeRequestStatus.OPEN:
        raise ValidationError("طلب التبادل هذا لم يعد مفتوحاً")
    if request.user_id == proposer.id:
        raise ValidationError("لا يمكنك إرسال عرض على طلبك الخاص")

    proposed_service = get_service_by_id(db, payload.proposed_service_id)
    if proposed_service.provider_id != proposer.id:
        raise PermissionDeniedError("يمكنك اقتراح خدمة تملكها فقط")

    proposal = ExchangeProposal(
        request_id=request.id,
        proposer_id=proposer.id,
        proposed_service_id=proposed_service.id,
        message=payload.message,
    )
    db.add(proposal)
    db.commit()
    db.refresh(proposal)

    notification_service.notify_user(
        db,
        user_id=request.user_id,
        notification_type=NotificationType.EXCHANGE_PROPOSAL_RECEIVED,
        title="عرض تبادل جديد",
        message=(
            f"تم اقتراح '{proposed_service.display_title}' "
            f"مقابل '{request.offered_service.display_title}'"
        ),
        related_entity_id=proposal.id,
    )

    return get_proposal_by_id(db, proposal.id)


def get_proposal_by_id(db: Session, proposal_id: int) -> ExchangeProposal:
    stmt = _query_proposals_with_relations().where(ExchangeProposal.id == proposal_id)
    proposal = db.execute(stmt).scalar_one_or_none()
    if proposal is None:
        raise NotFoundError("عرض التبادل غير موجود")
    return proposal


def _my_proposals_query(user: User, sent: bool):
    """
    [sent]=True: proposals I sent. [sent]=False: proposals sent to my
    requests. Newest first either way.

    Explicitly ordered for the same reason as list_my_requests: there was
    no ORDER BY, and nothing downstream can impose one because the
    proposal response carries no timestamp. The sort is on the proposal's
    own `created_at` — when it was sent — and never the request's, which
    is a different event; the received branch joins exchange_requests, so
    the column is qualified to keep that unambiguous. `id` breaks ties.
    """
    if sent:
        stmt = _query_proposals_with_relations().where(ExchangeProposal.proposer_id == user.id)
    else:
        stmt = (
            _query_proposals_with_relations()
            .join(ExchangeRequest, ExchangeProposal.request_id == ExchangeRequest.id)
            .where(ExchangeRequest.user_id == user.id)
        )
    return stmt.order_by(
        ExchangeProposal.created_at.desc(), ExchangeProposal.id.desc()
    )


def list_my_proposals_page(
    db: Session, user: User, sent: bool, params: PageParams | None = None
) -> tuple[list[ExchangeProposal], bool]:
    """
    One page of the sent or received proposals, cut in SQL:
    (proposals, has_next).

    The two sides are separate queries with separate pages; the ownership
    filter (and, for received, the join to my requests) and the Group 3.3
    ordering on the proposal's own created_at are all in the statement, so
    the page is cut after them. Without pagination, every proposal on that
    side and False.
    """
    return fetch_page(db, _my_proposals_query(user, sent), params or PageParams())


def list_my_proposals(db: Session, user: User, sent: bool) -> list[ExchangeProposal]:
    """Sent or received proposals. See [list_my_proposals_page]."""
    proposals, _has_next = list_my_proposals_page(db, user, sent)
    return proposals


def list_proposals_for_request(
    db: Session, request_id: int, user: User
) -> list[ExchangeProposal]:
    """
    The proposals on one request, as this user is allowed to see them.

    The request's owner sees every proposal on it; anyone else sees only
    their own. That is exactly the visibility the two /exchange-proposals/me
    views already gave a single request's detail screen — the owner read
    the received list, a visitor read the sent list, and both discarded
    everything belonging to other requests. The difference is that the
    request_id is now a WHERE clause, so the database returns one request's
    proposals instead of every proposal the user can see.

    Ordered by id: the request's own proposals in the order they arrived.
    The old path had no ORDER BY at all, so nothing is being re-ranked —
    this only makes the result stable.

    The owner is looked up on its own rather than through
    get_request_by_id: the check needs one column, and the proposals'
    eager loads already bring the request with them. A missing request
    raises the same NotFoundError that every other request route raises.
    """
    owner_id = db.execute(
        select(ExchangeRequest.user_id).where(ExchangeRequest.id == request_id)
    ).scalar_one_or_none()
    if owner_id is None:
        raise NotFoundError("طلب التبادل غير موجود")

    stmt = _query_proposals_with_relations().where(
        ExchangeProposal.request_id == request_id
    )
    if owner_id != user.id:
        # Not my request: I may only see what I myself proposed on it,
        # never who else is interested.
        stmt = stmt.where(ExchangeProposal.proposer_id == user.id)

    return list(db.execute(stmt.order_by(ExchangeProposal.id)).scalars().all())


def _reciprocal_requests(db: Session, proposal: ExchangeProposal) -> list[ExchangeRequest]:
    """
    Every request of the proposer's that this proposal completes, oldest
    first — whatever state each one is in.

    A proposal keeps no link to a request of its sender's: it carries the
    service they put up (`proposed_service_id`), and it can be sent straight
    from «تصفح» by someone who never published a request at all. So the
    counterpart is recovered the same way the direct-matching system paired
    the two in the first place (app/algorithms/direct_match.is_direct_match):
    among the sender's OPEN requests, those offering exactly the service they
    proposed, and forming a complete two-way exchange with the request being
    answered — each side offering what the other wants, «أخرى» labels
    compared in both directions.

    Nothing weaker is accepted: no category-name guesswork, never another
    user's request, and never a request offering a different service.

    Deliberately NOT filtered by status, because an empty list has to mean
    one thing only: the sender never published a counterpart, so their
    proposal is a plain offer from «تصفح» and settles one side. A
    counterpart that exists but is already matched (or that its owner
    withdrew) is a different story — the proposal is stale, and telling the
    two apart is the caller's job, after the rows are locked. When the
    sender published the same service for the same wanted category more
    than once, those duplicates are by that definition interchangeable.
    """
    target_edge = _edge(proposal.request)
    candidates = (
        db.execute(
            select(ExchangeRequest)
            .where(
                ExchangeRequest.user_id == proposal.proposer_id,
                ExchangeRequest.offered_service_id == proposal.proposed_service_id,
            )
            .order_by(ExchangeRequest.id)
        )
        .scalars()
        .all()
    )
    return [c for c in candidates if is_direct_match(target_edge, _edge(c))]


def respond_to_proposal(
    db: Session, proposal_id: int, user: User, accept: bool
) -> ExchangeProposal:
    proposal = get_proposal_by_id(db, proposal_id)
    if proposal.request.user_id != user.id:
        raise PermissionDeniedError(
            "صاحب الطلب فقط يمكنه قبول العرض أو رفضه"
        )
    if proposal.status != ExchangeProposalStatus.PENDING:
        raise ValidationError("تم الرد على هذا العرض مسبقاً")

    reciprocal: ExchangeRequest | None = None
    if accept:
        # One acceptance per request, even when two of them arrive at the
        # same instant. The rows this acceptance settles are locked and
        # their statuses re-read from the database: whoever gets the lock
        # second waits here, then finds the request already matched and is
        # refused — so a request can never end up with two accepted
        # proposals.
        #
        # There is more than one such row when the proposal completes a
        # request of the sender's own (see [_reciprocal_requests]): that one
        # is settled by this very acceptance, so every candidate is locked
        # too, or the same counterpart could be promised to two different
        # people at once. Locking the candidates that are already matched or
        # closed costs nothing and leaves no gap between reading a status
        # and acting on it. They are locked lowest id first — a fixed order,
        # so two acceptances holding one row each can only queue up, never
        # deadlock. The lookup itself takes no lock; everything it found is
        # re-read below, once the rows are held.
        #
        # PostgreSQL (what production runs) is where FOR UPDATE actually
        # blocks; SQLite has no row locks and simply ignores it, so there
        # the re-read still covers the sequential case. Rejecting needs no
        # lock: it decides nothing for either request as a whole.
        candidates = _reciprocal_requests(db, proposal)
        locked_status = {
            request_id: db.execute(
                select(ExchangeRequest.status)
                .where(ExchangeRequest.id == request_id)
                .with_for_update()
            ).scalar_one_or_none()
            for request_id in sorted(
                {proposal.request.id} | {c.id for c in candidates}
            )
        }
        target_status = locked_status[proposal.request.id]
        if target_status is None:
            raise NotFoundError("طلب التبادل غير موجود")
        if target_status != ExchangeRequestStatus.OPEN:
            raise ValidationError("طلب التبادل هذا لم يعد مفتوحاً")
        # The winner rejects every other pending proposal, so re-read this
        # one too before acting on a status we read before the lock.
        db.refresh(proposal)
        if proposal.status != ExchangeProposalStatus.PENDING:
            raise ValidationError("تم الرد على هذا العرض مسبقاً")
        if candidates:
            # The oldest one still OPEN as the lock found it — not simply
            # the oldest, which may well be an older exchange of the same
            # service that is already settled.
            reciprocal = next(
                (c for c in candidates if locked_status.get(c.id) == ExchangeRequestStatus.OPEN),
                None,
            )
            if reciprocal is None:
                # The sender does have a counterpart to this proposal, and
                # every one of them is spoken for, withdrawn, or gone: the
                # proposal is stale. Refuse it rather than quietly settle
                # one side as if no counterpart had ever existed.
                raise ValidationError("لم يعد طلب التبادل المقابل متاحاً")

    proposal.status = (
        ExchangeProposalStatus.ACCEPTED if accept else ExchangeProposalStatus.REJECTED
    )

    if accept:
        proposal.request.status = ExchangeRequestStatus.MATCHED
        if reciprocal is not None:
            # The sender's own request is settled by the same acceptance:
            # the service it offers is promised here, so it stops being on
            # offer to anyone else. One commit covers both rows and the
            # proposals below — either the whole exchange is settled or
            # nothing is.
            reciprocal.status = ExchangeRequestStatus.MATCHED
        # Any other still-pending proposals on this request are implicitly
        # no longer relevant once one has been accepted.
        for other in proposal.request.proposals:
            if other.id != proposal.id and other.status == ExchangeProposalStatus.PENDING:
                other.status = ExchangeProposalStatus.REJECTED

    db.commit()
    db.refresh(proposal)

    notification_service.notify_user(
        db,
        user_id=proposal.proposer_id,
        notification_type=(
            NotificationType.EXCHANGE_PROPOSAL_ACCEPTED
            if accept
            else NotificationType.EXCHANGE_PROPOSAL_REJECTED
        ),
        title="تم قبول عرض التبادل" if accept else "تم رفض عرض التبادل",
        message=(
            "تم قبول عرض التبادل الخاص بك!"
            if accept
            else "تم رفض عرض التبادل الخاص بك."
        ),
        related_entity_id=proposal.id,
    )

    return get_proposal_by_id(db, proposal.id)
