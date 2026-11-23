"""
ServiceCategory model — the controlled vocabulary of service types
(Electrician, Plumber, Cook, Phone Repair, Cleaner, ...).

Deliberately FLAT (no parent/subcategory tree). Two reasons:
  1. Simplicity for a graduation project scope.
  2. The barter-matching algorithm (Phase 9) treats "category" as the
     atomic unit of exchange — User A offers category X, needs category Y.
     A tree would require deciding whether matches must be exact-category
     or subtree-compatible, which adds real complexity for little payoff
     here. Flat categories make a "match" a simple equality check.

Categories are admin-managed (see app/routers/admin.py in Phase 8) —
regular users can only select from existing categories, not create new ones,
which keeps the taxonomy clean and prevents duplicate near-identical entries.
"""
from typing import TYPE_CHECKING, List, Optional

from sqlalchemy import Boolean, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.barter import BarterPreference
    from app.models.service import Service


class ServiceCategory(TimestampMixin, Base):
    __tablename__ = "service_categories"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100), unique=True, nullable=False, index=True)
    description: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    icon_name: Mapped[Optional[str]] = mapped_column(
        String(100), nullable=True, doc="Icon identifier the Flutter app maps to a local asset"
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False,
        doc="Soft-disable a category without deleting it (preserves history on existing services)",
    )
    is_other: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False,
        doc=(
            "Marks this as the catch-all 'Others' bucket for service types "
            "that don't fit any of the curated categories yet. At most one "
            "category should have this set at a time — category_service "
            "enforces that by unsetting it on any other category whenever "
            "one is marked as the 'Others' bucket. A service filed under "
            "this category is expected to carry a free-text "
            "Service.custom_category_label describing what it actually is "
            "(e.g. 'سباك'), since 'Others' itself isn't a real trade name."
        ),
    )

    # --- Relationships ---
    services: Mapped[List["Service"]] = relationship(back_populates="category")
    barter_preferences: Mapped[List["BarterPreference"]] = relationship(
        back_populates="offered_category", foreign_keys="BarterPreference.offered_category_id"
    )

    def __repr__(self) -> str:
        return f"<ServiceCategory id={self.id} name={self.name!r}>"
