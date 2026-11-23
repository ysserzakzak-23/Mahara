"""
Opt-in pagination on the five Exchange Hub list operations
(Phase 4, Group 3.4):

    GET /api/v1/exchange-requests                 (Browse)          SQL
    GET /api/v1/exchange-requests/search?q=       (Browse search)   ranked
    GET /api/v1/exchange-requests/me              (My requests)     SQL
    GET /api/v1/exchange-requests/interests?q=    (My interests)    ranked
    GET /api/v1/exchange-proposals/me?sent=       (My proposals)    SQL

The same contract as the earlier groups: no `page`/`page_size` gives the
complete bare array, either parameter gives `{items, page, page_size,
has_next}`, there is no `total` and no COUNT anywhere.

The two ranked endpoints are the interesting ones. Their candidate
selection and ordering happen in Python — the Arabic search engine and the
rating sort — so a SQL OFFSET would cut into candidates rather than
results and would change which requests qualify. They rank in full and
slice afterwards, and the tests here prove it the only way that really
counts: walking every page must reproduce the legacy ranked list exactly,
element for element.

Neither of them has a result ceiling (arabic_search.rank returns
everything at or above MIN_SCORE), so none is imposed and every match
stays reachable by paging on.

Runs against a throwaway in-memory SQLite database with the real models.
The project's PostgreSQL database is never opened.
"""
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.main import app
from app.models.category import ServiceCategory
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)
from app.models.profile import UserProfile
from app.models.review import Review
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole

ME = 1
OTHERS = list(range(2, 14))        # 12 other users, each with one request

BASE_TIME = datetime(2026, 10, 5, 12, 0)

PLUMBING, ELECTRICAL, OTHER_CATEGORY = 1, 2, 3

BROWSE = "/api/v1/exchange-requests"
SEARCH = "/api/v1/exchange-requests/search"
MINE = "/api/v1/exchange-requests/me"
INTERESTS = "/api/v1/exchange-requests/interests"
PROPOSALS = "/api/v1/exchange-proposals/me"

# Every other user wants plumbing, which is what ME offers, so all 12 of
# their requests qualify as "interests" for ME.
MY_REQUEST_COUNT = 25
SENT_COUNT = 14
RECEIVED_COUNT = 11


@pytest.fixture
def seeded():
    """(session, statements) against a fresh in-memory database."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    statements: list[str] = []

    @event.listens_for(engine, "before_cursor_execute")
    def _record(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    Base.metadata.create_all(engine)
    session = Session(engine)

    session.add(ServiceCategory(id=PLUMBING, name="سباكة"))
    session.add(ServiceCategory(id=ELECTRICAL, name="كهرباء"))
    session.add(ServiceCategory(id=OTHER_CATEGORY, name="أخرى", is_other=True))

    for user_id in [ME] + OTHERS:
        session.add(User(
            id=user_id, email=f"u{user_id}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True, is_active=True,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(UserProfile(user_id=user_id, full_name=f"User {user_id}"))

    def service(service_id, owner, category=PLUMBING, description="تصليح مكيف وصيانة"):
        session.add(Service(
            id=service_id, provider_id=owner, category_id=category, title=None,
            description=description, status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    # ME offers plumbing, so every request wanting plumbing is an interest.
    service(ME, ME, PLUMBING)

    # ---- the other users' open requests: the Browse list and my interests.
    for i, owner in enumerate(OTHERS, start=1):
        service(100 + i, owner, PLUMBING)
        session.add(ExchangeRequest(
            id=100 + i, user_id=owner, offered_service_id=100 + i,
            offered_category_id=PLUMBING, wanted_category_id=PLUMBING,
            status=ExchangeRequestStatus.OPEN,
            created_at=BASE_TIME + timedelta(minutes=i), updated_at=BASE_TIME,
        ))
        # A review on some of them, so the rating sort has something to do.
        if i % 3 == 0:
            session.add(Review(
                id=100 + i, service_id=100 + i, reviewer_id=ME,
                rating=(i % 5) + 1, comment="جيد",
                created_at=BASE_TIME, updated_at=BASE_TIME,
            ))

    # ---- my own requests, for «طلباتي». Pairs share a created_at so the
    # id tie-breaker from Group 3.3 is exercised across page boundaries.
    for i in range(1, MY_REQUEST_COUNT + 1):
        service(200 + i, ME, ELECTRICAL)
        session.add(ExchangeRequest(
            id=200 + i, user_id=ME, offered_service_id=200 + i,
            offered_category_id=ELECTRICAL, wanted_category_id=PLUMBING,
            status=(
                ExchangeRequestStatus.CLOSED if i % 7 == 0
                else ExchangeRequestStatus.OPEN
            ),
            created_at=BASE_TIME + timedelta(minutes=i // 2),
            updated_at=BASE_TIME,
        ))

    # ---- proposals I sent, on other people's requests.
    for i in range(1, SENT_COUNT + 1):
        session.add(ExchangeProposal(
            id=300 + i, request_id=101, proposer_id=ME, proposed_service_id=ME,
            message=f"عرضي {i}", status=ExchangeProposalStatus.PENDING,
            created_at=BASE_TIME + timedelta(minutes=i // 2),
            updated_at=BASE_TIME,
        ))

    # ---- proposals received on my first request, from the other users.
    for i in range(1, RECEIVED_COUNT + 1):
        owner = OTHERS[i % len(OTHERS)]
        session.add(ExchangeProposal(
            id=400 + i, request_id=201, proposer_id=owner,
            proposed_service_id=100 + (i % len(OTHERS)) + 1,
            message=f"عرض وارد {i}", status=ExchangeProposalStatus.PENDING,
            created_at=BASE_TIME + timedelta(minutes=i // 2),
            updated_at=BASE_TIME,
        ))

    session.commit()
    statements.clear()
    yield session, statements
    session.close()


@pytest.fixture
def client(seeded):
    session, _ = seeded
    app.dependency_overrides[get_db] = lambda: session
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def auth(user_id=ME):
    return {"Authorization": f"Bearer {create_access_token(user_id)}"}


def ids(body):
    rows = body["items"] if isinstance(body, dict) else body
    return [row["id"] for row in rows]


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


def counts(statements):
    """
    The COUNT(*) that pagination must never add — what `count_rows` emits.

    Deliberately not every aggregate: the two ranked flows already run
    `service_ratings`, a single grouped `count(reviews.id)` that computes
    the rating each list is sorted by. That one predates this work and is
    not what the no-COUNT rule is about.
    """
    return [s for s in selects(statements) if "count(*)" in s.lower()]


def url(path, query="", *, extra=""):
    parts = [p for p in (extra, query) if p]
    return path + ("?" + "&".join(parts) if parts else "")


# Each flow as (name, path, extra query, needs a token).
FLOWS = [
    ("browse", BROWSE, "", False),
    ("search", SEARCH, "q=تصليح مكيف", False),
    ("mine", MINE, "", True),
    ("interests", INTERESTS, "", True),
    ("sent", PROPOSALS, "sent=true", True),
    ("received", PROPOSALS, "sent=false", True),
]
FLOW_IDS = [flow[0] for flow in FLOWS]


def fetch(client, flow, page_query=""):
    _name, path, extra, needs_auth = flow
    return client.get(
        url(path, page_query, extra=extra),
        headers=auth() if needs_auth else {},
    )


# ============================================= the legacy path (no parameters)

@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_without_parameters_the_whole_list_comes_back_as_an_array(client, flow):
    response = fetch(client, flow)

    assert response.status_code == 200, response.text
    body = response.json()
    assert isinstance(body, list), f"{flow[0]} must still answer with a bare array"
    assert body, f"{flow[0]} returned nothing, so the test proves little"
    assert len(set(ids(body))) == len(body)


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_the_legacy_response_carries_no_envelope_keys(client, flow):
    body = fetch(client, flow).json()

    assert isinstance(body, list)
    for row in body:
        assert "items" not in row and "has_next" not in row and "page" not in row


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_a_legacy_request_adds_no_limit_or_offset(client, seeded, flow):
    """
    The legacy path must run the query it always ran. The ranked flows add
    no LIMIT either: they rank in Python and the slice is a no-op there.
    """
    _, statements = seeded
    fetch(client, flow)

    for statement in selects(statements):
        upper = statement.upper()
        assert " LIMIT " not in upper, statement
        assert " OFFSET " not in upper, statement


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_no_flow_ever_runs_a_count_query(client, seeded, flow):
    _, statements = seeded

    fetch(client, flow)
    fetch(client, flow, "page=1&page_size=5")
    fetch(client, flow, "page=2&page_size=5")

    assert counts(statements) == []


# ================================================================ the envelope

@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_a_paginated_request_answers_with_the_envelope(client, flow):
    response = fetch(client, flow, "page=1&page_size=5")

    assert response.status_code == 200, response.text
    body = response.json()
    assert isinstance(body, dict)
    assert set(body) == {"items", "page", "page_size", "has_next"}
    assert body["page"] == 1
    assert body["page_size"] == 5
    assert len(body["items"]) == 5
    assert body["has_next"] is True


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_page_size_alone_opts_in_and_starts_at_page_one(client, flow):
    body = fetch(client, flow, "page_size=4").json()

    assert isinstance(body, dict)
    assert body["page"] == 1
    assert len(body["items"]) == 4


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_page_alone_opts_in_with_the_default_page_size(client, flow):
    body = fetch(client, flow, "page=1").json()

    assert isinstance(body, dict)
    assert body["page_size"] == 20


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_no_flow_returns_a_total(client, flow):
    assert "total" not in fetch(client, flow, "page=1").json()


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
@pytest.mark.parametrize("query", [
    "page=0", "page=-1", "page_size=0", "page_size=-5", "page_size=101",
    "page=abc", "page_size=abc", "page=1.5",
])
def test_invalid_pagination_values_are_a_422(client, flow, query):
    assert fetch(client, flow, query).status_code == 422, (flow[0], query)


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_a_page_past_the_end_is_empty_rather_than_an_error(client, flow):
    response = fetch(client, flow, "page=99&page_size=10")

    assert response.status_code == 200
    body = response.json()
    assert body["items"] == []
    assert body["has_next"] is False
    assert body["page"] == 99


# ======================================= every page, exactly the legacy list

@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
@pytest.mark.parametrize("page_size", [1, 3, 7, 20])
def test_walking_every_page_reproduces_the_legacy_list_exactly(
    client, flow, page_size
):
    """
    The heart of this substep, and the only test that really covers the
    ranked flows: the pages, concatenated, must equal the unpaginated
    answer element for element — same rows, same order, nothing repeated,
    nothing lost, whatever the page size.
    """
    legacy = ids(fetch(client, flow).json())

    collected, page = [], 1
    while True:
        body = fetch(client, flow, f"page={page}&page_size={page_size}").json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1
        assert page < 200, f"{flow[0]}: has_next never went false"

    assert collected == legacy, flow[0]
    assert len(set(collected)) == len(collected)


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_has_next_is_false_exactly_on_the_last_page(client, flow):
    total = len(fetch(client, flow).json())
    page_size = 4
    last = (total + page_size - 1) // page_size

    flags = [
        fetch(client, flow, f"page={p}&page_size={page_size}").json()["has_next"]
        for p in range(1, last + 1)
    ]

    assert flags[:-1] == [True] * (last - 1), flow[0]
    assert flags[-1] is False, flow[0]


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_a_page_that_divides_exactly_does_not_promise_another(client, flow):
    total = len(fetch(client, flow).json())

    body = fetch(client, flow, f"page=1&page_size={total}").json()

    assert len(body["items"]) == total
    assert body["has_next"] is False


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_the_last_page_holds_the_remainder(client, flow):
    total = len(fetch(client, flow).json())
    page_size = 4
    last = (total + page_size - 1) // page_size

    body = fetch(client, flow, f"page={last}&page_size={page_size}").json()

    expected = total - (last - 1) * page_size
    assert len(body["items"]) == expected, flow[0]


@pytest.mark.parametrize("flow", FLOWS, ids=FLOW_IDS)
def test_consecutive_pages_never_overlap(client, flow):
    first = set(ids(fetch(client, flow, "page=1&page_size=4").json()))
    second = set(ids(fetch(client, flow, "page=2&page_size=4").json()))

    assert first and second
    assert first.isdisjoint(second), flow[0]


# ============================================================= Browse (SQL)

def test_browse_pages_are_cut_in_sql(client, seeded):
    _, statements = seeded
    client.get(f"{BROWSE}?page=2&page_size=3")

    main = [s for s in selects(statements) if "FROM exchange_requests" in s]
    assert main, selects(statements)
    assert any("LIMIT" in s.upper() for s in main), main


def test_browse_keeps_its_id_desc_ordering_across_pages(client):
    walked = []
    for page in (1, 2, 3, 4, 5):
        walked += ids(client.get(f"{BROWSE}?page={page}&page_size=3").json())

    assert walked == sorted(walked, reverse=True)


def test_browse_pagination_keeps_exclude_user_id(client):
    """Group 3.2 still holds, on every page."""
    excluded = OTHERS[0]

    collected, page = [], 1
    while True:
        body = client.get(
            f"{BROWSE}?exclude_user_id={excluded}&page={page}&page_size=2"
        ).json()
        collected += body["items"]
        if not body["has_next"]:
            break
        page += 1

    assert collected
    for row in collected:
        assert row["user"]["id"] != excluded


def test_browse_with_exclusion_still_matches_its_own_legacy_list(client):
    excluded = OTHERS[0]
    legacy = ids(client.get(f"{BROWSE}?exclude_user_id={excluded}").json())

    collected, page = [], 1
    while True:
        body = client.get(
            f"{BROWSE}?exclude_user_id={excluded}&page={page}&page_size=5"
        ).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1

    assert collected == legacy


@pytest.mark.parametrize("query", ["", "?page=1&page_size=5"])
def test_browse_stays_public(client, query):
    assert client.get(BROWSE + query).status_code == 200


def test_browse_pages_hide_the_unavailable_requests(client, seeded):
    """The status / active-owner / active-service filters still apply."""
    session, _ = seeded
    session.add(Service(
        id=900, provider_id=OTHERS[0], category_id=PLUMBING, title=None,
        description="وصف", status=ServiceStatus.INACTIVE,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(ExchangeRequest(
        id=900, user_id=OTHERS[0], offered_service_id=900,
        offered_category_id=PLUMBING, wanted_category_id=ELECTRICAL,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME + timedelta(days=1), updated_at=BASE_TIME,
    ))
    session.commit()

    collected, page = [], 1
    while True:
        body = client.get(f"{BROWSE}?page={page}&page_size=3").json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1

    assert 900 not in collected


# ========================================================= My requests (SQL)

def test_my_requests_pages_are_cut_in_sql(client, seeded):
    _, statements = seeded
    client.get(f"{MINE}?page=2&page_size=5", headers=auth())

    main = [s for s in selects(statements) if "FROM exchange_requests" in s]
    assert any("LIMIT" in s.upper() for s in main), main


def test_my_requests_pages_hold_only_mine_and_every_status(client):
    collected, page = [], 1
    while True:
        body = client.get(f"{MINE}?page={page}&page_size=6", headers=auth()).json()
        collected += body["items"]
        if not body["has_next"]:
            break
        page += 1

    assert len(collected) == MY_REQUEST_COUNT
    for row in collected:
        assert row["user"]["id"] == ME
    assert {row["status"] for row in collected} == {"open", "closed"}


def test_my_requests_keep_created_at_then_id_ordering_across_pages(client):
    """
    Group 3.3's ordering, now across a page boundary. Pairs of my requests
    share a created_at, so without the id tie-breaker a boundary falling
    between them would repeat or skip one — which the walk test would also
    catch, but this pins the actual order.
    """
    legacy = ids(client.get(MINE, headers=auth()).json())

    walked = []
    for page in range(1, 10):
        body = client.get(f"{MINE}?page={page}&page_size=4", headers=auth()).json()
        walked += ids(body)
        if not body["has_next"]:
            break

    assert walked == legacy
    # Newest first: my highest ids were created last.
    assert walked[0] == 200 + MY_REQUEST_COUNT


@pytest.mark.parametrize("query", ["", "?page=1&page_size=5"])
def test_my_requests_still_need_a_token(client, query):
    assert client.get(MINE + query).status_code == 401


# ======================================================= My proposals (SQL)

def test_proposal_pages_are_cut_in_sql(client, seeded):
    _, statements = seeded
    client.get(f"{PROPOSALS}?sent=true&page=2&page_size=4", headers=auth())

    main = [s for s in selects(statements) if "FROM exchange_proposals" in s]
    assert any("LIMIT" in s.upper() for s in main), main


def test_the_two_proposal_sides_page_independently(client):
    sent, received = [], []
    for page in range(1, 10):
        body = client.get(
            f"{PROPOSALS}?sent=true&page={page}&page_size=3", headers=auth()
        ).json()
        sent += ids(body)
        if not body["has_next"]:
            break
    for page in range(1, 10):
        body = client.get(
            f"{PROPOSALS}?sent=false&page={page}&page_size=3", headers=auth()
        ).json()
        received += ids(body)
        if not body["has_next"]:
            break

    assert len(sent) == SENT_COUNT
    assert len(received) == RECEIVED_COUNT
    assert set(sent).isdisjoint(received)


def test_a_page_of_received_proposals_is_only_mine_to_receive(client):
    body = client.get(
        f"{PROPOSALS}?sent=false&page=1&page_size=100", headers=auth()
    ).json()

    for row in body["items"]:
        assert row["request"]["user"]["id"] == ME
        assert row["proposer"]["id"] != ME


def test_a_page_of_sent_proposals_is_only_mine_to_send(client):
    body = client.get(
        f"{PROPOSALS}?sent=true&page=1&page_size=100", headers=auth()
    ).json()

    for row in body["items"]:
        assert row["proposer"]["id"] == ME


def test_proposal_pages_sort_by_the_proposals_own_created_at(client, seeded):
    """
    Group 3.3 again: a brand-new proposal on an old request must come
    first, not be ordered by the request's timestamp.
    """
    session, _ = seeded
    session.add(ExchangeProposal(
        id=500, request_id=201, proposer_id=OTHERS[0],
        proposed_service_id=101, message="أحدث عرض",
        status=ExchangeProposalStatus.PENDING,
        created_at=BASE_TIME + timedelta(days=5), updated_at=BASE_TIME,
    ))
    session.commit()

    first_page = client.get(
        f"{PROPOSALS}?sent=false&page=1&page_size=2", headers=auth()
    ).json()

    assert ids(first_page)[0] == 500


@pytest.mark.parametrize("sent", ["true", "false"])
def test_proposal_pages_need_a_token(client, sent):
    assert client.get(f"{PROPOSALS}?sent={sent}&page=1").status_code == 401


# ================================= the ranked flows: ranking before slicing

def test_interests_rank_before_slicing(client):
    """
    The rating order is computed over every candidate and only then cut.
    Walking the pages must give the same sequence as the legacy ranked
    list — including the rated-before-unrated rule and its tie-breakers.
    """
    legacy = client.get(INTERESTS, headers=auth()).json()
    assert len(legacy) == len(OTHERS)

    collected, page = [], 1
    while True:
        body = client.get(
            f"{INTERESTS}?page={page}&page_size=2", headers=auth()
        ).json()
        collected += body["items"]
        if not body["has_next"]:
            break
        page += 1

    assert [r["id"] for r in collected] == [r["id"] for r in legacy]
    # and the ranking values travelled with the rows, page by page
    assert [r["offered_service_rating"] for r in collected] == \
           [r["offered_service_rating"] for r in legacy]
    assert [r["offered_service_review_count"] for r in collected] == \
           [r["offered_service_review_count"] for r in legacy]


def test_the_first_interests_page_is_the_top_of_the_ranking(client):
    """
    Not merely the first rows of the table: the highest-rated requests.
    If a page were taken before ranking, this would be whatever the
    database returned first.
    """
    legacy = client.get(INTERESTS, headers=auth()).json()
    page = client.get(f"{INTERESTS}?page=1&page_size=3", headers=auth()).json()

    assert [r["id"] for r in page["items"]] == [r["id"] for r in legacy[:3]]
    # The top of the list is rated; unrated requests sort last.
    assert page["items"][0]["offered_service_rating"] is not None


def test_interests_pages_never_reach_beyond_the_matching_set(client):
    """Pagination must not widen which requests qualify."""
    qualifying = {r["id"] for r in client.get(INTERESTS, headers=auth()).json()}

    collected, page = [], 1
    while True:
        body = client.get(
            f"{INTERESTS}?page={page}&page_size=1", headers=auth()
        ).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1

    assert set(collected) == qualifying


def test_interests_search_ranks_before_slicing(client):
    legacy = ids(client.get(
        f"{INTERESTS}?q=تصليح مكيف", headers=auth()
    ).json())
    assert legacy

    collected, page = [], 1
    while True:
        body = client.get(
            f"{INTERESTS}?q=تصليح مكيف&page={page}&page_size=2", headers=auth()
        ).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1

    assert collected == legacy


def test_the_search_relevance_order_survives_pagination(client):
    legacy = client.get(f"{SEARCH}?q=تصليح مكيف").json()
    assert legacy

    collected, page = [], 1
    while True:
        body = client.get(
            f"{SEARCH}?q=تصليح مكيف&page={page}&page_size=2"
        ).json()
        collected += body["items"]
        if not body["has_next"]:
            break
        page += 1

    assert [r["id"] for r in collected] == [r["id"] for r in legacy]
    assert [r["relevance_score"] for r in collected] == \
           [r["relevance_score"] for r in legacy]


def test_a_search_page_is_not_cut_in_sql(client, seeded):
    """
    The opposite requirement to the SQL flows: the candidate query must
    stay unlimited, because the Python ranking has to see all of it.
    """
    _, statements = seeded
    client.get(f"{SEARCH}?q=تصليح مكيف&page=2&page_size=2")

    for statement in selects(statements):
        assert " LIMIT " not in statement.upper(), statement


def test_an_interests_page_is_not_cut_in_sql(client, seeded):
    _, statements = seeded
    client.get(f"{INTERESTS}?page=2&page_size=2", headers=auth())

    for statement in selects(statements):
        assert " LIMIT " not in statement.upper(), statement


def test_a_search_with_no_matches_pages_to_nothing(client):
    body = client.get(f"{SEARCH}?q=نجارة أثاث&page=1&page_size=5").json()

    assert body["items"] == []
    assert body["has_next"] is False


def test_a_stopword_only_search_still_returns_nothing_paginated(client):
    """Unchanged behaviour: an empty analysis is an empty result."""
    body = client.get(f"{SEARCH}?q=في من على&page=1&page_size=5").json()

    assert body["items"] == []
    assert body["has_next"] is False


def test_interests_for_a_user_who_offers_nothing_page_to_nothing(client, seeded):
    """The `not offers` short-circuit keeps working under pagination."""
    session, _ = seeded
    session.add(User(
        id=99, email="u99@example.com", hashed_password="x",
        role=UserRole.USER, is_provider=False, is_active=True,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(UserProfile(user_id=99, full_name="User 99"))
    session.commit()

    legacy = client.get(INTERESTS, headers=auth(99))
    paged = client.get(f"{INTERESTS}?page=1&page_size=5", headers=auth(99))

    assert legacy.json() == []
    assert paged.json()["items"] == []
    assert paged.json()["has_next"] is False


def test_search_pagination_still_excludes_the_callers_own_requests(client, seeded):
    """
    /search takes the exclusion from the token. Paging must not let my own
    requests back in.
    """
    session, _ = seeded
    # One of mine that would match the query.
    session.add(Service(
        id=950, provider_id=ME, category_id=PLUMBING, title=None,
        description="تصليح مكيف وصيانة", status=ServiceStatus.ACTIVE,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(ExchangeRequest(
        id=950, user_id=ME, offered_service_id=950,
        offered_category_id=PLUMBING, wanted_category_id=ELECTRICAL,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.commit()

    collected, page = [], 1
    while True:
        body = client.get(
            f"{SEARCH}?q=تصليح مكيف&page={page}&page_size=2", headers=auth()
        ).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1

    assert 950 not in collected
    assert collected


def test_slice_page_itself_never_reorders(client):
    """
    A direct check on the helper the ranked flows use: the slices of a
    list, concatenated, are the list.
    """
    from app.core.pagination import slice_page
    from app.schemas.pagination import PageParams

    ranked = [f"item-{i}" for i in range(37)]

    collected, page = [], 1
    while True:
        items, has_next = slice_page(ranked, PageParams(page=page, page_size=5))
        collected += items
        if not has_next:
            break
        page += 1

    assert collected == ranked
