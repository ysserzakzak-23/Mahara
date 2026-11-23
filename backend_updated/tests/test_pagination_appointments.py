"""
Opt-in pagination on GET /api/v1/appointments/me (Phase 4, Group 2).

The same contract as Groups 0 and 1, so the same things are pinned down:

  * **no `page`/`page_size`** -> the complete bare JSON array, exactly what
    this endpoint has always returned, so an installed app build that
    cannot be updated keeps working;
  * **either parameter alone** -> one page in the shared envelope
    `{items, page, page_size, has_next}`, with no `total`;
  * `has_next` comes from fetching one row too many, never a COUNT(*);
  * `as_provider`, ownership and the response fields are untouched by
    pagination;
  * the order is still COALESCE(start_time, created_at) DESC, now with
    `id DESC` breaking ties so a page boundary cannot repeat or skip a row;
  * the eager loads survive the LIMIT: serialising a page still costs a
    fixed number of queries, not one per row (service.display_title feeds
    AppointmentResponse.service_title).

Runs against a throwaway in-memory SQLite database with the real models,
because page boundaries, ordering and query counts are only meaningful
against real SQL. The project's PostgreSQL database is never opened.
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
from app.models.appointment import Appointment, AppointmentStatus
from app.models.category import ServiceCategory
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole

ME = 2              # the user these tests log in as
OTHER = 3           # a third party, whose appointments must never show up

AS_CUSTOMER = 45    # appointments where ME is the customer
AS_PROVIDER = 12    # appointments where ME is the provider

BASE_TIME = datetime(2026, 10, 5, 12, 0)

# Distinct categories, so a wrongly-loaded category shows up as a wrong title.
CATEGORIES = {1: "سباكة", 2: "كهرباء", 3: "نجارة"}


@pytest.fixture
def seeded():
    """
    (session, statements) against a fresh in-memory database.

    `created_at` is set explicitly: everything is written in one
    transaction, so letting the database stamp it would give many rows the
    same value and make "newest first" ambiguous — which is exactly what
    the id tie-breaker is for.
    """
    # One shared connection, usable from any thread: TestClient runs the app
    # in a worker thread, which would otherwise get a different (empty)
    # in-memory database.
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

    for category_id, name in CATEGORIES.items():
        session.add(ServiceCategory(id=category_id, name=name))

    for user_id in (1, ME, OTHER):
        session.add(User(
            id=user_id, email=f"user{user_id}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True, is_active=True,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    # One service per category, each owned by a different provider.
    for service_id, category_id in enumerate(CATEGORIES, start=1):
        session.add(Service(
            id=service_id, provider_id=1, category_id=category_id,
            title=None, description="وصف الخدمة", status=ServiceStatus.ACTIVE,
            created_at=BASE_TIME, updated_at=BASE_TIME,
        ))

    def book(appointment_id, *, customer_id, provider_id, minutes, dated=True):
        session.add(Appointment(
            id=appointment_id,
            customer_id=customer_id,
            provider_id=provider_id,
            service_id=(appointment_id % len(CATEGORIES)) + 1,
            start_time=BASE_TIME + timedelta(minutes=minutes) if dated else None,
            end_time=BASE_TIME + timedelta(minutes=minutes + 60) if dated else None,
            status=AppointmentStatus.PENDING,
            created_at=BASE_TIME + timedelta(minutes=minutes),
            updated_at=BASE_TIME,
        ))

    for i in range(1, AS_CUSTOMER + 1):
        book(i, customer_id=ME, provider_id=1, minutes=i)

    for i in range(1, AS_PROVIDER + 1):
        book(1000 + i, customer_id=OTHER, provider_id=ME, minutes=i)

    # Someone else's booking entirely: not on either of ME's sides.
    book(9000, customer_id=OTHER, provider_id=1, minutes=5000)

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


PATH = "/api/v1/appointments/me"


def ids(body):
    rows = body["items"] if isinstance(body, dict) else body
    return [row["id"] for row in rows]


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


def counts(statements):
    return [s for s in selects(statements) if "count(" in s.lower()]


def get(client, query="", *, as_provider=None, user=ME):
    parts = []
    if as_provider is not None:
        parts.append(f"as_provider={str(as_provider).lower()}")
    if query:
        parts.append(query)
    url = PATH + ("?" + "&".join(parts) if parts else "")
    return client.get(url, headers=auth(user))


# ============================================= the legacy path (no parameters)

@pytest.mark.parametrize("as_provider, expected", [
    (None, AS_CUSTOMER),
    (False, AS_CUSTOMER),
    (True, AS_PROVIDER),
])
def test_without_parameters_the_whole_list_comes_back_as_an_array(
    client, as_provider, expected
):
    response = get(client, as_provider=as_provider)

    assert response.status_code == 200, response.text
    body = response.json()
    assert isinstance(body, list), "this endpoint must still answer with a bare array"
    assert len(body) == expected
    assert len(set(ids(body))) == expected          # no row repeated or lost


def test_the_legacy_response_carries_no_envelope_keys(client):
    body = get(client).json()

    assert isinstance(body, list)
    for row in body:
        assert "items" not in row and "has_next" not in row and "page" not in row


def test_the_legacy_response_still_has_every_field_it_had(client):
    row = get(client).json()[0]

    assert set(row) == {
        "id", "service_id", "service_title", "start_time", "end_time", "status",
        "customer_notes", "cancellation_reason", "created_at", "customer", "provider",
    }
    assert row["service_title"] in CATEGORIES.values()
    assert row["customer"]["id"] == ME
    assert row["status"] == "pending"


# ================================================================ the envelope

def test_a_paginated_request_answers_with_the_envelope(client):
    body = get(client, "page=1&page_size=10").json()

    assert isinstance(body, dict)
    assert set(body) == {"items", "page", "page_size", "has_next"}
    assert body["page"] == 1
    assert body["page_size"] == 10
    assert len(body["items"]) == 10
    assert body["has_next"] is True


def test_page_alone_opts_in_and_uses_the_default_page_size(client):
    body = get(client, "page=1").json()

    assert isinstance(body, dict)
    assert body["page_size"] == 20
    assert len(body["items"]) == 20


def test_page_size_alone_opts_in_and_starts_at_page_one(client):
    body = get(client, "page_size=5").json()

    assert isinstance(body, dict)
    assert body["page"] == 1
    assert len(body["items"]) == 5
    assert body["has_next"] is True


def test_no_total_is_returned(client):
    """Nothing on the bookings screen shows a count, so nothing pays for one."""
    assert "total" not in get(client, "page=1").json()


@pytest.mark.parametrize("query", ["", "page=1&page_size=5", "page=3&page_size=10"])
def test_no_count_query_is_ever_run(client, seeded, query):
    """
    `has_next` comes from the page_size + 1 probe row. A COUNT(*) would be a
    second full scan of the same filtered set, on every page, for a number
    nothing displays.
    """
    _, statements = seeded
    get(client, query)

    assert counts(statements) == []


def test_serialising_a_page_does_not_grow_with_the_rows_on_it(client, seeded):
    """
    The eager loads must survive the LIMIT pagination adds. A page of 40
    costs the same queries as a page of 2 — otherwise each extra row would
    lazy-load its customer, provider, service and category.
    """
    _, statements = seeded

    get(client, "page=1&page_size=2")
    small = len(selects(statements))

    statements.clear()
    get(client, "page=1&page_size=40")
    large = len(selects(statements))

    assert small == large, selects(statements)
    # the caller's own row, appointments, customers, providers, their two
    # profiles, services, categories
    assert large <= 8, selects(statements)


def test_every_row_on_a_page_has_its_own_service_title(client):
    """
    service_title is service.display_title, which is the category's name:
    the relationship that pagination could most easily have broken.
    """
    rows = get(client, "page=1&page_size=20").json()["items"]

    for row in rows:
        expected = CATEGORIES[(row["id"] % len(CATEGORIES)) + 1]
        assert row["service_title"] == expected, row
        assert row["customer"]["id"] == ME
        assert row["provider"]["id"] == 1


# ======================================================== pages and boundaries

@pytest.mark.parametrize("as_provider, expected", [
    (False, AS_CUSTOMER),
    (True, AS_PROVIDER),
])
def test_walking_every_page_yields_the_list_once_and_in_order(
    client, as_provider, expected
):
    whole = ids(get(client, as_provider=as_provider).json())

    collected, page = [], 1
    while True:
        body = get(client, f"page={page}&page_size=7", as_provider=as_provider).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1
        assert page < 50, "has_next never went false"

    assert collected == whole            # same rows, same order, no gaps
    assert len(collected) == expected
    assert len(set(collected)) == expected


def test_has_next_is_false_exactly_on_the_last_page(client):
    # 45 appointments, 15 per page -> three full pages and nothing after.
    flags = [get(client, f"page={p}&page_size=15").json()["has_next"] for p in (1, 2, 3)]

    assert flags == [True, True, False]


def test_a_page_that_divides_exactly_does_not_promise_another(client):
    body = get(client, f"page=1&page_size={AS_CUSTOMER}").json()

    assert len(body["items"]) == AS_CUSTOMER
    assert body["has_next"] is False


def test_the_last_partial_page_holds_the_remainder(client):
    # 45 rows, 20 per page -> 20 + 20 + 5.
    third = get(client, "page=3&page_size=20").json()

    assert len(third["items"]) == 5
    assert third["has_next"] is False


def test_a_page_past_the_end_is_empty_rather_than_an_error(client):
    response = get(client, "page=99&page_size=10")

    assert response.status_code == 200
    body = response.json()
    assert body["items"] == []
    assert body["has_next"] is False
    assert body["page"] == 99


@pytest.mark.parametrize("query", [
    "page=0", "page=-1", "page_size=0", "page_size=-5", "page_size=101",
    "page=abc", "page_size=abc", "page=1.5",
])
def test_invalid_pagination_values_are_still_a_422(client, query):
    assert get(client, query).status_code == 422, query


# ======================================================== deterministic order

def test_the_order_is_unchanged_and_undated_rows_sort_by_creation_time(client, seeded):
    """
    COALESCE(start_time, created_at) DESC: a booking with no agreed time
    sorts by when it was asked for, which is what it always did.
    """
    session, _ = seeded
    session.add(Appointment(
        id=500, customer_id=ME, provider_id=1, service_id=1,
        start_time=None, end_time=None, status=AppointmentStatus.PENDING,
        # Later than every dated row, so COALESCE puts it first.
        created_at=BASE_TIME + timedelta(days=1), updated_at=BASE_TIME,
    ))
    session.commit()

    first_page = get(client, "page=1&page_size=3").json()

    assert ids(first_page)[0] == 500
    assert first_page["items"][0]["start_time"] is None
    # and the dated rows follow, newest first
    assert ids(first_page)[1:] == [AS_CUSTOMER, AS_CUSTOMER - 1]


def test_rows_sharing_a_coalesce_value_are_split_by_id_across_a_boundary(
    client, seeded
):
    """
    Three rows with the same COALESCE(start_time, created_at). Without the
    id tie-breaker the database may order them differently between the two
    requests, and the page boundary would repeat or drop one.
    """
    session, _ = seeded
    shared = BASE_TIME + timedelta(hours=10)
    for new_id in (600, 601, 602):
        session.add(Appointment(
            id=new_id, customer_id=ME, provider_id=1, service_id=1,
            start_time=shared, end_time=shared + timedelta(hours=1),
            status=AppointmentStatus.PENDING,
            created_at=shared, updated_at=BASE_TIME,
        ))
    session.commit()

    first = ids(get(client, "page=1&page_size=2").json())
    second = ids(get(client, "page=2&page_size=2").json())

    assert first == [602, 601]        # descending id inside the shared value
    assert second[0] == 600           # the boundary neither repeats nor skips


def test_an_undated_row_sharing_created_at_with_a_dated_row_still_pages_cleanly(
    client, seeded
):
    """A COALESCE tie between a dated and an undated row is a tie as well."""
    session, _ = seeded
    moment = BASE_TIME + timedelta(hours=20)
    session.add(Appointment(
        id=700, customer_id=ME, provider_id=1, service_id=1,
        start_time=moment, end_time=moment + timedelta(hours=1),
        status=AppointmentStatus.PENDING, created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(Appointment(
        id=701, customer_id=ME, provider_id=1, service_id=1,
        start_time=None, end_time=None, status=AppointmentStatus.PENDING,
        created_at=moment, updated_at=BASE_TIME,
    ))
    session.commit()

    walked = []
    for page in (1, 2):
        walked += ids(get(client, f"page={page}&page_size=1").json())

    assert walked == [701, 700]
    assert len(set(walked)) == 2


# ============================================= as_provider, ownership, auth

def test_as_provider_picks_the_side_before_the_page_is_cut(client):
    customer_side = ids(get(client, "page=1&page_size=100", as_provider=False).json())
    provider_side = ids(get(client, "page=1&page_size=100", as_provider=True).json())

    assert len(customer_side) == AS_CUSTOMER
    assert len(provider_side) == AS_PROVIDER
    assert set(customer_side).isdisjoint(provider_side)  # a page never mixes sides


def test_a_paginated_page_only_ever_holds_your_own_appointments(client):
    for as_provider in (False, True):
        collected = []
        page = 1
        while True:
            body = get(client, f"page={page}&page_size=10", as_provider=as_provider).json()
            collected += body["items"]
            if not body["has_next"]:
                break
            page += 1

        for row in collected:
            assert ME in (row["customer"]["id"], row["provider"]["id"]), row
        assert 9000 not in [row["id"] for row in collected]


def test_another_users_page_holds_only_their_own(client):
    """The same page number for a different user is a different list."""
    mine = ids(get(client, "page=1&page_size=10").json())
    theirs = ids(get(client, "page=1&page_size=10", user=OTHER).json())

    assert mine
    assert set(mine).isdisjoint(theirs)


@pytest.mark.parametrize("query", ["", "page=1&page_size=10"])
def test_pagination_opens_no_door_for_an_anonymous_caller(client, query):
    url = PATH + (f"?{query}" if query else "")

    assert client.get(url).status_code == 401
