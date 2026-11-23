"""
Shared test setup.

IMPORTANT: the environment variables below are set BEFORE any `app.*` module
is imported. pydantic-settings gives real environment variables priority over
the project's `.env` file, so these tests can never accidentally connect to
your real PostgreSQL database or use your real JWT secret / Firebase.

None of these tests need a running database: they cover pure algorithms,
security primitives, schemas, error handling, auth dependencies, and the
service layer (with the DB session mocked).
"""
import os

os.environ["DATABASE_URL"] = "sqlite://"  # never opened by these tests
os.environ["JWT_SECRET_KEY"] = "test-secret-key-not-for-production"
os.environ["JWT_ALGORITHM"] = "HS256"
os.environ["ACCESS_TOKEN_EXPIRE_MINUTES"] = "30"
os.environ["REFRESH_TOKEN_EXPIRE_DAYS"] = "7"
os.environ["ENVIRONMENT"] = "test"
os.environ["DEBUG"] = "false"
os.environ["FCM_ENABLED"] = "false"
os.environ["SEMANTIC_SEARCH_ENABLED"] = "false"

from datetime import datetime, time  # noqa: E402
from types import SimpleNamespace  # noqa: E402
from unittest.mock import MagicMock  # noqa: E402

import pytest  # noqa: E402


@pytest.fixture
def db():
    """A fake SQLAlchemy Session. Configure `.execute(...)` per test."""
    return MagicMock(name="Session")


@pytest.fixture
def make_user():
    from app.models.user import UserRole

    def _make(id=1, role=UserRole.USER, is_active=True, full_name="Test User"):
        return SimpleNamespace(
            id=id,
            role=role,
            is_active=is_active,
            profile=SimpleNamespace(full_name=full_name),
        )

    return _make


@pytest.fixture
def monday():
    """Helper: build a datetime on a known Monday (2026-10-05)."""

    def _at(hour, minute=0):
        return datetime(2026, 10, 5, hour, minute)

    return _at


@pytest.fixture
def notifications(monkeypatch):
    """Replaces notification_service.notify_user with a recorder.

    Every service module calls `notification_service.notify_user(db, **kwargs)`
    through the shared module object, so patching it once covers them all.
    """
    from app.services import notification_service

    sent = []
    monkeypatch.setattr(
        notification_service, "notify_user", lambda db, **kwargs: sent.append(kwargs)
    )
    return sent

