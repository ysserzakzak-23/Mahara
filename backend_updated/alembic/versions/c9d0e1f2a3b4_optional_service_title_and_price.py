"""make a service's title and price optional

Revision ID: c9d0e1f2a3b4
Revises: b8c9d0e1f2a3
Create Date: 2026-11-13

Two product changes to publishing a service:
  * the price is optional — a service published without one stores NULL
    (shown in the app as «السعر غير محدد»), never 0;
  * the separate "service name" is gone — a service is identified by its
    category (Service.display_title), so new services store NULL in
    `title`. Existing services keep the title they were published with.

Upgrade only relaxes NOT NULL: no existing row is changed.

Downgrade restores NOT NULL, which is impossible while rows without a
title/price exist. Rather than invent values (a fake "0" price or a fake
name) or delete services, it stops with an explanation so the data can be
dealt with deliberately.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "c9d0e1f2a3b4"
down_revision: Union[str, None] = "b8c9d0e1f2a3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column("services", "title", existing_type=sa.String(length=150), nullable=True)
    op.alter_column(
        "services", "price", existing_type=sa.Numeric(precision=10, scale=2), nullable=True
    )


def downgrade() -> None:
    missing = op.get_bind().execute(
        sa.text("SELECT count(*) FROM services WHERE title IS NULL OR price IS NULL")
    ).scalar()
    if missing:
        raise RuntimeError(
            f"{missing} service(s) have no title and/or no price. Downgrading would "
            "require inventing values for them; give them a title and price (or "
            "remove them) first, then downgrade again."
        )
    op.alter_column(
        "services", "price", existing_type=sa.Numeric(precision=10, scale=2), nullable=False
    )
    op.alter_column("services", "title", existing_type=sa.String(length=150), nullable=False)
