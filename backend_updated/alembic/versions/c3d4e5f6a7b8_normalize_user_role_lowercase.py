"""normalize users.role to lowercase values

Fixes existing rows written before the User.role column started storing
the enum's lowercase `.value` ("user"/"admin") instead of the uppercase
member name ("USER"/"ADMIN"). Without this, any account created/updated
before the model fix would fail to load with a LookupError, since the
application now expects lowercase.

Revision ID: c3d4e5f6a7b8
Revises: b7c8d9e0f1a2
Create Date: 2026-07-19

"""
from typing import Sequence, Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c3d4e5f6a7b8"
down_revision: Union[str, None] = "b7c8d9e0f1a2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # role is a plain VARCHAR (native_enum=False), so this is a safe,
    # ordinary string update — not touching any real Postgres enum type.
    op.execute("UPDATE users SET role = LOWER(role) WHERE role != LOWER(role)")


def downgrade() -> None:
    op.execute("UPDATE users SET role = UPPER(role) WHERE role != UPPER(role)")
