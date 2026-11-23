"""
exclude_user_id on GET /api/v1/exchange-requests (Phase 4, Group 3.2).

The Browse tab hides the viewer's own requests: they already have their own
tab, and proposing to yourself is refused anyway. That filter used to run
in the app — fetch every open request, then drop your own — which means the
rows travelled only to be thrown away, and a page of results could never be
counted on (the groundwork for paginating this list later).

It is now a WHERE clause. What these tests pin down:

  * absent, the list is byte-for-byte the list this endpoint always
    returned — what an installed app build that still filters client-side
    depends on;
  * present, that user's requests are gone and everyone else's are
    untouched;
  * the exclusion is in the SQL, not applied to the rows afterwards;
  * it composes with the filters that were already there (open status,
    active owner, active offered service) rather than replacing them;
  * it is a display filter, not an access check: the endpoint stays public
    and excluding a user is never a way to see more.

Runs against a throwaway in-memory SQLite database with the real models.
The project's PostgreSQL database is never opened.
"""
from datetime import datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.main import app
from app.models.category import ServiceCategory
from app.models.exchange import ExchangeRequest, ExchangeRequestStatus
from app.models.profile import UserProfile
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole

ALICE, BOB, CARL = 1, 2, 3
INACTIVE_OWNER = 4

BASE_TIME = datetime(2026, 10, 5, 12, 0)

PATH = "/api/v1/exchange-requests"


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

    session.add(ServiceCategory(id=1, name="سباكة"))
    session.add(ServiceCategory(id=2, name="كهرباء"))

    for user_id in (ALICE, BOB, CARL, INACTIVE_OWNER):
        session.add(User(
            id=user_id, email=f"u{user_id}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True,
            is_active=(user_id != INACTIVE_OWNER),
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(UserProfile(user_id=user_id, full_name=f"User {user_id}"))

    def service(service_id, owner, status=ServiceStatus.ACTIVE):
        session.add(Service(
            id=service_id, provider_id=owner, category_id=1, title=None,
            description="وصف الخدمة", status=status,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    def request(request_id, owner, *, status=ExchangeRequestStatus.OPEN,
                service_status=ServiceStatus.ACTIVE):
        service(request_id, owner, service_status)
        session.add(ExchangeRequest(
            id=request_id, user_id=owner, offered_service_id=request_id,
            offered_category_id=1, wanted_category_id=2, status=status,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    # Available: two of Alice's, two of Bob's, one of Carl's.
    request(1, ALICE)
    request(2, BOB)
    request(3, ALICE)
    request(4, CARL)
    request(5, BOB)

    # Never available, whatever exclude_user_id says — Alice owns two of
    # these, so excluding her must not be what hides them.
    request(6, ALICE, status=ExchangeRequestStatus.CLOSED)
    request(7, ALICE, service_status=ServiceStatus.INACTIVE)
    request(8, INACTIVE_OWNER)

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


AVAILABLE = [5, 4, 3, 2, 1]          # newest first, as this endpoint orders


def auth(user_id):
    return {"Authorization": f"Bearer {create_access_token(user_id)}"}


def ids(response):
    return [row["id"] for row in response.json()]


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


def _requests_statement(statements):
    """The one SELECT that reads the exchange_requests table itself."""
    found = [
        s for s in selects(statements)
        if "FROM exchange_requests" in s and "JOIN" in s
    ]
    assert len(found) == 1, found
    return found[0]


def _where_clause(statement):
    assert "WHERE" in statement, f"no WHERE at all in: {statement}"
    return statement.split("WHERE", 1)[1]


# =========================================== absent: exactly as it always was

def test_without_the_parameter_the_whole_available_list_comes_back(client):
    response = client.get(PATH)

    assert response.status_code == 200, response.text
    assert ids(response) == AVAILABLE


def test_the_legacy_call_is_untouched_for_a_logged_in_caller_too(client):
    """
    An installed build filters its own requests client-side and sends no
    exclusion. It must keep receiving everything, including its own.
    """
    response = client.get(PATH, headers=auth(ALICE))

    assert ids(response) == AVAILABLE
    assert 1 in ids(response) and 3 in ids(response)   # Alice's own


def test_the_endpoint_is_still_public(client):
    """No token, no parameter, same list."""
    assert ids(client.get(PATH)) == AVAILABLE


def test_the_response_fields_are_unchanged(client):
    row = client.get(PATH).json()[0]

    assert set(row) == {
        "id", "status", "user", "offered_service", "offered_category",
        "wanted_category", "wanted_custom_category_label",
    }
    assert row["user"]["profile"]["full_name"] == f"User {BOB}"
    assert row["offered_service"]["display_title"] == "سباكة"
    assert row["wanted_category"]["name"] == "كهرباء"


# ==================================================== present: rows are gone

def test_the_excluded_users_requests_are_left_out(client):
    response = client.get(f"{PATH}?exclude_user_id={ALICE}")

    assert response.status_code == 200
    assert ids(response) == [5, 4, 2]      # Alice's 1 and 3 are gone
    for row in response.json():
        assert row["user"]["id"] != ALICE


def test_everyone_elses_requests_are_still_all_there(client):
    """Excluding Alice must not cost Bob or Carl a single row."""
    everything = client.get(PATH).json()
    without_alice = client.get(f"{PATH}?exclude_user_id={ALICE}").json()

    expected = [r["id"] for r in everything if r["user"]["id"] != ALICE]
    assert [r["id"] for r in without_alice] == expected


@pytest.mark.parametrize("excluded, expected", [
    (ALICE, [5, 4, 2]),
    (BOB, [4, 3, 1]),
    (CARL, [5, 3, 2, 1]),
])
def test_each_user_can_be_excluded_in_turn(client, excluded, expected):
    assert ids(client.get(f"{PATH}?exclude_user_id={excluded}")) == expected


def test_excluding_a_user_with_no_requests_changes_nothing(client):
    assert ids(client.get(f"{PATH}?exclude_user_id=777")) == AVAILABLE


def test_the_order_survives_the_exclusion(client):
    """Still newest first; removing rows must not reshuffle the rest."""
    kept = ids(client.get(f"{PATH}?exclude_user_id={ALICE}"))

    assert kept == sorted(kept, reverse=True)


# ============================================= the exclusion is in the SQL

def test_the_exclusion_is_a_where_clause_not_a_python_filter(client, seeded):
    """
    The point of this substep. Filtering afterwards would leave the SELECT
    unrestricted and still carry every row out of the database.
    """
    _, statements = seeded
    client.get(f"{PATH}?exclude_user_id={ALICE}")

    where = _where_clause(_requests_statement(statements))
    assert "user_id !=" in where.replace("exchange_requests.", ""), where


def test_without_the_parameter_no_such_clause_is_added(client, seeded):
    _, statements = seeded
    client.get(PATH)

    where = _where_clause(_requests_statement(statements))
    assert "!=" not in where, where


def test_only_the_kept_rows_leave_the_database(client, seeded):
    """
    Proof that the filtering happened in SQL rather than after it: the
    eager loads follow up on three requests, not five.
    """
    _, statements = seeded
    client.get(f"{PATH}?exclude_user_id={ALICE}")

    widths = [
        s.split("IN (", 1)[1].split(")", 1)[0].count("?")
        for s in selects(statements)
        if "FROM service_categories" in s and "IN (" in s
    ]
    # Three kept rows -> their categories are fetched for three rows, and
    # every one of them is category 1, so a single id is asked for once.
    assert widths, selects(statements)
    assert all(width <= 1 for width in widths), widths

    users = [
        s.split("IN (", 1)[1].split(")", 1)[0].count("?")
        for s in selects(statements)
        if "FROM users" in s and "IN (" in s
    ]
    # Bob and Carl own the three kept rows. Alice would make it three.
    assert users and max(users) == 2, users


def test_the_query_count_does_not_grow_with_the_number_of_requests(
    client, seeded
):
    """No N+1: more rows must not mean more statements."""
    session, statements = seeded

    client.get(PATH)
    before = len(selects(statements))

    for new_id in range(100, 160):
        owner = BOB if new_id % 2 else CARL
        session.add(Service(
            id=new_id, provider_id=owner, category_id=(new_id % 2) + 1,
            title=None, description="وصف", status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
        session.add(ExchangeRequest(
            id=new_id, user_id=owner, offered_service_id=new_id,
            offered_category_id=(new_id % 2) + 1, wanted_category_id=2,
            status=ExchangeRequestStatus.OPEN,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))
    session.commit()
    session.expunge_all()
    statements.clear()

    response = client.get(f"{PATH}?exclude_user_id={ALICE}")

    assert len(response.json()) == 63        # 60 new + Bob's 2 + Carl's 1
    assert len(selects(statements)) == before, selects(statements)


# ======================= it composes with the filters that were there before

@pytest.mark.parametrize("excluded", [None, ALICE, BOB, CARL])
def test_the_unavailable_requests_stay_hidden_whatever_is_excluded(
    client, excluded
):
    """
    A closed request, one whose offered service is inactive, and one whose
    owner is deactivated are never listed. Alice owns the first two, so
    excluding her must not be what hides them.
    """
    url = PATH if excluded is None else f"{PATH}?exclude_user_id={excluded}"

    listed = ids(client.get(url))

    assert 6 not in listed, "a closed request was listed"
    assert 7 not in listed, "a request on an inactive service was listed"
    assert 8 not in listed, "a deactivated owner's request was listed"


def test_excluding_everyone_available_leaves_an_empty_list_not_the_hidden_rows(
    client,
):
    """
    Belt and braces: even with every available owner excluded one at a
    time, the unavailable rows never reappear.
    """
    remaining = set(AVAILABLE)
    for owner in (ALICE, BOB, CARL):
        listed = set(ids(client.get(f"{PATH}?exclude_user_id={owner}")))
        assert listed <= remaining
        assert listed.isdisjoint({6, 7, 8})


# ================================================= it is not an access check

def test_excluding_a_user_never_reveals_anything_extra(client):
    """
    The guard against treating this as authorization: whoever asks and
    whatever they exclude, the result is a subset of the public list.
    """
    public = set(ids(client.get(PATH)))

    for caller in (None, ALICE, BOB):
        headers = {} if caller is None else auth(caller)
        for excluded in (ALICE, BOB, CARL, 777):
            response = client.get(f"{PATH}?exclude_user_id={excluded}", headers=headers)
            assert response.status_code == 200
            assert set(ids(response)) <= public


def test_the_parameter_is_not_read_as_an_identity(client):
    """
    Excluding someone else's id is not a way to act as them: the response
    is the same list for any caller, since this endpoint shows only public
    rows and the parameter only subtracts.
    """
    as_alice = ids(client.get(f"{PATH}?exclude_user_id={BOB}", headers=auth(ALICE)))
    as_bob = ids(client.get(f"{PATH}?exclude_user_id={BOB}", headers=auth(BOB)))
    anonymous = ids(client.get(f"{PATH}?exclude_user_id={BOB}"))

    assert as_alice == as_bob == anonymous


@pytest.mark.parametrize("value", ["abc", "1.5", ""])
def test_a_non_integer_exclusion_is_a_422(client, value):
    assert client.get(f"{PATH}?exclude_user_id={value}").status_code == 422


def test_a_search_still_takes_the_exclusion_from_the_token(client):
    """
    /search is sent the token, so it keeps deriving the exclusion from the
    caller — untouched by this substep, and asserted here so that stays
    true.
    """
    mine = client.get(
        "/api/v1/exchange-requests/search?q=وصف الخدمة", headers=auth(ALICE)
    )

    assert mine.status_code == 200, mine.text
    assert all(row["user"]["id"] != ALICE for row in mine.json())
