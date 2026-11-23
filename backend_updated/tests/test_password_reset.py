"""
Tests for the new auth rules and the "forgot password" flow:
  * password >= 8 characters, phone >= 10 digits (Arabic error messages)
  * POST /auth/forgot-password and /auth/reset-password
  * password_reset_service (code generation, expiry, attempts, hashing)
"""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError as PydanticValidationError

from app.core.database import get_db
from app.core.exceptions import ValidationError
from app.main import app
from app.models.password_reset import PasswordResetToken
from app.schemas.user import ResetPasswordRequest, UserProfileUpdateRequest, UserRegisterRequest
from app.services import password_reset_service as svc
from app.services import user_service


def registration(**overrides):
    data = {
        "email": "a@example.com",
        "password": "Secret123!",
        "full_name": "Test User",
        "phone_number": "0912345678",
        "city": "دمشق",
    }
    data.update(overrides)
    return data


# ------------------------------------------------------------------ schemas

def test_password_shorter_than_8_is_rejected_in_arabic():
    with pytest.raises(PydanticValidationError):
        UserRegisterRequest(**registration(password="1234567"))


def test_password_of_8_characters_is_accepted():
    assert UserRegisterRequest(**registration(password="12345678")).password == "12345678"


@pytest.mark.parametrize("phone", ["091234567", "12345", "+963 91 234"])
def test_phone_with_fewer_than_10_digits_is_rejected(phone):
    with pytest.raises(PydanticValidationError):
        UserRegisterRequest(**registration(phone_number=phone))


@pytest.mark.parametrize("phone", ["0912345678", "+963 912 345 678", "09123456789"])
def test_phone_with_10_or_more_digits_is_accepted(phone):
    assert UserRegisterRequest(**registration(phone_number=phone)).phone_number == phone


def test_phone_with_letters_is_rejected():
    with pytest.raises(PydanticValidationError):
        UserRegisterRequest(**registration(phone_number="09123abc678"))


def test_phone_is_still_optional_in_the_api():
    assert UserRegisterRequest(**registration(phone_number=None)).phone_number is None


def test_profile_update_validates_phone_too():
    with pytest.raises(PydanticValidationError):
        UserProfileUpdateRequest(phone_number="123")
    assert UserProfileUpdateRequest(phone_number="0912345678").phone_number == "0912345678"


@pytest.mark.parametrize("code", ["12345", "1234567", "abcdef"])
def test_reset_code_must_be_six_digits(code):
    with pytest.raises(PydanticValidationError):
        ResetPasswordRequest(email="a@example.com", code=code, new_password="Secret123!")


# ------------------------------------------------------------------ service

@pytest.fixture
def db():
    return MagicMock(name="Session")


def active_user(id=1):
    return SimpleNamespace(id=id, email="a@example.com", is_active=True, hashed_password="old", profile=None)


def token_for(user, code, *, minutes_left=10, attempts=0):
    return PasswordResetToken(
        user_id=user.id,
        code_hash=svc._hash_code(user.id, code),
        expires_at=datetime.now(timezone.utc) + timedelta(minutes=minutes_left),
        attempts=attempts,
    )


def test_request_for_unknown_email_returns_none(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)
    assert svc.request_reset_code(db, "nobody@example.com") is None
    db.add.assert_not_called()


def test_request_for_deactivated_account_returns_none(db, monkeypatch):
    user = active_user()
    user.is_active = False
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    assert svc.request_reset_code(db, user.email) is None


def test_request_creates_hashed_six_digit_code(db, monkeypatch):
    user = active_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    db.execute.return_value.scalar_one_or_none.return_value = None  # no previous code

    result = svc.request_reset_code(db, user.email)

    assert result is not None
    returned_user, code = result
    assert returned_user is user
    assert len(code) == 6 and code.isdigit()
    stored = db.add.call_args.args[0]
    assert stored.code_hash == svc._hash_code(user.id, code)
    assert stored.code_hash != code  # never stored in clear text
    db.commit.assert_called_once()


def test_request_is_throttled(db, monkeypatch):
    user = active_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    recent = token_for(user, "123456")
    recent.created_at = datetime.now(timezone.utc) - timedelta(seconds=5)
    db.execute.return_value.scalar_one_or_none.return_value = recent

    assert svc.request_reset_code(db, user.email) is None
    db.add.assert_not_called()


def test_reset_with_correct_code_changes_password(db, monkeypatch):
    user = active_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    db.execute.return_value.scalar_one_or_none.return_value = token_for(user, "654321")
    monkeypatch.setattr(svc, "hash_password", lambda plain: f"hashed:{plain}")

    svc.reset_password(db, user.email, "654321", "NewSecret123")

    assert user.hashed_password == "hashed:NewSecret123"
    db.commit.assert_called()


def test_reset_with_wrong_code_counts_an_attempt(db, monkeypatch):
    user = active_user()
    token = token_for(user, "654321")
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    db.execute.return_value.scalar_one_or_none.return_value = token

    with pytest.raises(ValidationError, match="غير صحيح"):
        svc.reset_password(db, user.email, "000000", "NewSecret123")

    assert token.attempts == 1
    assert user.hashed_password == "old"


def test_reset_with_expired_code_is_rejected(db, monkeypatch):
    user = active_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    db.execute.return_value.scalar_one_or_none.return_value = token_for(user, "654321", minutes_left=-1)

    with pytest.raises(ValidationError, match="منتهي"):
        svc.reset_password(db, user.email, "654321", "NewSecret123")
    assert user.hashed_password == "old"


def test_reset_after_too_many_attempts_is_rejected_even_with_right_code(db, monkeypatch):
    user = active_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    db.execute.return_value.scalar_one_or_none.return_value = token_for(user, "654321", attempts=99)

    with pytest.raises(ValidationError, match="المحاولات"):
        svc.reset_password(db, user.email, "654321", "NewSecret123")
    assert user.hashed_password == "old"


def test_reset_for_unknown_email_gives_generic_error(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)
    with pytest.raises(ValidationError, match="غير صحيح"):
        svc.reset_password(db, "x@example.com", "123456", "NewSecret123")


# ------------------------------------------------------------------ routes

@pytest.fixture
def client():
    app.dependency_overrides[get_db] = lambda: MagicMock(name="Session")
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def test_forgot_password_sends_email_for_known_account(client, monkeypatch):
    sent = []
    user = SimpleNamespace(email="a@example.com", profile=SimpleNamespace(full_name="سامر"))
    monkeypatch.setattr(svc, "request_reset_code", lambda db, email: (user, "123456"))
    monkeypatch.setattr(
        "app.routers.auth.send_password_reset_email",
        lambda *args: sent.append(args),
    )

    response = client.post("/api/v1/auth/forgot-password", json={"email": "a@example.com"})

    assert response.status_code == 200
    assert sent and sent[0][0] == "a@example.com" and sent[0][2] == "123456"


def test_forgot_password_answers_identically_for_unknown_account(client, monkeypatch):
    sent = []
    monkeypatch.setattr(svc, "request_reset_code", lambda db, email: None)
    monkeypatch.setattr("app.routers.auth.send_password_reset_email", lambda *a: sent.append(a))

    response = client.post("/api/v1/auth/forgot-password", json={"email": "nobody@example.com"})

    assert response.status_code == 200
    assert "message" in response.json()
    assert sent == []


def test_forgot_password_rejects_malformed_email(client):
    response = client.post("/api/v1/auth/forgot-password", json={"email": "not-an-email"})
    assert response.status_code == 422


def test_reset_password_route_success(client, monkeypatch):
    calls = []
    monkeypatch.setattr(svc, "reset_password", lambda db, *args: calls.append(args))
    response = client.post(
        "/api/v1/auth/reset-password",
        json={"email": "a@example.com", "code": "123456", "new_password": "NewSecret123"},
    )
    assert response.status_code == 200
    assert calls == [("a@example.com", "123456", "NewSecret123")]


def test_reset_password_route_maps_bad_code_to_422(client, monkeypatch):
    def bad(db, *args):
        raise ValidationError("رمز التحقق غير صحيح أو منتهي الصلاحية")

    monkeypatch.setattr(svc, "reset_password", bad)
    response = client.post(
        "/api/v1/auth/reset-password",
        json={"email": "a@example.com", "code": "123456", "new_password": "NewSecret123"},
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "رمز التحقق غير صحيح أو منتهي الصلاحية"


def test_reset_password_route_rejects_short_password_in_arabic(client):
    response = client.post(
        "/api/v1/auth/reset-password",
        json={"email": "a@example.com", "code": "123456", "new_password": "short"},
    )
    assert response.status_code == 422
    assert "8" in response.json()["detail"][0]["msg"]


def test_register_validation_errors_are_arabic(client):
    response = client.post(
        "/api/v1/auth/register",
        json=registration(phone_number="123"),
    )
    assert response.status_code == 422
    assert response.json()["detail"][0]["msg"] == "رقم الجوال يجب أن يتكون من 10 أرقام على الأقل"
