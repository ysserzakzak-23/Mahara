"""add PENDING/REJECTED appointment states, normalize enum columns, exchange tables

Three things bundled in one migration since they're all part of the same
change set:

1. Normalizes services.status, appointments.status, barter_matches.match_type,
   and notifications.type to lowercase, matching the same
   values_callable fix already applied to users.role (see
   c3d4e5f6a7b8_normalize_user_role_lowercase.py for the full rationale —
   SQLAlchemy's Enum type defaults to persisting the member NAME, not
   `.value`, which is surprising for anything touching the DB directly).

2. Appointments now require explicit provider approval: adds PENDING and
   REJECTED as valid appointment_status values (no DB-level change needed
   since it's a plain VARCHAR, native_enum=False) and updates the
   exclusion constraint to also exclude REJECTED rows (a rejected
   appointment must free up its time slot, same as a cancelled one).

3. Creates the exchange_requests and exchange_proposals tables for the
   explicit request/propose/approve barter workflow.

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-08-08

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "d4e5f6a7b8c9"
down_revision: Union[str, None] = "c3d4e5f6a7b8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # --- 1. Normalize enum-like columns to lowercase ---
    op.execute("UPDATE services SET status = LOWER(status) WHERE status != LOWER(status)")
    op.execute("UPDATE appointments SET status = LOWER(status) WHERE status != LOWER(status)")
    op.execute(
        "UPDATE barter_matches SET match_type = LOWER(match_type) WHERE match_type != LOWER(match_type)"
    )
    op.execute("UPDATE notifications SET type = LOWER(type) WHERE type != LOWER(type)")

    # --- 2. Appointments: PENDING/REJECTED + exclusion constraint update ---
    # No column-level change needed (plain VARCHAR), but any appointment
    # that was auto-confirmed under the old flow stays CONFIRMED — only
    # NEW appointments default to PENDING going forward (see
    # app/models/appointment.py).
    op.execute("ALTER TABLE appointments DROP CONSTRAINT IF EXISTS ex_appointment_no_overlap")
    op.execute(
        """
        ALTER TABLE appointments
        ADD CONSTRAINT ex_appointment_no_overlap
        EXCLUDE USING gist (
            provider_id WITH =,
            tstzrange(start_time, end_time, '[)') WITH &&
        )
        WHERE (status NOT IN ('cancelled', 'rejected'))
        """
    )

    # --- 3. Exchange request/proposal tables ---
    op.create_table(
        "exchange_requests",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column(
            "offered_service_id",
            sa.Integer(),
            sa.ForeignKey("services.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "offered_category_id",
            sa.Integer(),
            sa.ForeignKey("service_categories.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "wanted_category_id",
            sa.Integer(),
            sa.ForeignKey("service_categories.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("status", sa.String(length=20), nullable=False, server_default="open"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_exchange_requests_user_id", "exchange_requests", ["user_id"])
    op.create_index("ix_exchange_requests_offered_service_id", "exchange_requests", ["offered_service_id"])
    op.create_index("ix_exchange_requests_offered_category_id", "exchange_requests", ["offered_category_id"])
    op.create_index("ix_exchange_requests_wanted_category_id", "exchange_requests", ["wanted_category_id"])
    op.create_index("ix_exchange_requests_status", "exchange_requests", ["status"])

    op.create_table(
        "exchange_proposals",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "request_id",
            sa.Integer(),
            sa.ForeignKey("exchange_requests.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("proposer_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column(
            "proposed_service_id",
            sa.Integer(),
            sa.ForeignKey("services.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("message", sa.String(length=1000), nullable=True),
        sa.Column("status", sa.String(length=20), nullable=False, server_default="pending"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_exchange_proposals_request_id", "exchange_proposals", ["request_id"])
    op.create_index("ix_exchange_proposals_proposer_id", "exchange_proposals", ["proposer_id"])
    op.create_index("ix_exchange_proposals_proposed_service_id", "exchange_proposals", ["proposed_service_id"])
    op.create_index("ix_exchange_proposals_status", "exchange_proposals", ["status"])

    # --- 4. is_remote flag on services ---
    op.add_column("services", sa.Column("is_remote", sa.Boolean(), nullable=False, server_default=sa.false()))


def downgrade() -> None:
    op.drop_column("services", "is_remote")

    op.drop_table("exchange_proposals")
    op.drop_table("exchange_requests")

    op.execute("ALTER TABLE appointments DROP CONSTRAINT IF EXISTS ex_appointment_no_overlap")
    op.execute(
        """
        ALTER TABLE appointments
        ADD CONSTRAINT ex_appointment_no_overlap
        EXCLUDE USING gist (
            provider_id WITH =,
            tstzrange(start_time, end_time, '[)') WITH &&
        )
        WHERE (status != 'cancelled')
        """
    )
