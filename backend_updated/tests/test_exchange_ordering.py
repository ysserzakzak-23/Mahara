"""
Deterministic ordering for GET /exchange-requests/me and
GET /exchange-proposals/me (Phase 4, Group 3.3).

Both queries had no ORDER BY, so the rows came back in whatever order the
database found convenient — «طلباتي» and the two proposal tabs could
reshuffle between two openings, and a page boundary drawn across such a
list would repeat or skip rows. Nothing downstream could fix it either:
neither response schema carries a timestamp, so the server's order is the
only order there is.

Both are now ordered by the record's own `created_at` DESC with `id` DESC
breaking ties. These tests check that from both directions:

  * the rows really come back newest first, and by descending id when the
    timestamps are equal — which they are for records written in one
    transaction;
  * the ORDER BY is in the SQL, naming the right table's column (the
    received-proposals branch joins exchange_requests, which has a
    `created_at` of its own);
  * inserting unrelated rows — other people's, other statuses, the other
    side of the same tab — does not disturb it;
  * the filters, ownership and sent/received semantics are untouched.

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
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole

ME = 1
OTHER = 2          # owns requests of their own, and proposes on mine
THIRD = 3          # another proposer, so «received» holds more than one sender

BASE_TIME = datetime(2026, 10, 5, 12, 0)

REQUESTS_PATH = "/api/v1/exchange-requests/me"
PROPOSALS_PATH = "/api/v1/exchange-proposals/me"


@pytest.fixture
def seeded():
    """
    (session, statements) against a fresh in-memory database.

    Timestamps are assigned explicitly, and several rows deliberately share
    one: that is the case the id tie-breaker exists for, and it is what
    rows written in a single transaction actually look like.
    """
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

    for user_id in (ME, OTHER, THIRD):
        session.add(User(
            id=user_id, email=f"u{user_id}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True, is_active=True,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(UserProfile(user_id=user_id, full_name=f"User {user_id}"))
        session.add(Service(
            id=user_id, provider_id=user_id, category_id=1, title=None,
            description="وصف الخدمة", status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    def request(request_id, owner, *, minutes, status=ExchangeRequestStatus.OPEN):
        session.add(ExchangeRequest(
            id=request_id, user_id=owner, offered_service_id=owner,
            offered_category_id=1, wanted_category_id=2, status=status,
            created_at=BASE_TIME + timedelta(minutes=minutes),
            updated_at=BASE_TIME,
        ))

    def proposal(proposal_id, *, request_id, proposer, minutes,
                 status=ExchangeProposalStatus.PENDING):
        session.add(ExchangeProposal(
            id=proposal_id, request_id=request_id, proposer_id=proposer,
            proposed_service_id=proposer, message=f"عرض {proposal_id}",
            status=status,
            created_at=BASE_TIME + timedelta(minutes=minutes),
            updated_at=BASE_TIME,
        ))

    # ---- my own requests. 20 and 21 share a timestamp; so do 30 and 31.
    request(10, ME, minutes=5)
    request(20, ME, minutes=10)
    request(21, ME, minutes=10)                                  # tie with 20
    request(30, ME, minutes=1)
    request(31, ME, minutes=1)                                   # tie with 30
    request(40, ME, minutes=20, status=ExchangeRequestStatus.CLOSED)
    request(41, ME, minutes=15, status=ExchangeRequestStatus.MATCHED)

    # ---- other people's requests, which must never appear under /me.
    request(900, OTHER, minutes=99)
    request(901, THIRD, minutes=98)

    # ---- proposals I sent, on other people's requests.
    proposal(100, request_id=900, proposer=ME, minutes=5)
    proposal(110, request_id=901, proposer=ME, minutes=10)
    proposal(111, request_id=900, proposer=ME, minutes=10)       # tie with 110
    proposal(120, request_id=901, proposer=ME, minutes=1,
             status=ExchangeProposalStatus.REJECTED)

    # ---- proposals received on my requests, from two different senders.
    proposal(200, request_id=10, proposer=OTHER, minutes=7)
    proposal(210, request_id=20, proposer=THIRD, minutes=12)
    proposal(211, request_id=21, proposer=OTHER, minutes=12)     # tie with 210
    proposal(220, request_id=10, proposer=THIRD, minutes=2,
             status=ExchangeProposalStatus.ACCEPTED)

    # ---- a proposal between two other people: neither sent nor received.
    proposal(999, request_id=901, proposer=OTHER, minutes=50)

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


def ids(response):
    assert response.status_code == 200, response.text
    return [row["id"] for row in response.json()]


def my_requests(client, user=ME):
    return ids(client.get(REQUESTS_PATH, headers=auth(user)))


def my_proposals(client, *, sent, user=ME):
    return ids(client.get(
        f"{PROPOSALS_PATH}?sent={str(sent).lower()}", headers=auth(user)
    ))


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


def _main_statement(statements, table):
    """The one SELECT that reads `table` itself (not an eager-load follow-up)."""
    found = [
        s for s in selects(statements)
        if f"FROM {table}" in s and "ORDER BY" in s
    ]
    assert len(found) == 1, selects(statements)
    return found[0]


def _order_by(statement):
    assert "ORDER BY" in statement, f"no ORDER BY in: {statement}"
    return statement.split("ORDER BY", 1)[1]


# =========================================================== my own requests

# Newest first, and descending id inside each shared timestamp.
EXPECTED_REQUESTS = [40, 41, 21, 20, 10, 31, 30]


def test_my_requests_come_back_newest_first(client):
    assert my_requests(client) == EXPECTED_REQUESTS


def test_requests_sharing_a_timestamp_are_ordered_by_descending_id(client):
    listed = my_requests(client)

    # 20 and 21 were created in the same minute, 30 and 31 likewise.
    assert listed.index(21) < listed.index(20)
    assert listed.index(31) < listed.index(30)


def test_the_request_order_is_the_same_every_time(client):
    """
    The property that was missing. Repeating the call must not reshuffle,
    which is also what makes a page boundary safe in the next substep.
    """
    runs = [my_requests(client) for _ in range(5)]

    assert runs.count(runs[0]) == 5, runs


def test_the_request_order_survives_unrelated_rows(client, seeded):
    """Other people's requests must not disturb mine."""
    session, _ = seeded
    before = my_requests(client)

    for new_id in range(500, 540):
        session.add(ExchangeRequest(
            id=new_id, user_id=OTHER, offered_service_id=OTHER,
            offered_category_id=1, wanted_category_id=2,
            status=ExchangeRequestStatus.OPEN,
            created_at=BASE_TIME + timedelta(minutes=new_id),
            updated_at=BASE_TIME,
        ))
    session.commit()
    session.expunge_all()

    assert my_requests(client) == before


def test_a_newly_opened_request_lands_at_the_top(client, seeded):
    """Newest first, demonstrated rather than assumed from the fixture."""
    session, _ = seeded
    session.add(ExchangeRequest(
        id=777, user_id=ME, offered_service_id=ME,
        offered_category_id=1, wanted_category_id=2,
        status=ExchangeRequestStatus.OPEN,
        created_at=BASE_TIME + timedelta(days=1), updated_at=BASE_TIME,
    ))
    session.commit()

    assert my_requests(client)[0] == 777


def test_my_requests_still_hold_only_mine_and_every_status(client):
    listed = my_requests(client)

    assert 900 not in listed and 901 not in listed
    assert set(listed) == {10, 20, 21, 30, 31, 40, 41}   # closed/matched kept


def test_another_user_gets_their_own_requests_in_their_own_order(client):
    assert my_requests(client, user=OTHER) == [900]
    assert my_requests(client, user=THIRD) == [901]


def test_the_request_order_by_is_in_the_sql(client, seeded):
    _, statements = seeded
    client.get(REQUESTS_PATH, headers=auth())

    clause = _order_by(_main_statement(statements, "exchange_requests"))
    assert "exchange_requests.created_at DESC" in clause, clause
    assert "exchange_requests.id DESC" in clause, clause
    assert clause.index("created_at") < clause.index("exchange_requests.id"), clause


# ============================================================ sent proposals

EXPECTED_SENT = [111, 110, 100, 120]


def test_sent_proposals_come_back_newest_first(client):
    assert my_proposals(client, sent=True) == EXPECTED_SENT


def test_sent_proposals_sharing_a_timestamp_are_ordered_by_descending_id(client):
    listed = my_proposals(client, sent=True)

    assert listed.index(111) < listed.index(110)


def test_the_sent_order_is_the_same_every_time(client):
    runs = [my_proposals(client, sent=True) for _ in range(5)]

    assert runs.count(runs[0]) == 5, runs


def test_sent_proposals_exclude_everyone_elses(client):
    listed = my_proposals(client, sent=True)

    assert 999 not in listed                     # between two other people
    assert all(i not in listed for i in (200, 210, 211, 220))   # received
    assert set(listed) == {100, 110, 111, 120}


def test_the_sent_order_by_is_in_the_sql(client, seeded):
    _, statements = seeded
    client.get(f"{PROPOSALS_PATH}?sent=true", headers=auth())

    clause = _order_by(_main_statement(statements, "exchange_proposals"))
    assert "exchange_proposals.created_at DESC" in clause, clause
    assert "exchange_proposals.id DESC" in clause, clause


# ======================================================== received proposals

EXPECTED_RECEIVED = [211, 210, 200, 220]


def test_received_proposals_come_back_newest_first(client):
    assert my_proposals(client, sent=False) == EXPECTED_RECEIVED


def test_received_proposals_sharing_a_timestamp_are_ordered_by_descending_id(
    client,
):
    listed = my_proposals(client, sent=False)

    assert listed.index(211) < listed.index(210)


def test_the_received_order_is_the_same_every_time(client):
    runs = [my_proposals(client, sent=False) for _ in range(5)]

    assert runs.count(runs[0]) == 5, runs


def test_received_proposals_are_sorted_by_the_proposals_own_timestamp(
    client, seeded,
):
    """
    Not the request's. The received branch joins exchange_requests, which
    carries a `created_at` of its own; sorting by that would order the
    newest proposal on an old request last.
    """
    session, _ = seeded
    # Request 30 is one of my oldest; a brand-new proposal on it must still
    # come first.
    session.add(ExchangeProposal(
        id=300, request_id=30, proposer_id=OTHER, proposed_service_id=OTHER,
        message="أحدث عرض", status=ExchangeProposalStatus.PENDING,
        created_at=BASE_TIME + timedelta(days=1), updated_at=BASE_TIME,
    ))
    session.commit()

    assert my_proposals(client, sent=False)[0] == 300


def test_received_proposals_exclude_the_ones_i_sent(client):
    listed = my_proposals(client, sent=False)

    assert 999 not in listed
    assert all(i not in listed for i in (100, 110, 111, 120))
    assert set(listed) == {200, 210, 211, 220}


def test_the_received_order_by_names_the_proposal_table(client, seeded):
    """
    Both joined tables have a created_at, so the clause must say which.
    An unqualified column would be ambiguous — or silently the wrong one.
    """
    _, statements = seeded
    client.get(f"{PROPOSALS_PATH}?sent=false", headers=auth())

    statement = _main_statement(statements, "exchange_proposals")
    assert "JOIN exchange_requests" in statement, statement

    clause = _order_by(statement)
    assert "exchange_proposals.created_at DESC" in clause, clause
    assert "exchange_proposals.id DESC" in clause, clause
    assert "exchange_requests.created_at" not in clause, clause


def test_the_two_tabs_stay_separate_lists(client):
    sent = my_proposals(client, sent=True)
    received = my_proposals(client, sent=False)

    assert set(sent).isdisjoint(received)
    assert sent == EXPECTED_SENT
    assert received == EXPECTED_RECEIVED


def test_the_proposal_order_survives_unrelated_rows(client, seeded):
    session, _ = seeded
    sent_before = my_proposals(client, sent=True)
    received_before = my_proposals(client, sent=False)

    # Proposals between two other people, on someone else's request.
    for new_id in range(600, 640):
        session.add(ExchangeProposal(
            id=new_id, request_id=900, proposer_id=THIRD,
            proposed_service_id=THIRD, message="ضجيج",
            status=ExchangeProposalStatus.PENDING,
            created_at=BASE_TIME + timedelta(minutes=new_id),
            updated_at=BASE_TIME,
        ))
    session.commit()
    session.expunge_all()

    assert my_proposals(client, sent=True) == sent_before
    assert my_proposals(client, sent=False) == received_before


# ====================================== nothing else about them has changed

def test_a_row_still_carries_the_same_fields(client):
    row = client.get(f"{PROPOSALS_PATH}?sent=false", headers=auth()).json()[0]

    assert set(row) == {"id", "status", "message", "proposer", "proposed_service", "request"}
    assert "created_at" not in row, "ordering must not have leaked a new field"


def test_a_request_row_still_carries_the_same_fields(client):
    row = client.get(REQUESTS_PATH, headers=auth()).json()[0]

    assert set(row) == {
        "id", "status", "user", "offered_service", "offered_category",
        "wanted_category", "wanted_custom_category_label",
    }
    assert "created_at" not in row


@pytest.mark.parametrize("path", [REQUESTS_PATH, f"{PROPOSALS_PATH}?sent=true"])
def test_both_endpoints_still_need_a_token(client, path):
    assert client.get(path).status_code == 401


def test_neither_endpoint_runs_a_count_query(client, seeded):
    """Ordering is all this substep adds — no counting, no pagination."""
    _, statements = seeded

    client.get(REQUESTS_PATH, headers=auth())
    client.get(f"{PROPOSALS_PATH}?sent=true", headers=auth())
    client.get(f"{PROPOSALS_PATH}?sent=false", headers=auth())

    assert [s for s in selects(statements) if "count(" in s.lower()] == []


def test_neither_endpoint_grew_a_limit(client, seeded):
    _, statements = seeded
    client.get(REQUESTS_PATH, headers=auth())

    statement = _main_statement(statements, "exchange_requests")
    assert "LIMIT" not in statement.upper(), statement
