"""
UserProfile model — display information and geolocation.

One-to-one with User. Separated from User so that:
  1. The auth hot-path (JWT decode -> load user) stays lean.
  2. Latitude/longitude live in one well-indexed place for geo search
     (see app/algorithms/geo.py and the provider search endpoints).
"""
from typing import TYPE_CHECKING, Optional

from sqlalchemy import Float, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.user import User


class UserProfile(TimestampMixin, Base):
    __tablename__ = "user_profiles"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False, index=True
    )

    full_name: Mapped[str] = mapped_column(String(150), nullable=False)
    phone_number: Mapped[Optional[str]] = mapped_column(String(30), nullable=True)
    bio: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    avatar_url: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)

    # City the user operates/lives in, chosen from the fixed list in
    # app/core/constants.py. Nullable only for backward compatibility with
    # rows created before this column existed; new registrations require it
    # (see UserRegisterRequest.city). Used for city-based search/listing
    # filters, kept separate from the free-text address_label and the
    # lat/lng geo columns, which serve the more precise map-based search.
    city: Mapped[Optional[str]] = mapped_column(String(100), nullable=True, index=True)

    # --- Geolocation ---
    # Nullable because a user may not have shared their location yet.
    # Indexed individually (rather than as a composite) since the Haversine
    # search filters by a lat/lng bounding box before the precise distance
    # calculation — see app/algorithms/geo.py for the query strategy.
    latitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True, index=True)
    longitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True, index=True)
    address_label: Mapped[Optional[str]] = mapped_column(
        String(255), nullable=True, doc="Human-readable address/area, e.g. 'Maadi, Cairo'"
    )

    # --- Relationships ---
    user: Mapped["User"] = relationship(back_populates="profile")

    def __repr__(self) -> str:
        return f"<UserProfile user_id={self.user_id} full_name={self.full_name!r}>"
