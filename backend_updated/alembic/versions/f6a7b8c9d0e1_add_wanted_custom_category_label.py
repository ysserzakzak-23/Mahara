"""add wanted_custom_category_label to exchange_requests

Revision ID: f6a7b8c9d0e1
Revises: e5f6a7b8c9d0
Create Date: 2026-09-25

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "f6a7b8c9d0e1"
down_revision: Union[str, None] = "e5f6a7b8c9d0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "exchange_requests",
        sa.Column("wanted_custom_category_label", sa.String(length=100), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("exchange_requests", "wanted_custom_category_label")