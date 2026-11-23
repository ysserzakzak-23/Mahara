"""
GET /api/v1/exchange-requests/{request_id}/proposals (Phase 4, Group 3.1).

The exchange request detail screen used to read /exchange-proposals/me —
every proposal the user could see, anywhere — and throw away the ones that
belonged to other requests. This endpoint answers the question the screen
actually asks, with the request id as a WHERE clause.

The visibility is the same as what the old pair of calls produced for one
request, and these tests pin that down:

  * the request's owner sees every proposal on it (what the received list
    gave them, filtered to this request);
  * anyone else sees only their own (what the sent list gave them), never
    who else is interested;
  * an unknown request is a 404, like every other /exchange-requests/{id}
    route; an anonymous caller is a 401.

Also pinned down: the response fields are unchanged, the query count does
not grow with the number of proposals in the database or on the request
(so neither the filtering nor the serialisation walks everything), and
the result is ordered.

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
from app.models.service import Service, ServiceStatus
from app.models.profile import UserProfile
from app.models.user import User, UserRole

OWNER = 10          # owns request 7
PROPOSER_A = 20     # proposed on request 7
PROPOSER_B = 21     # also proposed on request 7
STRANGER = 99       # proposed on nothing

MINE = 7            # the request under test
OTHERS = 8          # someone else's request, with proposals of its own

BASE_TIME = datetime(2026, 10, 5, 12, 0)


@pytest.fixture
def seeded():
    """(session, statements) against a fresh in-memory database."""
    # One shared connection usable from any thread: TestClient runs the app
    # in a worker thread, which would otherwise see a different database.
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

    session.add(ServiceCategory(id=1, name="سباكة"))
    session.add(ServiceCategory(id=2, name="كهرباء"))

    for user_id in (OWNER, PROPOSER_A, PROPOSER_B, STRANGER):
        session.add(User(
            id=user_id, email=f"u{user_id}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True, is_active=True,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(UserProfile(user_id=user_id, full_name=f"User {user_id}"))
        # One service each, so everyone has something to offer.
        session.add(Service(
            id=user_id, provider_id=user_id, category_id=1, title=None,
            description="وصف الخدمة", status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    session.add(ExchangeRequest(
        id=MINE, user_id=OWNER, offered_service_id=OWNER,
        offered_category_id=1, wanted_category_id=2,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(ExchangeRequest(
        id=OTHERS, user_id=PROPOSER_B, offered_service_id=PROPOSER_B,
        offered_category_id=1, wanted_category_id=2,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))

    def propose(proposal_id, *, request_id, proposer_id, status, minutes):
        session.add(ExchangeProposal(
            id=proposal_id, request_id=request_id, proposer_id=proposer_id,
            proposed_service_id=proposer_id, message=f"عرض {proposal_id}",
            status=status,
            created_at=BASE_TIME + timedelta(minutes=minutes), updated_at=BASE_TIME,
        ))

    # On MINE: one from each proposer, in id order.
    propose(1, request_id=MINE, proposer_id=PROPOSER_A,
            status=ExchangeProposalStatus.PENDING, minutes=1)
    propose(2, request_id=MINE, proposer_id=PROPOSER_B,
            status=ExchangeProposalStatus.REJECTED, minutes=2)
    propose(3, request_id=MINE, proposer_id=PROPOSER_A,
            status=ExchangeProposalStatus.PENDING, minutes=3)

    # On someone else's request: must never appear under MINE.
    propose(50, request_id=OTHERS, proposer_id=OWNER,
            status=ExchangeProposalStatus.PENDING, minutes=1)
    propose(51, request_id=OTHERS, proposer_id=PROPOSER_A,
            status=ExchangeProposalStatus.PENDING, minutes=2)

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


def auth(user_id):
    return {"Authorization": f"Bearer {create_access_token(user_id)}"}


def url(request_id=MINE):
    return f"/api/v1/exchange-requests/{request_id}/proposals"


def get(client, user, request_id=MINE):
    return client.get(url(request_id), headers=auth(user))


def ids(response):
    return [row["id"] for row in response.json()]


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


# ===================================================== only this request's own

def test_the_owner_gets_every_proposal_on_their_request(client):
    response = get(client, OWNER)

    assert response.status_code == 200, response.text
    assert ids(response) == [1, 2, 3]


def test_proposals_on_other_requests_are_excluded(client):
    """
    Proposal 50 is the owner's own, on someone else's request — exactly the
    row the detail screen used to receive and discard.
    """
    body = get(client, OWNER).json()

    assert 50 not in [row["id"] for row in body]
    assert 51 not in [row["id"] for row in body]
    for row in body:
        assert row["request"]["id"] == MINE


def test_each_request_answers_with_its_own_proposals(client):
    """The same user, two requests, two different lists."""
    mine = ids(get(client, OWNER, request_id=MINE))
    others = ids(get(client, PROPOSER_B, request_id=OTHERS))

    assert mine == [1, 2, 3]
    assert others == [50, 51]
    assert set(mine).isdisjoint(others)


def test_a_request_with_no_proposals_is_an_empty_list(client, seeded):
    session, _ = seeded
    session.add(ExchangeRequest(
        id=900, user_id=OWNER, offered_service_id=OWNER,
        offered_category_id=1, wanted_category_id=2,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.commit()

    response = get(client, OWNER, request_id=900)

    assert response.status_code == 200
    assert response.json() == []


def test_the_result_is_ordered_by_id(client, seeded):
    """
    Stable order, oldest first. The old path had no ORDER BY at all, so
    nothing is re-ranked here — the result simply stops depending on what
    the database feels like returning.
    """
    session, _ = seeded
    session.add(ExchangeProposal(
        id=4, request_id=MINE, proposer_id=STRANGER, proposed_service_id=STRANGER,
        message="عرض متأخر", status=ExchangeProposalStatus.PENDING,
        created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.commit()

    assert ids(get(client, OWNER)) == [1, 2, 3, 4]


# ====================================================== visibility and access

def test_a_proposer_sees_only_their_own_proposals_on_someone_elses_request(client):
    """
    PROPOSER_A sent 1 and 3; 2 is PROPOSER_B's. Showing 2 would leak who
    else is competing for the same request.
    """
    response = get(client, PROPOSER_A)

    assert response.status_code == 200
    assert ids(response) == [1, 3]


def test_the_other_proposer_sees_only_theirs(client):
    assert ids(get(client, PROPOSER_B)) == [2]


def test_someone_with_no_proposal_on_it_sees_an_empty_list(client):
    """
    Not an error: a visitor opening the detail screen legitimately asks
    this and simply has nothing of their own on it yet.
    """
    response = get(client, STRANGER)

    assert response.status_code == 200
    assert response.json() == []


def test_a_rejected_proposal_is_still_visible_to_its_proposer(client):
    """Status does not hide a proposal — the screen reports the rejection."""
    body = get(client, PROPOSER_B).json()

    assert [row["status"] for row in body] == ["rejected"]


def test_an_unknown_request_is_a_404_with_the_usual_message(client):
    response = get(client, OWNER, request_id=12345)

    assert response.status_code == 404
    assert response.json()["detail"] == "طلب التبادل غير موجود"


def test_an_unknown_request_is_a_404_for_a_stranger_too(client):
    """The 404 must not depend on who asks, or it reveals which ids exist."""
    assert get(client, STRANGER, request_id=12345).status_code == 404


def test_an_anonymous_caller_is_refused(client):
    assert client.get(url()).status_code == 401


# ======================================================== shape of the rows

def test_a_row_carries_the_same_fields_as_before(client):
    row = get(client, OWNER).json()[0]

    assert set(row) == {"id", "status", "message", "proposer", "proposed_service", "request"}
    assert row["status"] == "pending"
    assert row["message"] == "عرض 1"
    assert row["proposer"]["id"] == PROPOSER_A
    assert row["proposer"]["profile"]["full_name"] == f"User {PROPOSER_A}"
    assert row["proposed_service"]["id"] == PROPOSER_A
    assert row["request"]["id"] == MINE
    assert row["request"]["user"]["id"] == OWNER


def test_the_nested_request_and_service_are_fully_serialised(client):
    """
    display_title comes from the service's category, and the nested request
    carries its own offered service and both categories — the relationships
    the eager loads exist for.
    """
    row = get(client, OWNER).json()[0]

    assert row["proposed_service"]["display_title"] == "سباكة"
    assert row["request"]["offered_service"]["display_title"] == "سباكة"
    assert row["request"]["offered_category"]["name"] == "سباكة"
    assert row["request"]["wanted_category"]["name"] == "كهرباء"


# ============================================ it does not walk every proposal

def _proposals_statement(statements):
    """The one SELECT that reads the exchange_proposals table itself."""
    found = [s for s in selects(statements) if "FROM exchange_proposals" in s]
    assert len(found) == 1, found
    return found[0]


def _where_clause(statement):
    assert "WHERE" in statement, f"no WHERE at all in: {statement}"
    return statement.split("WHERE", 1)[1]


def _in_clause_widths(statements, table):
    """How many ids each `FROM <table> ... IN (...)` follow-up asks for."""
    widths = []
    for statement in selects(statements):
        if f"FROM {table}" in statement and "IN (" in statement:
            widths.append(statement.split("IN (", 1)[1].split(")", 1)[0].count("?"))
    return widths


def test_the_request_id_is_a_where_clause_not_a_python_filter(client, seeded):
    """
    The point of this endpoint. Filtering in Python would leave the main
    SELECT unrestricted — for the owner, with no WHERE at all.
    """
    _, statements = seeded
    get(client, OWNER)

    where = _where_clause(_proposals_statement(statements))
    assert "request_id" in where, where


def test_a_non_owner_gets_both_restrictions_in_sql(client, seeded):
    _, statements = seeded
    get(client, PROPOSER_A)

    where = _where_clause(_proposals_statement(statements))
    assert "request_id" in where, where
    assert "proposer_id" in where, where


def test_only_this_requests_rows_come_back_from_the_database(client, seeded):
    """
    Proof that the filtering happened in SQL, not after it: the eager load
    for the nested request asks for exactly one request id. Had the query
    returned proposals from both requests, it would ask for two.
    """
    _, statements = seeded
    get(client, OWNER)

    assert _in_clause_widths(statements, "exchange_requests") == [1]


def test_the_query_count_does_not_grow_with_proposals_elsewhere(client, seeded):
    """
    The old path's cost grew with every proposal the user could see
    anywhere. 200 proposals on another request must not cost this endpoint
    a single extra statement.
    """
    session, statements = seeded

    get(client, OWNER)
    before = len(selects(statements))

    for new_id in range(2000, 2200):
        session.add(ExchangeProposal(
            id=new_id, request_id=OTHERS, proposer_id=PROPOSER_A,
            proposed_service_id=PROPOSER_A, message="ضجيج",
            status=ExchangeProposalStatus.PENDING,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
    session.commit()
    session.expunge_all()
    statements.clear()

    response = get(client, OWNER)

    assert ids(response) == [1, 2, 3]       # still only this request's
    assert len(selects(statements)) == before
    # And the database really returned three rows, not 203 narrowed down
    # afterwards: the nested-request eager load asks for one id.
    assert _in_clause_widths(statements, "exchange_requests") == [1]
    assert "request_id" in _where_clause(_proposals_statement(statements))


def test_the_query_count_does_not_grow_with_proposals_on_this_request(
    client, seeded
):
    """
    The N+1 check: more rows on the page must not mean more statements.
    Each proposal brings a proposer, a proposed service with its category
    and provider, and the nested request with its own relations — one
    lazy load per row would be dozens of queries.
    """
    session, statements = seeded

    get(client, OWNER)
    before = len(selects(statements))
    # A fixed cost: the caller's own row plus one SELECT per relationship in
    # the existing _query_proposals_with_relations chain (proposer and
    # profile, proposed service with its category and provider, the nested
    # request with its user, offered service, and both categories). The
    # number is bounded here only to catch an outright blow-up; that it
    # does not GROW is the assertion that matters, below.
    assert before <= 20, selects(statements)

    # 30 more proposals on MINE, from two different proposers and across
    # both categories, so nothing can be served from a single identity map.
    for offset in range(30):
        new_id = 3000 + offset
        proposer = PROPOSER_A if offset % 2 else PROPOSER_B
        session.add(Service(
            id=new_id, provider_id=proposer, category_id=(offset % 2) + 1,
            title=None, description="وصف", status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(ExchangeProposal(
            id=new_id, request_id=MINE, proposer_id=proposer,
            proposed_service_id=new_id, message="عرض إضافي",
            status=ExchangeProposalStatus.PENDING,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
    session.commit()
    session.expunge_all()
    statements.clear()

    response = get(client, OWNER)

    assert len(response.json()) == 33
    assert len(selects(statements)) == before, selects(statements)
