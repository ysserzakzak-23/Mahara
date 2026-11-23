"""
Shared helpers for the real-PostgreSQL integration tests: Alembic runners,
schema reset, and small ORM factories.
"""
import itertools
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import inspect, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import (
    Appointment,
    AppointmentStatus,
    Service,
    ServiceCategory,
    ServiceStatus,
    User,
    UserProfile,
)

BACKEND_DIR = Path(__file__).resolve().parents[2]

# Postgres SQLSTATE codes
EXCLUSION_VIOLATION = "23P01"
CHECK_VIOLATION = "23514"
UNIQUE_VIOLATION = "23505"


# --------------------------------------------------------------------------
# Alembic
# --------------------------------------------------------------------------
def alembic_config() -> Config:
    """
    Built by hand (no alembic.ini) on purpose: alembic/env.py calls
    logging.config.fileConfig() whenever a config *file* is attached, which
    would silence the loggers of every other test in the session. The DB URL
    is taken by env.py from app.core.config.settings, which the `conftest`
    autouse fixture points at TEST_DATABASE_URL.
    """
    cfg = Config()
    cfg.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    return cfg


def upgrade(revision: str = "head") -> None:
    command.upgrade(alembic_config(), revision)


def downgrade(revision: str) -> None:
    command.downgrade(alembic_config(), revision)


def head_revision() -> str:
    return ScriptDirectory.from_config(alembic_config()).get_current_head()


def current_revision(engine) -> str | None:
    if not inspect(engine).has_table("alembic_version"):
        return None
    with engine.connect() as conn:
        return conn.execute(text("SELECT version_num FROM alembic_version")).scalar()


def reset_schema(engine) -> None:
    """Wipes EVERYTHING (tables, extensions, alembic_version) in `public`."""
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
        conn.execute(text("GRANT ALL ON SCHEMA public TO PUBLIC"))


def truncate_all(engine) -> None:
    with engine.begin() as conn:
        tables = [
            row[0]
            for row in conn.execute(
                text(
                    "SELECT tablename FROM pg_tables "
                    "WHERE schemaname = 'public' AND tablename <> 'alembic_version'"
                )
            )
        ]
        if tables:
            quoted = ", ".join(f'"{t}"' for t in tables)
            conn.execute(text(f"TRUNCATE {quoted} RESTART IDENTITY CASCADE"))


def new_session(engine) -> Session:
    # Same settings as app.core.database.SessionLocal
    return Session(bind=engine, autoflush=False)


# --------------------------------------------------------------------------
# Expectations
# --------------------------------------------------------------------------
@contextmanager
def expect_db_error(session: Session, *, pgcode: str, constraint: str):
    """
    Asserts that the block is rejected BY POSTGRES with the given SQLSTATE
    and constraint name (not merely "some exception"), then rolls back.
    """
    with pytest.raises(IntegrityError) as exc:
        yield
    session.rollback()
    orig = exc.value.orig
    assert orig.pgcode == pgcode, f"expected SQLSTATE {pgcode}, got {orig.pgcode}: {orig}"
    assert orig.diag.constraint_name == constraint, (
        f"expected constraint {constraint!r}, got {orig.diag.constraint_name!r}"
    )


# --------------------------------------------------------------------------
# Time helpers
# --------------------------------------------------------------------------
def at(hour: int, minute: int = 0, *, day: int = 7, tz=timezone.utc) -> datetime:
    """2030-01-07 is a Monday (weekday() == 0)."""
    return datetime(2030, 1, day, hour, minute, tzinfo=tz)


# --------------------------------------------------------------------------
# Factories (each commits, so data is visible to other connections/threads)
# --------------------------------------------------------------------------
_counter = itertools.count(1)


def make_user(
    session: Session,
    *,
    is_provider: bool = False,
    with_profile: bool = True,
    lat: float | None = None,
    lon: float | None = None,
    city: str | None = None,
) -> User:
    n = next(_counter)
    user = User(email=f"user{n}@example.test", hashed_password="not-a-real-hash", is_provider=is_provider)
    if with_profile:
        user.profile = UserProfile(full_name=f"User {n}", latitude=lat, longitude=lon, city=city)
    session.add(user)
    session.commit()
    return user


def make_category(session: Session, name: str | None = None) -> ServiceCategory:
    category = ServiceCategory(name=name or f"Category {next(_counter)}")
    session.add(category)
    session.commit()
    return category


def make_service(
    session: Session,
    provider: User,
    category: ServiceCategory,
    *,
    lat: float | None = None,
    lon: float | None = None,
    status: ServiceStatus = ServiceStatus.ACTIVE,
    title: str | None = None,
) -> Service:
    service = Service(
        provider_id=provider.id,
        category_id=category.id,
        title=title or f"Service {next(_counter)}",
        description="integration test service",
        price=10,
        latitude=lat,
        longitude=lon,
        status=status,
    )
    session.add(service)
    session.commit()
    return service


def book(
    session: Session,
    customer: User,
    service: Service,
    start: datetime,
    end: datetime,
    status: AppointmentStatus = AppointmentStatus.PENDING,
) -> Appointment:
    """Inserts straight through the ORM — NO application-level checks."""
    appointment = Appointment(
        customer_id=customer.id,
        provider_id=service.provider_id,
        service_id=service.id,
        start_time=start,
        end_time=end,
        status=status,
    )
    session.add(appointment)
    session.commit()
    return appointment
