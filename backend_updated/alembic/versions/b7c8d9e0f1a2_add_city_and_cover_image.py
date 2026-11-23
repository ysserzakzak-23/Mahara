"""add city to user_profiles and cover_image_url to services

Adds the two new columns introduced for: (1) selecting/changing a city at
registration and from the profile screen, used to filter search/listing
results by city; (2) a single cover/thumbnail photo per service, distinct
from the existing per-service portfolio gallery.

Revision ID: b7c8d9e0f1a2
Revises: a1b2c3d4e5f6
Create Date: 2026-07-10

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "b7c8d9e0f1a2"
down_revision: Union[str, None] = "a1b2c3d4e5f6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("user_profiles", sa.Column("city", sa.String(length=100), nullable=True))
    op.create_index(op.f("ix_user_profiles_city"), "user_profiles", ["city"], unique=False)

    op.add_column("services", sa.Column("cover_image_url", sa.String(length=500), nullable=True))


def downgrade() -> None:
    op.drop_column("services", "cover_image_url")

    op.drop_index(op.f("ix_user_profiles_city"), table_name="user_profiles")
    op.drop_column("user_profiles", "city")
