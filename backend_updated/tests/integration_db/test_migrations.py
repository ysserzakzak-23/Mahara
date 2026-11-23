"""
Alembic migration chain, run against a real PostgreSQL database.
"""
import os
import subprocess
import sys
from datetime import datetime, timezone
from pprint import pformat

import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import inspect, text
from sqlalchemy.exc import IntegrityError

from app.core.database import Base

from .helpers import (
    BACKEND_DIR,
    EXCLUSION_VIOLATION,
    alembic_config,
    current_revision,
    downgrade,
    head_revision,
    reset_schema,
    upgrade,
)

R_BASE = "959c4edd5b19"       # create all tables
R_EXCLUSION = "a1b2c3d4e5f6"  # appointment exclusion constraint
R_CITY = "b7c8d9e0f1a2"       # city + cover image
R_ROLE = "c3d4e5f6a7b8"       # lowercase users.role
R_PENDING = "d4e5f6a7b8c9"    # pending/rejected, lowercase enums, exchange tables, is_remote
R_OTHER = "e5f6a7b8c9d0"      # "Others" category
R_WANTED = "f6a7b8c9d0e1"     # exchange_requests.wanted_custom_category_label


def tables(engine) -> set[str]:
    return set(inspect(engine).get_table_names())


def columns(engine, table: str) -> dict:
    return {c["name"]: c for c in inspect(engine).get_columns(table)}


def scalar(engine, sql: str, **params):
    with engine.connect() as conn:
        return conn.execute(text(sql), params).scalar()


def column_values(engine, sql: str) -> list:
    with engine.connect() as conn:
        return [row[0] for row in conn.execute(text(sql))]


# ============================================================ structure of the chain
def test_history_is_linear_with_exactly_one_head():
    script = ScriptDirectory.from_config(alembic_config())

    assert len(script.get_heads()) == 1, f"multiple heads (branching): {script.get_heads()}"
    for rev in script.walk_revisions():
        assert not isinstance(rev.down_revision, tuple), f"{rev.revision} is a merge revision"


def test_upgrade_from_an_empty_database_to_head(blank_db):
    upgrade("head")

    assert current_revision(blank_db) == head_revision()
    expected = set(Base.metadata.tables)
    assert expected <= tables(blank_db), f"missing tables: {expected - tables(blank_db)}"


def test_upgrade_head_twice_is_a_noop(blank_db):
    upgrade("head")
    upgrade("head")

    assert current_revision(blank_db) == head_revision()


def test_every_step_downgrades_and_upgrades_cleanly(blank_db):
    script = ScriptDirectory.from_config(alembic_config())
    revisions = [r.revision for r in reversed(list(script.walk_revisions()))]  # base -> head

    upgrade("head")
    for parent in reversed(revisions[:-1]):
        downgrade("-1")
        assert current_revision(blank_db) == parent

    downgrade("-1")
    assert current_revision(blank_db) is None
    assert tables(blank_db) <= {"alembic_version"}, f"downgrade left tables behind: {tables(blank_db)}"

    for revision in revisions:
        upgrade("+1")
        assert current_revision(blank_db) == revision


# ============================================================ models vs migrations
def test_models_match_the_migrated_schema(blank_db):
    """Same check `alembic revision --autogenerate` does: it must find nothing to change."""
    upgrade("head")

    with blank_db.connect() as conn:
        context = MigrationContext.configure(conn, opts={"compare_type": True})
        diff = compare_metadata(context, Base.metadata)

    assert diff == [], "models and migrations have drifted apart:\n" + pformat(diff)


def test_alembic_env_registers_every_table(blank_db):
    """
    alembic/env.py only does `import app.models`. A model missing from
    app/models/__init__.py makes --autogenerate propose DROPPING its table.
    Checked in a fresh interpreter so other imports can't hide the problem.
    """
    upgrade("head")
    code = (
        "import app.models\n"
        "from app.core.database import Base\n"
        "print('\\n'.join(sorted(Base.metadata.tables)))\n"
    )
    out = subprocess.run(
        [sys.executable, "-c", code],
        cwd=BACKEND_DIR,
        env={**os.environ, "DATABASE_URL": str(blank_db.url.render_as_string(hide_password=False))},
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()

    unregistered = tables(blank_db) - set(out) - {"alembic_version"}
    assert not unregistered, (
        f"tables in the DB that `import app.models` does not register: {sorted(unregistered)}. "
        "Add their models to app/models/__init__.py."
    )


# ============================================================ catalog checks at head
def test_exclusion_constraint_definition_at_head(blank_db):
    upgrade("head")

    definition = scalar(
        blank_db,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
        "WHERE conname = 'ex_appointment_no_overlap' AND contype = 'x'",
    )
    assert definition is not None, "ex_appointment_no_overlap is missing"
    assert "gist" in definition.lower()
    assert "tstzrange" in definition
    assert "cancelled" in definition and "rejected" in definition
    assert "IS NOT NULL" in definition       # requests without a time never overlap anything
    assert scalar(blank_db, "SELECT count(*) FROM pg_extension WHERE extname = 'btree_gist'") == 1


def test_expected_named_constraints_exist_at_head(blank_db):
    upgrade("head")

    present = set(column_values(blank_db, "SELECT conname FROM pg_constraint"))
    expected = {
        "ex_appointment_no_overlap",
        "ck_appointment_end_after_start",
        "ck_availability_day_of_week_range",
        "ck_availability_end_after_start",
        "ck_review_rating_range",
        "uq_review_reviewer_service",
        "uq_barter_preference_user_offer_need",
        "uq_barter_participant_match_user",
    }
    assert expected <= present, f"missing constraints: {expected - present}"


# ============================================================ data migrations
def _insert_user(conn, email: str, role: str) -> int:
    return conn.execute(
        text(
            "INSERT INTO users (email, hashed_password, role, is_provider, is_active) "
            "VALUES (:email, 'h', :role, true, true) RETURNING id"
        ),
        {"email": email, "role": role},
    ).scalar_one()


def test_role_migration_lowercases_existing_users_and_downgrade_reverses_it(blank_db):
    upgrade(R_CITY)
    with blank_db.begin() as conn:
        _insert_user(conn, "a@x.test", "ADMIN")
        _insert_user(conn, "u@x.test", "USER")

    upgrade(R_ROLE)
    assert sorted(column_values(blank_db, "SELECT role FROM users")) == ["admin", "user"]

    downgrade(R_CITY)
    assert sorted(column_values(blank_db, "SELECT role FROM users")) == ["ADMIN", "USER"]


def test_city_and_cover_image_migration_keeps_existing_rows(blank_db):
    upgrade(R_EXCLUSION)
    with blank_db.begin() as conn:
        provider = _insert_user(conn, "p@x.test", "USER")
        category = conn.execute(
            text("INSERT INTO service_categories (name, is_active) VALUES ('Plumbing', true) RETURNING id")
        ).scalar_one()
        conn.execute(
            text("INSERT INTO user_profiles (user_id, full_name) VALUES (:u, 'Old Profile')"), {"u": provider}
        )
        conn.execute(
            text(
                "INSERT INTO services (provider_id, category_id, title, description, price, price_unit, status) "
                "VALUES (:p, :c, 'Old', 'd', 10, 'fixed', 'ACTIVE')"
            ),
            {"p": provider, "c": category},
        )

    upgrade(R_CITY)

    assert scalar(blank_db, "SELECT full_name FROM user_profiles") == "Old Profile"
    assert scalar(blank_db, "SELECT city FROM user_profiles") is None
    assert scalar(blank_db, "SELECT cover_image_url FROM services") is None
    assert "ix_user_profiles_city" in {i["name"] for i in inspect(blank_db).get_indexes("user_profiles")}


def _seed_legacy_booking_data(conn):
    """Data as it looked at revision c3d4 (UPPERCASE enum values)."""
    provider = _insert_user(conn, "p@x.test", "user")
    customer = _insert_user(conn, "c@x.test", "user")
    category = conn.execute(
        text("INSERT INTO service_categories (name, is_active) VALUES ('Plumbing', true) RETURNING id")
    ).scalar_one()
    service = conn.execute(
        text(
            "INSERT INTO services (provider_id, category_id, title, description, price, price_unit, status) "
            "VALUES (:p, :c, 'Fix', 'd', 10, 'fixed', 'ACTIVE') RETURNING id"
        ),
        {"p": provider, "c": category},
    ).scalar_one()
    conn.execute(
        text("INSERT INTO notifications (user_id, type, title, message, is_read) "
             "VALUES (:u, 'APPOINTMENT_BOOKED', 't', 'm', false)"),
        {"u": provider},
    )
    conn.execute(text("INSERT INTO barter_matches (match_type, cycle_length) VALUES ('DIRECT', 2)"))
    return provider, customer, service


def _insert_appointment(engine, ids, start_hour: int, end_hour: int, status: str) -> None:
    provider, customer, service = ids
    day = datetime(2030, 1, 7, tzinfo=timezone.utc)
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO appointments (customer_id, service_id, provider_id, start_time, end_time, status) "
                "VALUES (:c, :s, :p, :st, :en, :status)"
            ),
            {
                "c": customer, "s": service, "p": provider, "status": status,
                "st": day.replace(hour=start_hour), "en": day.replace(hour=end_hour),
            },
        )


def test_pending_migration_normalizes_enums_and_rebuilds_the_exclusion_constraint(blank_db):
    upgrade(R_ROLE)
    with blank_db.begin() as conn:
        ids = _seed_legacy_booking_data(conn)
    _insert_appointment(blank_db, ids, 10, 11, "CANCELLED")
    _insert_appointment(blank_db, ids, 14, 15, "CONFIRMED")

    # BEFORE: the legacy bug the migration exists to fix. 'CANCELLED' (upper-case)
    # != 'cancelled', so the old constraint still treats it as holding the slot.
    with pytest.raises(IntegrityError) as before:
        _insert_appointment(blank_db, ids, 10, 11, "CONFIRMED")
    assert before.value.orig.pgcode == EXCLUSION_VIOLATION

    upgrade(R_PENDING)

    # AFTER: every enum-like column is lowercase...
    assert sorted(column_values(blank_db, "SELECT status FROM appointments")) == ["cancelled", "confirmed"]
    assert column_values(blank_db, "SELECT status FROM services") == ["active"]
    assert column_values(blank_db, "SELECT type FROM notifications") == ["appointment_booked"]
    assert column_values(blank_db, "SELECT match_type FROM barter_matches") == ["direct"]

    # ...the formerly "cancelled" slot is genuinely free again...
    _insert_appointment(blank_db, ids, 10, 11, "pending")
    # ...a live (confirmed) booking still blocks...
    with pytest.raises(IntegrityError) as live:
        _insert_appointment(blank_db, ids, 14, 15, "pending")
    assert live.value.orig.pgcode == EXCLUSION_VIOLATION
    # ...and the new 'rejected' state frees its slot.
    _insert_appointment(blank_db, ids, 16, 17, "rejected")
    _insert_appointment(blank_db, ids, 16, 17, "pending")

    # New schema pieces, with defaults applied to pre-existing rows.
    assert {"exchange_requests", "exchange_proposals"} <= tables(blank_db)
    assert scalar(blank_db, "SELECT is_remote FROM services") is False


def test_other_category_migration_backfills_false_and_drops_the_default(blank_db):
    upgrade(R_PENDING)
    with blank_db.begin() as conn:
        conn.execute(text("INSERT INTO service_categories (name, is_active) VALUES ('Plumbing', true)"))

    upgrade(R_OTHER)

    assert scalar(blank_db, "SELECT is_other FROM service_categories") is False
    assert columns(blank_db, "service_categories")["is_other"]["default"] is None
    assert columns(blank_db, "services")["custom_category_label"]["nullable"] is True


def test_wanted_custom_category_label_column_is_added_and_removed(blank_db):
    upgrade(R_WANTED)
    column = columns(blank_db, "exchange_requests")["wanted_custom_category_label"]
    assert column["nullable"] is True

    downgrade(R_OTHER)
    assert "wanted_custom_category_label" not in columns(blank_db, "exchange_requests")
