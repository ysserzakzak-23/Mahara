"""allow appointments without a day/time (remote services with no working hours)

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-11-04

A booking request on a remote service whose provider has no working hours is
sent without a start/end time. Two things change:
  * start_time / end_time may be NULL;
  * the overlap exclusion constraint ignores rows without a time. Without
    that, tstzrange(NULL, NULL) is the unbounded range and such a row would
    "overlap" every other appointment of the provider.
"""
from typing import Sequence, Union

from alembic import op

revision: str = "b8c9d0e1f2a3"
down_revision: Union[str, None] = "a7b8c9d0e1f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TABLE appointments ALTER COLUMN start_time DROP NOT NULL")
    op.execute("ALTER TABLE appointments ALTER COLUMN end_time DROP NOT NULL")
    op.execute("ALTER TABLE appointments DROP CONSTRAINT IF EXISTS ex_appointment_no_overlap")
    op.execute(
        """
        ALTER TABLE appointments
        ADD CONSTRAINT ex_appointment_no_overlap
        EXCLUDE USING gist (
            provider_id WITH =,
            tstzrange(start_time, end_time, '[)') WITH &&
        )
        WHERE (status NOT IN ('cancelled', 'rejected') AND start_time IS NOT NULL AND end_time IS NOT NULL)
        """
    )


def downgrade() -> None:
    # Requests without a time cannot exist under the old schema.
    op.execute("DELETE FROM appointments WHERE start_time IS NULL OR end_time IS NULL")
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
    op.execute("ALTER TABLE appointments ALTER COLUMN start_time SET NOT NULL")
    op.execute("ALTER TABLE appointments ALTER COLUMN end_time SET NOT NULL")
