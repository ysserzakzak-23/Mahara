"""
HTTP-level tests: real FastAPI app + TestClient, with the database session
replaced by a MagicMock and the service layer patched where a route needs data.

They verify what only the router layer can: URL wiring, status codes, who is
allowed in (401 / 403), request validation (422), error mapping (409, ...) and
response shapes. The TestClient is NOT used as a context manager, so startup
hooks (semantic-search model warm-up) never run.
"""
from datetime import datetime
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.core.database import get_db
from app.core.exceptions import (
    ConflictError,
    InvalidCredentialsError,
    PermissionDeniedError,
)
from app.core.security import create_access_token, create_refresh_token
from app.main import app
from app.models.user import UserRole
from app.schemas.admin import PlatformStatsResponse
from app.services import admin_service, appointment_service, category_service, user_service


@pytest.fixture
def fake_db():
    return MagicMock(name="Session")


@pytest.fixture
def client(fake_db):
    app.dependency_overrides[get_db] = lambda: fake_db
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def user_obj(id=1, role=UserRole.USER, is_active=True):
    return SimpleNamespace(
        id=id, email=f"user{id}@example.com", role=role, is_provider=False,
        is_active=is_active, created_at=datetime(2026, 10, 5, 12, 0), profile=None,
    )


def login_as(fake_db, id=1, role=UserRole.USER, is_active=True):
    """Makes the auth dependency accept a real signed token for this user."""
    fake_db.get.return_value = user_obj(id, role, is_active)
    return {"Authorization": f"Bearer {create_access_token(id)}"}


# ============================================================ wiring / smoke

def test_health_endpoint(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_unknown_route_is_404(client):
    assert client.get("/api/v1/does-not-exist").status_code == 404


def test_wrong_http_method_is_405(client):
    assert client.delete("/api/v1/auth/login").status_code == 405


def test_every_router_is_mounted(client):
    paths = client.get("/openapi.json").json()["paths"]
    expected = [
        "/api/v1/auth/login", "/api/v1/users/me", "/api/v1/categories",
        "/api/v1/services", "/api/v1/appointments", "/api/v1/notifications",
        "/api/v1/admin/stats", "/api/v1/exchange-requests", "/api/v1/uploads/image",
    ]
    for path in expected:
        assert path in paths, f"{path} is not mounted"


# ================================================================== auth guard

PROTECTED = [
    ("GET", "/api/v1/users/me"),
    ("GET", "/api/v1/appointments/me"),
    ("POST", "/api/v1/appointments"),
    ("POST", "/api/v1/services"),
    ("GET", "/api/v1/notifications/unread-count"),
    ("GET", "/api/v1/exchange-requests/me"),
    ("GET", "/api/v1/exchange-requests/interests"),
    ("GET", "/api/v1/admin/stats"),
]


@pytest.mark.parametrize("method, path", PROTECTED)
def test_protected_routes_reject_missing_token(client, method, path):
    response = client.request(method, path, json={} if method == "POST" else None)
    assert response.status_code == 401


@pytest.mark.parametrize("method, path", PROTECTED)
def test_protected_routes_reject_a_garbage_token(client, method, path):
    response = client.request(
        method, path, headers={"Authorization": "Bearer not-a-token"},
        json={} if method == "POST" else None,
    )
    assert response.status_code == 401


def test_refresh_token_cannot_be_used_as_an_access_token(client, fake_db):
    fake_db.get.return_value = user_obj()
    response = client.get(
        "/api/v1/users/me", headers={"Authorization": f"Bearer {create_refresh_token(1)}"}
    )
    assert response.status_code == 401


def test_deactivated_users_token_stops_working(client, fake_db):
    headers = login_as(fake_db, is_active=False)
    assert client.get("/api/v1/users/me", headers=headers).status_code == 401


def test_token_of_a_deleted_user_stops_working(client, fake_db):
    headers = login_as(fake_db)
    fake_db.get.return_value = None
    assert client.get("/api/v1/users/me", headers=headers).status_code == 401


def test_current_user_endpoint_returns_the_profile_payload(client, fake_db):
    response = client.get("/api/v1/users/me", headers=login_as(fake_db, id=7))
    body = response.json()

    assert response.status_code == 200
    assert body["id"] == 7 and body["email"] == "user7@example.com"
    assert "hashed_password" not in body


# ============================================================== admin guard

ADMIN_ROUTES = [
    ("GET", "/api/v1/admin/stats", None),
    ("GET", "/api/v1/admin/users", None),
    ("GET", "/api/v1/admin/services", None),
    ("PUT", "/api/v1/admin/users/2/role", {"role": "admin"}),
    ("PUT", "/api/v1/admin/users/2/active-status", {"is_active": False}),
    ("PUT", "/api/v1/admin/services/1/status", {"status": "suspended"}),
]


@pytest.mark.parametrize("method, path, body", ADMIN_ROUTES)
def test_regular_users_are_forbidden_from_admin_routes(client, fake_db, method, path, body):
    response = client.request(method, path, headers=login_as(fake_db), json=body)
    assert response.status_code == 403


def test_admin_can_read_platform_stats(client, fake_db, monkeypatch):
    monkeypatch.setattr(
        admin_service, "get_platform_stats",
        lambda db: PlatformStatsResponse(
            total_users=10, total_providers=3, active_services=5, total_appointments=20,
            completed_appointments=8, total_reviews=6, average_platform_rating=4.5,
        ),
    )
    response = client.get("/api/v1/admin/stats", headers=login_as(fake_db, role=UserRole.ADMIN))

    assert response.status_code == 200
    assert response.json()["total_users"] == 10
    assert response.json()["average_platform_rating"] == 4.5


def test_admin_user_list_passes_filters_to_the_service(client, fake_db, monkeypatch):
    captured = {}

    def fake_list(db, role=None, is_active=None, params=None):
        captured.update(role=role, is_active=is_active)
        return [user_obj(2)], False

    monkeypatch.setattr(admin_service, "list_users", fake_list)
    response = client.get(
        "/api/v1/admin/users?role=user&is_active=false",
        headers=login_as(fake_db, role=UserRole.ADMIN),
    )

    assert response.status_code == 200
    assert captured == {"role": UserRole.USER, "is_active": False}
    assert response.json()[0]["id"] == 2


def test_invalid_enum_filter_is_a_validation_error(client, fake_db):
    response = client.get(
        "/api/v1/admin/users?role=superuser", headers=login_as(fake_db, role=UserRole.ADMIN)
    )
    assert response.status_code == 422


# ============================================================== categories

CATEGORY = SimpleNamespace(
    id=1, name="Plumbing", description=None, icon_name=None, is_active=True, is_other=False
)


def test_listing_categories_is_public(client, monkeypatch):
    monkeypatch.setattr(category_service, "list_categories", lambda db, include_inactive=False: [CATEGORY])
    response = client.get("/api/v1/categories")

    assert response.status_code == 200
    assert response.json()[0]["name"] == "Plumbing"


def test_creating_a_category_requires_admin(client, fake_db, monkeypatch):
    monkeypatch.setattr(category_service, "create_category", lambda db, payload: CATEGORY)
    body = {"name": "Plumbing"}

    assert client.post("/api/v1/categories", json=body).status_code == 401
    assert client.post("/api/v1/categories", json=body, headers=login_as(fake_db)).status_code == 403

    admin = login_as(fake_db, role=UserRole.ADMIN)
    response = client.post("/api/v1/categories", json=body, headers=admin)
    assert response.status_code == 201
    assert response.json()["name"] == "Plumbing"


def test_updating_a_category_requires_admin(client, fake_db):
    response = client.patch("/api/v1/categories/1", json={"name": "New"}, headers=login_as(fake_db))
    assert response.status_code == 403


def test_category_validation_error_is_422(client, fake_db):
    admin = login_as(fake_db, role=UserRole.ADMIN)
    assert client.post("/api/v1/categories", json={"name": "x"}, headers=admin).status_code == 422


# ===================================================================== auth

def test_register_returns_201_with_the_new_user(client, monkeypatch):
    monkeypatch.setattr(user_service, "register_user", lambda db, payload: user_obj(5))
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "new@example.com", "password": "Secret123!", "full_name": "New User", "city": "دمشق"},
    )

    assert response.status_code == 201
    assert response.json()["id"] == 5
    assert "password" not in response.text


def test_register_rejects_invalid_payloads(client):
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "not-an-email", "password": "Secret123!", "full_name": "New", "city": "دمشق"},
    )
    assert response.status_code == 422


def test_register_duplicate_email_is_409(client, monkeypatch):
    def duplicate(db, payload):
        raise ConflictError("An account with this email already exists")

    monkeypatch.setattr(user_service, "register_user", duplicate)
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "dup@example.com", "password": "Secret123!", "full_name": "Dup User", "city": "دمشق"},
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "An account with this email already exists"


def test_login_returns_a_token_pair(client, monkeypatch):
    monkeypatch.setattr(user_service, "authenticate_user", lambda db, email, pw: SimpleNamespace(id=3))
    response = client.post("/api/v1/auth/login", json={"email": "a@example.com", "password": "pw"})

    body = response.json()
    assert response.status_code == 200
    assert body["access_token"] and body["refresh_token"]
    assert body["token_type"] == "bearer"


def test_login_with_wrong_credentials_is_401(client, monkeypatch):
    def reject(db, email, pw):
        raise InvalidCredentialsError()

    monkeypatch.setattr(user_service, "authenticate_user", reject)
    response = client.post("/api/v1/auth/login", json={"email": "a@example.com", "password": "bad"})
    assert response.status_code == 401


def test_login_requires_both_fields(client):
    assert client.post("/api/v1/auth/login", json={"email": "a@example.com"}).status_code == 422


def test_refresh_rotates_the_token_pair(client, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_id", lambda db, uid: user_obj(uid))
    response = client.post("/api/v1/auth/refresh", json={"refresh_token": create_refresh_token(4)})

    assert response.status_code == 200
    assert response.json()["access_token"] and response.json()["refresh_token"]


def test_refresh_rejects_an_access_token(client):
    response = client.post("/api/v1/auth/refresh", json={"refresh_token": create_access_token(4)})
    assert response.status_code == 401


def test_refresh_rejects_garbage(client):
    assert client.post("/api/v1/auth/refresh", json={"refresh_token": "junk"}).status_code == 401


def test_refresh_rejects_deactivated_accounts(client, monkeypatch):
    monkeypatch.setattr(
        user_service, "get_user_by_id", lambda db, uid: user_obj(uid, is_active=False)
    )
    response = client.post("/api/v1/auth/refresh", json={"refresh_token": create_refresh_token(4)})
    assert response.status_code == 401


# ============================================================== appointments

def test_booking_validates_the_time_range_before_touching_the_service(client, fake_db):
    response = client.post(
        "/api/v1/appointments",
        headers=login_as(fake_db),
        json={"service_id": 1, "start_time": "2026-10-05T11:00:00", "end_time": "2026-10-05T10:00:00"},
    )
    assert response.status_code == 422


def test_domain_errors_become_http_errors(client, fake_db, monkeypatch):
    headers = login_as(fake_db)

    def conflict(db, appointment_id, user):
        raise ConflictError("Only pending appointments can be accepted")

    monkeypatch.setattr(appointment_service, "accept_appointment", conflict)
    response = client.post("/api/v1/appointments/5/accept", headers=headers)
    assert response.status_code == 409
    assert response.json()["detail"] == "Only pending appointments can be accepted"

    def forbidden(db, appointment_id, user):
        raise PermissionDeniedError("Only the provider can accept")

    monkeypatch.setattr(appointment_service, "accept_appointment", forbidden)
    assert client.post("/api/v1/appointments/5/accept", headers=headers).status_code == 403


def test_non_numeric_ids_are_rejected(client, fake_db):
    response = client.post("/api/v1/appointments/abc/accept", headers=login_as(fake_db))
    assert response.status_code == 422


def test_creating_a_service_validates_input(client, fake_db):
    response = client.post(
        "/api/v1/services", headers=login_as(fake_db),
        json={"category_id": 1, "title": "x", "description": "short", "price": "-5"},
    )
    assert response.status_code == 422
