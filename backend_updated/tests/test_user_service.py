from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from app.core.exceptions import ConflictError, InvalidCredentialsError, ValidationError
from app.core.security import decode_token, hash_password
from app.schemas.user import (
    UserLocationUpdateRequest,
    UserProfileUpdateRequest,
    UserRegisterRequest,
)
from app.services import user_service


def registration(**overrides):
    data = {
        "email": "ahmad@example.com",
        "password": "Secret123!",
        "full_name": "Ahmad Ali",
        "phone_number": "0912345678",
        "city": "دمشق",
    }
    data.update(overrides)
    return UserRegisterRequest(**data)


# --------------------------------------------------------------------- register

def test_register_creates_user_and_profile(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)

    user = user_service.register_user(db, registration())

    db.add.assert_called_once_with(user)
    db.commit.assert_called_once()
    assert user.email == "ahmad@example.com"
    assert user.hashed_password != "Secret123!"          # never stored in plain text
    assert user.profile.full_name == "Ahmad Ali"
    assert user.profile.city == "دمشق"
    assert user.profile.phone_number == "0912345678"


def test_register_rejects_duplicate_email(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: object())

    with pytest.raises(ConflictError):
        user_service.register_user(db, registration())
    db.add.assert_not_called()


def test_register_rejects_unknown_city(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)

    with pytest.raises(ValidationError):
        user_service.register_user(db, registration(city="Atlantis"))
    db.add.assert_not_called()
    db.commit.assert_not_called()


# ----------------------------------------------------------------- authenticate

def _stored_user(password="Secret123!", is_active=True):
    return SimpleNamespace(id=5, hashed_password=hash_password(password), is_active=is_active)


def test_authenticate_success(db, monkeypatch):
    user = _stored_user()
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: user)
    assert user_service.authenticate_user(db, "a@b.com", "Secret123!") is user


def test_authenticate_unknown_email(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)
    with pytest.raises(InvalidCredentialsError):
        user_service.authenticate_user(db, "a@b.com", "whatever")


def test_authenticate_wrong_password(db, monkeypatch):
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: _stored_user())
    with pytest.raises(InvalidCredentialsError):
        user_service.authenticate_user(db, "a@b.com", "wrong")


def test_authenticate_deactivated_account(db, monkeypatch):
    monkeypatch.setattr(
        user_service, "get_user_by_email", lambda db, email: _stored_user(is_active=False)
    )
    with pytest.raises(InvalidCredentialsError, match="تم تعطيل"):
        user_service.authenticate_user(db, "a@b.com", "Secret123!")


def test_unknown_email_and_wrong_password_give_the_same_message(db, monkeypatch):
    """Avoids leaking which emails are registered."""
    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: None)
    with pytest.raises(InvalidCredentialsError) as unknown:
        user_service.authenticate_user(db, "a@b.com", "x")

    monkeypatch.setattr(user_service, "get_user_by_email", lambda db, email: _stored_user())
    with pytest.raises(InvalidCredentialsError) as wrong:
        user_service.authenticate_user(db, "a@b.com", "x")

    assert unknown.value.message == wrong.value.message


def test_issue_tokens_returns_access_and_refresh_for_the_user():
    access, refresh = user_service.issue_tokens(SimpleNamespace(id=9))
    assert decode_token(access)["type"] == "access"
    assert decode_token(refresh)["type"] == "refresh"
    assert decode_token(access)["sub"] == decode_token(refresh)["sub"] == "9"


# ------------------------------------------------------------------- get by id

def test_get_user_by_id_raises_when_missing(db):
    from app.core.exceptions import NotFoundError

    db.get.return_value = None
    with pytest.raises(NotFoundError):
        user_service.get_user_by_id(db, 123)


# --------------------------------------------------------------------- profile

def _user_with_profile():
    return SimpleNamespace(
        is_provider=False,
        profile=SimpleNamespace(
            full_name="Old Name", bio="old bio", city="دمشق",
            latitude=None, longitude=None, address_label=None,
        ),
    )


def test_update_profile_changes_only_provided_fields(db):
    user = _user_with_profile()
    user_service.update_profile(db, user, UserProfileUpdateRequest(bio="new bio"))

    assert user.profile.bio == "new bio"
    assert user.profile.full_name == "Old Name"
    assert user.profile.city == "دمشق"
    db.commit.assert_called_once()


def test_update_profile_rejects_unknown_city(db):
    user = _user_with_profile()
    with pytest.raises(ValidationError):
        user_service.update_profile(db, user, UserProfileUpdateRequest(city="Atlantis"))
    assert user.profile.city == "دمشق"
    db.commit.assert_not_called()


def test_update_profile_accepts_valid_city(db):
    user = _user_with_profile()
    user_service.update_profile(db, user, UserProfileUpdateRequest(city="حلب"))
    assert user.profile.city == "حلب"


def test_update_location_sets_coordinates(db):
    user = _user_with_profile()
    user_service.update_location(
        db, user, UserLocationUpdateRequest(latitude=33.5, longitude=36.3, address_label="Home")
    )
    assert (user.profile.latitude, user.profile.longitude) == (33.5, 36.3)
    assert user.profile.address_label == "Home"


def test_update_location_keeps_existing_label_when_none_given(db):
    user = _user_with_profile()
    user.profile.address_label = "Office"
    user_service.update_location(db, user, UserLocationUpdateRequest(latitude=1, longitude=2))
    assert user.profile.address_label == "Office"


def test_set_provider_status(db):
    user = _user_with_profile()
    user_service.set_provider_status(db, user, True)
    assert user.is_provider is True
    db.commit.assert_called_once()
