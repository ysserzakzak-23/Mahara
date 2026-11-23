"""add other-category support

Adds the two columns behind the "Others" category feature: a provider
whose trade isn't one of the curated categories yet can file their
service under the admin-marked "Others" bucket and type in what they
actually do.

  - service_categories.is_other: marks (at most) one category as that
    catch-all bucket.
  - services.custom_category_label: the free-text trade name, required
    and only meaningful when the service's category has is_other=True.

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-09-18

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = "e5f6a7b8c9d0"
down_revision: Union[str, None] = "d4e5f6a7b8c9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "service_categories",
        sa.Column("is_other", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    # Drop the server_default once existing rows are backfilled — new
    # rows going forward supply it explicitly via the model/schema default,
    # same convention as the other Boolean columns in this codebase
    # (see is_active on the same model).
    op.alter_column("service_categories", "is_other", server_default=None)

    op.add_column(
        "services",
        sa.Column("custom_category_label", sa.String(length=100), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("services", "custom_category_label")
    op.drop_column("service_categories", "is_other")
