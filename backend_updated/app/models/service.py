"""
Service model — something a provider offers (e.g. "AC Repair - Ahmed").

This is the "I provide X" side of the marketplace. The "I need Y in
exchange" side used for barter matching is modeled separately as
BarterPreference (see app/models/barter.py) because a barter need isn't
a publicly bookable listing — it has no price, no portfolio, no reviews.
Keeping them as distinct models avoids polluting Service with
barter-only nullable columns.
"""
import enum
from typing import TYPE_CHECKING, List, Optional

from sqlalchemy import Boolean, Enum as SAEnum, Float, ForeignKey, Numeric, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.appointment import Appointment
    from app.models.category import ServiceCategory
    from app.models.portfolio import PortfolioItem
    from app.models.review import Review
    from app.models.user import User


class ServiceStatus(str, enum.Enum):
    ACTIVE = "active"        # publicly visible and bookable
    INACTIVE = "inactive"     # hidden by the provider, not bookable
    SUSPENDED = "suspended"   # hidden by an admin (moderation action)


class Service(TimestampMixin, Base):
    __tablename__ = "services"

    id: Mapped[int] = mapped_column(primary_key=True)

    provider_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    category_id: Mapped[int] = mapped_column(
        ForeignKey("service_categories.id", ondelete="RESTRICT"), nullable=False, index=True
    )

    # Optional since services are identified by their CATEGORY (see
    # `display_title`): the app no longer asks for a separate name. Older
    # services keep the name they were published with (still stored and
    # searchable); new ones leave it NULL rather than inventing one.
    title: Mapped[Optional[str]] = mapped_column(String(150), nullable=True)
    description: Mapped[str] = mapped_column(Text, nullable=False)

    # Only meaningful (and required) when category.is_other is True: the
    # actual trade the provider does (e.g. "سباك") since the category
    # itself is just the "doesn't fit our curated list yet" bucket, not a
    # real trade name. Kept as free text rather than its own controlled
    # list — that's the whole point of "Others" — so it's excluded from
    # barter's exact-category matching (Phase 9) and is instead surfaced
    # through search (see semantic_search_service._searchable_chunks) and
    # shown as the visible category label in place of "Others" wherever
    # this service is displayed. NULL/ignored for any other category.
    custom_category_label: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)

    # Numeric(10, 2) rather than Float for money: avoids floating-point
    # rounding artifacts in prices (e.g. 19.999999999998 instead of 20.00).
    # Optional: NULL means "no price given" (the app shows «السعر غير
    # محدد») — it is never stored as 0, which would read as "free".
    price: Mapped[Optional[float]] = mapped_column(Numeric(10, 2), nullable=True)
    price_unit: Mapped[str] = mapped_column(
        String(30), default="fixed", nullable=False,
        doc="e.g. 'fixed', 'per_hour', 'per_visit' — display hint for the Flutter UI",
    )

    # The single "cover"/thumbnail photo shown in listings and search
    # results. Distinct from PortfolioItem, which is a whole gallery of
    # past-work photos for the service — this is the one image that
    # represents the service itself at a glance.
    cover_image_url: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)

    status: Mapped[ServiceStatus] = mapped_column(
        SAEnum(
            ServiceStatus,
            name="service_status",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        default=ServiceStatus.ACTIVE,
        nullable=False,
        index=True,
    )

    # Optional location override: a provider's service location may differ
    # from their personal profile location (e.g. a shop address vs home
    # address). NULL means "use the provider's profile location" — see
    # app/algorithms/geo.py for how search resolves this fallback.
    latitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True, index=True)
    longitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True, index=True)

    # True for a service delivered online/remotely (e.g. a design or
    # translation service done over a call) rather than in person. Doesn't
    # exempt the service from geo search — a remote provider can still be
    # based in and searchable from a particular city — it's purely a
    # display/filter hint so a customer can tell at a glance whether
    # showing up in person is required.
    is_remote: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # --- Relationships ---
    provider: Mapped["User"] = relationship(back_populates="services", foreign_keys=[provider_id])
    category: Mapped["ServiceCategory"] = relationship(back_populates="services")
    portfolio_items: Mapped[List["PortfolioItem"]] = relationship(
        back_populates="service", cascade="all, delete-orphan", order_by="PortfolioItem.display_order"
    )
    reviews: Mapped[List["Review"]] = relationship(
        back_populates="service", cascade="all, delete-orphan"
    )
    # passive_deletes=True is the fix for a real bug: without it, SQLAlchemy's
    # ORM-level cascade tries to *nullify* appointments.service_id on the
    # child rows when a Service is deleted (its default "de-associate"
    # behavior for a relationship with no cascade config), which fails
    # because that column is NOT NULL. passive_deletes=True tells SQLAlchemy
    # to leave deletion of the child rows entirely to the database's own
    # ON DELETE CASCADE (already declared on the FK in models/appointment.py),
    # which is what we actually want — appointments tied to a deleted
    # service should be deleted, not orphaned. This only manifested for
    # services that already had at least one appointment, which is why it
    # looked "intermittent."
    appointments: Mapped[List["Appointment"]] = relationship(
        back_populates="service", passive_deletes=True
    )

    @property
    def category_label(self) -> str:
        """The trade this service is filed under: the custom label for the
        «أخرى» category (e.g. "سباك"), otherwise the category name."""
        category = self.category
        if category is None:
            return ""
        label = (self.custom_category_label or "").strip()
        return label if category.is_other and label else category.name

    @property
    def display_title(self) -> str:
        """
        How this service is named everywhere it's shown: its category. The
        category is the service's identity; the description carries the
        details. A legacy free-text title is kept in `title` (and still
        searched) but is not what the app shows.
        """
        return self.category_label or (self.title or "").strip() or "خدمة"

    def __repr__(self) -> str:
        return f"<Service id={self.id} title={self.title!r} provider_id={self.provider_id}>"
