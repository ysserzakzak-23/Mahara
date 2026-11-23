"""
Integration tests against a REAL PostgreSQL database.

These cover what the unit/API tests (mocks / SQLite) cannot prove:
  * the EXCLUDE USING gist appointment-overlap constraint,
  * the Haversine / bounding-box / COALESCE geo search executed in SQL,
  * the Alembic migration chain (upgrade, downgrade, data migrations, drift).

How to run
----------
    docker compose -f docker-compose.test.yml up -d
    export TEST_DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5433/service_marketplace_test
    pytest tests/integration_db -v

Without TEST_DATABASE_URL every test here is SKIPPED (so the rest of your
suite is unaffected). The database name MUST end with `_test`: the fixtures
DROP and recreate the `public` schema, and we refuse to touch anything else.
"""
import os
from dataclasses import dataclass

import pytest

TEST_DB_URL = os.environ.get("TEST_DATABASE_URL")

if TEST_DB_URL:
    # Must be set before `app.core.config` is first imported anywhere.
    os.environ.setdefault("DATABASE_URL", TEST_DB_URL)
    os.environ.setdefault("JWT_SECRET_KEY", "integration-test-secret")
    os.environ.setdefault("FCM_ENABLED", "false")

from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.engine import make_url  # noqa: E402

import app.models  # noqa: E402,F401
# app/models/__init__.py does not import the exchange models, but User has
# relationships pointing at them — without this, mapper configuration fails.
import app.models.exchange  # noqa: E402,F401
from app.core.config import settings  # noqa: E402
from app.models import Service, User  # noqa: E402

from .helpers import (  # noqa: E402
    current_revision,
    head_revision,
    make_category,
    make_service,
    make_user,
    new_session,
    reset_schema,
    truncate_all,
    upgrade,
)


@pytest.fixture(scope="session")
def test_db_url() -> str:
    if not TEST_DB_URL:
        pytest.skip("TEST_DATABASE_URL is not set — skipping real-PostgreSQL tests")
    database = make_url(TEST_DB_URL).database or ""
    if not database.endswith("_test"):
        pytest.fail(
            f"Refusing to run: TEST_DATABASE_URL database is {database!r}. "
            "It must end with '_test' because these tests DROP SCHEMA public."
        )
    return TEST_DB_URL


@pytest.fixture(scope="session", autouse=True)
def _point_app_at_test_db(test_db_url):
    """alembic/env.py reads the URL from settings.DATABASE_URL — aim it at the test DB."""
    original = settings.DATABASE_URL
    settings.DATABASE_URL = test_db_url
    yield
    settings.DATABASE_URL = original


@pytest.fixture(scope="session")
def engine(test_db_url):
    eng = create_engine(test_db_url, pool_pre_ping=True)
    yield eng
    eng.dispose()


@pytest.fixture
def db_engine(engine):
    """
    A database that is at the migration HEAD (built by running the real
    Alembic migrations, NOT Base.metadata.create_all — so the exclusion
    constraint exists) and has empty tables.
    """
    if current_revision(engine) != head_revision():
        reset_schema(engine)
        upgrade("head")
    truncate_all(engine)
    return engine


@pytest.fixture
def session(db_engine):
    s = new_session(db_engine)
    yield s
    s.rollback()
    s.close()


@pytest.fixture
def blank_db(engine):
    """An empty schema with no tables at all, for migration tests."""
    reset_schema(engine)
    return engine


@dataclass
class World:
    session: object
    provider: User
    other_provider: User
    customer: User
    other_customer: User
    service: Service          # provider's first listing
    second_service: Service   # SAME provider, different listing
    other_service: Service    # other_provider's listing


@pytest.fixture
def world(session) -> World:
    category = make_category(session)
    provider = make_user(session, is_provider=True)
    other_provider = make_user(session, is_provider=True)
    return World(
        session=session,
        provider=provider,
        other_provider=other_provider,
        customer=make_user(session),
        other_customer=make_user(session),
        service=make_service(session, provider, category),
        second_service=make_service(session, provider, category),
        other_service=make_service(session, other_provider, category),
    )
