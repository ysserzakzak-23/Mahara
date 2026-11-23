from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from jose import jwt

from app.core.config import settings
from app.core.database import get_db
from app.core.dependencies import (
    get_current_user,
    get_current_user_optional,
    require_admin,
)
from app.core.error_handlers import register_error_handlers
from app.core.exceptions import (
    AppError,
    ConflictError,
    InvalidCredentialsError,
    NotFoundError,
    PermissionDeniedError,
    ServiceUnavailableError,
    UnauthorizedError,
    ValidationError,
)
from app.core.security import (
    TokenType,
    _create_token,
    create_access_token,
    create_refresh_token,
)
from app.models.user import UserRole


# =============================================================== error handlers

def _client():
    app = FastAPI()
    register_error_handlers(app)

    @app.get("/raise/{name}")
    def raise_it(name: str):
        errors = {
            "not_found": NotFoundError("nope"),
            "conflict": ConflictError("clash"),
            "forbidden": PermissionDeniedError("no"),
            "bad_creds": InvalidCredentialsError(),
            "unauth": UnauthorizedError(),
            "invalid": ValidationError("bad data"),
            "unavailable": ServiceUnavailableError(),
            "generic": AppError("generic failure"),
        }
        if name == "boom":
            raise RuntimeError("secret internal detail: db password=hunter2")
        raise errors[name]

    return TestClient(app, raise_server_exceptions=False)


@pytest.mark.parametrize(
    "name, status, error_type",
    [
        ("not_found", 404, "NotFoundError"),
        ("conflict", 409, "ConflictError"),
        ("forbidden", 403, "PermissionDeniedError"),
        ("bad_creds", 401, "InvalidCredentialsError"),
        ("unauth", 401, "UnauthorizedError"),
        ("invalid", 422, "ValidationError"),
        ("unavailable", 503, "ServiceUnavailableError"),
        ("generic", 400, "AppError"),
    ],
)
def test_domain_errors_map_to_http_status(name, status, error_type):
    response = _client().get(f"/raise/{name}")
    assert response.status_code == status
    assert response.json()["error_type"] == error_type


def test_error_message_is_returned_as_detail():
    assert _client().get("/raise/not_found").json()["detail"] == "nope"


def test_unexpected_exception_returns_500_without_leaking_internals():
    response = _client().get("/raise/boom")
    assert response.status_code == 500
    body = response.text
    assert "hunter2" not in body and "RuntimeError" not in body
    assert response.json()["error_type"] == "InternalServerError"


def test_default_messages():
    assert str(InvalidCredentialsError()) == "البريد الإلكتروني أو كلمة المرور غير صحيحة"
    assert NotFoundError().message == "العنصر المطلوب غير موجود"



def test_a_subclass_of_a_mapped_error_keeps_its_parents_status():
    """
    Status resolution walks the MRO, so a subclass of a registered error
    answers with its parent's status instead of the generic fallback.
    An exact-type lookup turned this into a 400.
    """

    class _ThingNotFound(NotFoundError):
        """Declared here on purpose: no production class is added for this."""

    app = FastAPI()
    register_error_handlers(app)

    @app.get("/subclass")
    def raise_subclass():
        raise _ThingNotFound("nested thing missing")

    response = TestClient(app, raise_server_exceptions=False).get("/subclass")

    assert response.status_code == 404                      # not the 400 fallback
    # The body and its fields are untouched by the change.
    assert response.json()["detail"] == "nested thing missing"
    assert response.json()["error_type"] == "_ThingNotFound"

# ============================================================== auth dependencies

def _db_returning(user):
    db = MagicMock()
    db.get.return_value = user
    return db


def _active_user(id=1, role=UserRole.USER):
    return SimpleNamespace(id=id, role=role, is_active=True)


def _token_without_sub():
    return jwt.encode(
        {"type": "access", "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )


def test_valid_access_token_returns_user():
    user = _active_user(7)
    assert get_current_user(create_access_token(7), _db_returning(user)) is user


@pytest.mark.parametrize(
    "token_factory, message_part",
    [
        (lambda: None, "مفقود"),
        (lambda: "garbage", "غير صالح أو منتهي"),
        (lambda: _create_token("1", TokenType.ACCESS, timedelta(seconds=-1)), "غير صالح أو منتهي"),
        (lambda: create_refresh_token(1), "نوع الرمز غير صحيح"),
        (_token_without_sub, "رمز الدخول غير صالح"),
    ],
)
def test_get_current_user_rejects_bad_tokens(token_factory, message_part):
    with pytest.raises(UnauthorizedError) as exc:
        get_current_user(token_factory(), _db_returning(_active_user()))
    assert message_part in exc.value.message


def test_get_current_user_rejects_deleted_user():
    with pytest.raises(UnauthorizedError, match="لم يعد موجوداً"):
        get_current_user(create_access_token(1), _db_returning(None))


def test_get_current_user_rejects_deactivated_user():
    user = SimpleNamespace(id=1, role=UserRole.USER, is_active=False)
    with pytest.raises(UnauthorizedError, match="تم تعطيل"):
        get_current_user(create_access_token(1), _db_returning(user))


def test_optional_user_returns_user_when_token_is_valid():
    user = _active_user(3)
    assert get_current_user_optional(create_access_token(3), _db_returning(user)) is user


@pytest.mark.parametrize(
    "token_factory",
    [
        lambda: None,
        lambda: "garbage",
        lambda: create_refresh_token(1),
        _token_without_sub,
    ],
)
def test_optional_user_never_raises_for_bad_tokens(token_factory):
    assert get_current_user_optional(token_factory(), _db_returning(_active_user())) is None


def test_optional_user_returns_none_for_missing_or_inactive_user():
    assert get_current_user_optional(create_access_token(1), _db_returning(None)) is None
    inactive = SimpleNamespace(id=1, role=UserRole.USER, is_active=False)
    assert get_current_user_optional(create_access_token(1), _db_returning(inactive)) is None


def test_require_admin_allows_admin():
    admin = _active_user(role=UserRole.ADMIN)
    assert require_admin(admin) is admin


def test_require_admin_blocks_regular_user():
    with pytest.raises(PermissionDeniedError):
        require_admin(_active_user(role=UserRole.USER))


def _token_with_subject(subject):
    """A correctly signed, unexpired access token carrying `subject` as sub."""
    return _create_token(subject, TokenType.ACCESS, timedelta(hours=1))


def _required_auth_client(db):
    """A route behind get_current_user, with the project's error handlers."""
    app = FastAPI()
    register_error_handlers(app)
    app.dependency_overrides[get_db] = lambda: db

    @app.get("/who")
    def who(user=Depends(get_current_user)):
        return {"id": user.id}

    return TestClient(app, raise_server_exceptions=False)


def test_get_current_user_rejects_a_non_numeric_subject():
    """
    A properly signed token whose `sub` is not a user id. The signature and
    the expiry are valid, so the subject is the only thing wrong: it used
    to reach int() and escape as a ValueError, surfacing as a 500.
    """
    token = _token_with_subject("not-a-number")

    with pytest.raises(UnauthorizedError) as exc:
        get_current_user(token, _db_returning(_active_user()))
    assert "رمز الدخول غير صالح" in exc.value.message

    # And over HTTP it is the usual 401, not a 500.
    response = _required_auth_client(_db_returning(_active_user())).get(
        "/who", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 401
    assert response.json()["error_type"] == "UnauthorizedError"


def test_optional_user_returns_none_for_a_non_numeric_subject():
    """
    The same token on the optional path: still None, never an exception —
    a public route must not become a 500 (or a gated one) because of it.
    """
    token = _token_with_subject("not-a-number")

    assert get_current_user_optional(token, _db_returning(_active_user())) is None
