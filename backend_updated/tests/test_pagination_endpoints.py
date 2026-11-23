"""
Opt-in pagination on the first three endpoints (Phase 4, Group 1):

    GET /api/v1/notifications
    GET /api/v1/admin/users
    GET /api/v1/admin/services

The contract these tests pin down:

  * **no `page`/`page_size`** -> a bare JSON array holding the whole
    collection, exactly what these endpoints have always returned. An
    installed app build that cannot be updated keeps working unchanged.
  * **either parameter present** -> one page in the shared envelope
    `{items, page, page_size, has_next}`. No endpoint returns `total`: no
    screen shows a count, and `has_next` already tells the app whether to
    keep asking.
  * `has_next` is decided by fetching one row too many, never by a
    COUNT(*) — asserted here by reading the SQL that actually ran, on
    every one of the three paths.
  * authorization, ownership and filtering are unchanged by pagination.
  * reading a page never marks a notification read.

Unlike the rest of the suite these run against a real (throwaway,
in-memory SQLite) database with the real models, because page boundaries
and ordering are only meaningful against real SQL. The project's
PostgreSQL database is never opened.
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
from app.models.notification import Notification, NotificationType
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole

NOTIFICATION_COUNT = 45
SERVICE_COUNT = 25
# 1 admin + 1 plain user + the service providers.
USER_COUNT = 2 + SERVICE_COUNT

BASE_TIME = datetime(2026, 10, 5, 12, 0)


# ------------------------------------------------------------------ fixtures

@pytest.fixture
def seeded():
    """
    (session, statements) against a fresh in-memory database.

    `created_at` is assigned explicitly: the rows are written in one
    transaction, so letting the database stamp them would give many rows
    the same timestamp and make "newest first" ambiguous — which is the
    very thing the id tie-breaker exists to settle.
    """
    # One shared connection, usable from any thread: TestClient runs the app
    # in a worker thread, and the default in-memory SQLite setup would give
    # that thread a different (empty) database.
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
    session.add(User(
        id=1, email="admin@example.com", hashed_password="x",
        role=UserRole.ADMIN, is_active=True, created_at=BASE_TIME, updated_at=BASE_TIME,
    ))
    session.add(User(
        id=2, email="user@example.com", hashed_password="x",
        role=UserRole.USER, is_active=True, created_at=BASE_TIME, updated_at=BASE_TIME,
    ))

    # User 2's notifications, plus one belonging to the admin that must
    # never appear in user 2's list however it is paged.
    for i in range(1, NOTIFICATION_COUNT + 1):
        session.add(Notification(
            id=i, user_id=2, type=NotificationType.SYSTEM,
            title=f"إشعار {i}", message="نص", is_read=(i % 5 == 0),
            created_at=BASE_TIME + timedelta(minutes=i), updated_at=BASE_TIME,
        ))
    session.add(Notification(
        id=999, user_id=1, type=NotificationType.SYSTEM,
        title="إشعار المشرف", message="نص", is_read=False,
        created_at=BASE_TIME + timedelta(days=1), updated_at=BASE_TIME,
    ))

    # Providers and their services. Half are suspended, so the status
    # filter has something to exclude.
    for i in range(1, SERVICE_COUNT + 1):
        provider_id = 100 + i
        session.add(User(
            id=provider_id, email=f"p{i}@example.com", hashed_password="x",
            role=UserRole.USER, is_provider=True, is_active=(i % 3 != 0),
            created_at=BASE_TIME + timedelta(minutes=i), updated_at=BASE_TIME,
        ))
        session.add(Service(
            id=i, provider_id=provider_id, category_id=1,
            title=f"خدمة {i}", description="وصف الخدمة",
            status=ServiceStatus.SUSPENDED if i % 2 == 0 else ServiceStatus.ACTIVE,
            created_at=BASE_TIME + timedelta(minutes=i), updated_at=BASE_TIME,
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


def auth(user_id):
    return {"Authorization": f"Bearer {create_access_token(user_id)}"}


USER = 2
ADMIN = 1


def ids(body):
    rows = body["items"] if isinstance(body, dict) else body
    return [row["id"] for row in rows]


def selects(statements):
    return [s for s in statements if s.lstrip().upper().startswith("SELECT")]


def counts(statements):
    return [s for s in selects(statements) if "count(" in s.lower()]


# ============================================= the legacy path (no parameters)

@pytest.mark.parametrize("path, user, expected", [
    ("/api/v1/notifications", USER, NOTIFICATION_COUNT),
    ("/api/v1/admin/users", ADMIN, USER_COUNT),
    ("/api/v1/admin/services", ADMIN, SERVICE_COUNT),
])
def test_without_parameters_the_whole_collection_comes_back_as_an_array(
    client, path, user, expected
):
    response = client.get(path, headers=auth(user))

    assert response.status_code == 200, response.text
    body = response.json()
    assert isinstance(body, list), f"{path} must still answer with a bare array"
    assert len(body) == expected
    assert len(set(ids(body))) == expected       # no row repeated or lost


@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
def test_the_legacy_response_has_no_envelope_keys_anywhere(client, path, user):
    """An old app build indexes the array directly; an envelope would break it."""
    body = client.get(path, headers=auth(user)).json()

    assert isinstance(body, list)
    for row in body:
        assert "items" not in row and "has_next" not in row


def test_the_legacy_notifications_path_runs_no_count_query(client, seeded):
    _, statements = seeded
    client.get("/api/v1/notifications", headers=auth(USER))

    assert counts(statements) == []
    assert len(selects(statements)) == 2        # the caller's own row, then the list


# ================================================================ the envelope

@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
def test_a_paginated_request_answers_with_the_envelope(client, path, user):
    response = client.get(f"{path}?page=1&page_size=10", headers=auth(user))

    assert response.status_code == 200, response.text
    body = response.json()
    assert isinstance(body, dict)
    assert set(body) == {"items", "page", "page_size", "has_next"}
    assert body["page"] == 1
    assert body["page_size"] == 10
    assert len(body["items"]) == 10
    assert body["has_next"] is True


@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
def test_either_parameter_alone_is_enough_to_opt_in(client, path, user):
    """`?page=1` and `?page_size=5` each turn pagination on by themselves."""
    page_only = client.get(f"{path}?page=1", headers=auth(user)).json()
    size_only = client.get(f"{path}?page_size=5", headers=auth(user)).json()

    assert isinstance(page_only, dict) and page_only["page_size"] == 20   # the default
    assert isinstance(size_only, dict) and size_only["page"] == 1
    assert len(size_only["items"]) == 5


@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
def test_no_endpoint_returns_a_total(client, path, user):
    """
    Nothing on screen shows a count, so nothing pays for one. `total` stays
    optional on the shared envelope for a future screen that does.
    """
    body = client.get(f"{path}?page=1", headers=auth(user)).json()

    assert "total" not in body


@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
@pytest.mark.parametrize("query", ["", "?page=1&page_size=5", "?page=2&page_size=10"])
def test_no_list_path_ever_runs_a_count_query(client, seeded, path, user, query):
    """
    `has_next` comes from fetching one row too many. A COUNT(*) here would
    be a second full scan of the same filtered set, on every page, for a
    number no screen displays.
    """
    _, statements = seeded
    client.get(f"{path}{query}", headers=auth(user))

    assert counts(statements) == []


@pytest.mark.parametrize("path, user", [
    ("/api/v1/notifications", USER),
    ("/api/v1/admin/users", ADMIN),
    ("/api/v1/admin/services", ADMIN),
])
def test_a_page_costs_the_same_number_of_queries_however_big_it_is(
    client, seeded, path, user
):
    """
    The query count must not grow with the rows on the page — that is the
    N+1 guarantee the eager loads exist for (Phase 1). The admin lists run
    one SELECT more than notifications because of that eager load, which
    is the point of it: one extra query instead of one per row.
    """
    _, statements = seeded

    client.get(f"{path}?page=1&page_size=5", headers=auth(user))
    small = len(selects(statements))

    statements.clear()
    client.get(f"{path}?page=1&page_size=40", headers=auth(user))
    large = len(selects(statements))

    assert small == large
    assert large <= 3, selects(statements)


# ======================================================== pages and boundaries

@pytest.mark.parametrize("path, user, expected", [
    ("/api/v1/notifications", USER, NOTIFICATION_COUNT),
    ("/api/v1/admin/users", ADMIN, USER_COUNT),
    ("/api/v1/admin/services", ADMIN, SERVICE_COUNT),
])
def test_walking_every_page_yields_the_collection_once_and_in_order(
    client, path, user, expected
):
    whole = ids(client.get(path, headers=auth(user)).json())

    collected, page = [], 1
    while True:
        body = client.get(f"{path}?page={page}&page_size=7", headers=auth(user)).json()
        collected += ids(body)
        if not body["has_next"]:
            break
        page += 1
        assert page < 50, "has_next never went false"

    assert collected == whole                   # same rows, same order, no gaps
    assert len(collected) == expected
    assert len(set(collected)) == expected      # and nothing twice


def test_has_next_is_false_exactly_on_the_last_page(client):
    # 45 notifications, 15 per page -> 3 full pages and nothing after.
    flags = [
        client.get(f"/api/v1/notifications?page={p}&page_size=15", headers=auth(USER))
        .json()["has_next"]
        for p in (1, 2, 3)
    ]

    assert flags == [True, True, False]


def test_a_page_that_divides_exactly_does_not_promise_another(client):
    """45 rows, 45 per page: everything fits, so has_next must be false."""
    body = client.get(
        f"/api/v1/notifications?page=1&page_size={NOTIFICATION_COUNT}", headers=auth(USER)
    ).json()

    assert len(body["items"]) == NOTIFICATION_COUNT
    assert body["has_next"] is False


def test_a_page_past_the_end_is_empty_rather_than_an_error(client):
    response = client.get("/api/v1/notifications?page=99&page_size=10", headers=auth(USER))

    assert response.status_code == 200
    body = response.json()
    assert body["items"] == []
    assert body["has_next"] is False
    assert body["page"] == 99


@pytest.mark.parametrize("query", [
    "page=0", "page=-1", "page_size=0", "page_size=-5", "page_size=101", "page=abc",
])
def test_pagination_parameters_are_validated(client, query):
    response = client.get(f"/api/v1/notifications?{query}", headers=auth(USER))

    assert response.status_code == 422, response.text


def test_ordering_is_newest_first_with_the_id_breaking_ties(client, seeded):
    """Rows sharing a created_at must still land in a fixed order."""
    session, _ = seeded
    shared = BASE_TIME + timedelta(hours=5)
    for new_id in (500, 501, 502):
        session.add(Notification(
            id=new_id, user_id=USER, type=NotificationType.SYSTEM,
            title="نفس الوقت", message="نص", created_at=shared, updated_at=BASE_TIME,
        ))
    session.commit()

    first_page = ids(
        client.get("/api/v1/notifications?page=1&page_size=2", headers=auth(USER)).json()
    )
    second_page = ids(
        client.get("/api/v1/notifications?page=2&page_size=2", headers=auth(USER)).json()
    )

    # Descending id within the shared timestamp, and the boundary between
    # the two pages neither repeats 500 nor skips it.
    assert first_page == [502, 501]
    assert second_page[0] == 500


# ============================================ filters, ownership, authorization

def test_a_paginated_notification_list_still_only_shows_your_own(client):
    body = client.get("/api/v1/notifications?page=1&page_size=50", headers=auth(USER)).json()

    assert 999 not in ids(body), "the admin's notification leaked into user 2's list"
    assert len(body["items"]) == NOTIFICATION_COUNT


def test_the_unread_filter_survives_pagination(client):
    unread_total = NOTIFICATION_COUNT - NOTIFICATION_COUNT // 5

    whole = client.get("/api/v1/notifications?unread_only=true", headers=auth(USER)).json()
    paged = client.get(
        "/api/v1/notifications?unread_only=true&page=1&page_size=100", headers=auth(USER)
    ).json()

    assert len(whole) == unread_total
    assert ids(paged) == ids(whole)


def test_the_admin_user_filters_survive_pagination(client):
    inactive_total = SERVICE_COUNT // 3        # every third provider

    whole = client.get("/api/v1/admin/users?is_active=false", headers=auth(ADMIN)).json()
    paged = client.get(
        "/api/v1/admin/users?is_active=false&page=1&page_size=100", headers=auth(ADMIN)
    ).json()

    assert len(whole) == inactive_total
    assert ids(paged) == ids(whole)
    assert paged["has_next"] is False


def test_the_admin_service_status_filter_survives_pagination(client):
    suspended_total = SERVICE_COUNT // 2

    whole = client.get("/api/v1/admin/services?status=suspended", headers=auth(ADMIN)).json()
    paged = client.get(
        "/api/v1/admin/services?status=suspended&page=1&page_size=4", headers=auth(ADMIN)
    ).json()

    assert len(whole) == suspended_total
    assert ids(paged) == ids(whole)[:4]
    assert paged["has_next"] is True


@pytest.mark.parametrize("path", ["/api/v1/admin/users", "/api/v1/admin/services"])
@pytest.mark.parametrize("query", ["", "?page=1&page_size=10"])
def test_pagination_opens_no_door_for_a_non_admin(client, path, query):
    assert client.get(f"{path}{query}").status_code == 401
    assert client.get(f"{path}{query}", headers=auth(USER)).status_code == 403


@pytest.mark.parametrize("query", ["", "?page=1&page_size=10"])
def test_the_notification_list_still_needs_a_token(client, query):
    assert client.get(f"/api/v1/notifications{query}").status_code == 401


# ================================================= reading never changes a row

def test_loading_any_page_leaves_every_notification_as_it_was(client, seeded):
    """
    The one behaviour the Flutter screen depends on: scrolling to page 2
    must not mark anything read. Only the mark-read endpoints may.
    """
    session, _ = seeded
    before = {n.id: n.is_read for n in session.query(Notification).all()}

    for page in (1, 2, 3, 4):
        client.get(f"/api/v1/notifications?page={page}&page_size=10", headers=auth(USER))
    client.get("/api/v1/notifications", headers=auth(USER))

    session.expire_all()
    after = {n.id: n.is_read for n in session.query(Notification).all()}
    assert after == before


def test_marking_one_read_still_works_and_is_the_only_thing_that_does(client, seeded):
    session, _ = seeded
    assert session.get(Notification, 1).is_read is False

    client.get("/api/v1/notifications?page=1&page_size=5", headers=auth(USER))
    session.expire_all()
    assert session.get(Notification, 1).is_read is False

    assert client.post("/api/v1/notifications/1/read", headers=auth(USER)).status_code == 200
    session.expire_all()
    assert session.get(Notification, 1).is_read is True
