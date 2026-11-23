"""
Review model — a star rating (1-5) plus optional comment, left by any
authenticated user against a specific Service.

Design choices:
  - Not gated on a completed appointment (product decision: any user can
    review any service, similar to Google Maps/Yelp). If verified-purchase
    reviews are wanted later, add a nullable appointment_id FK and a
    "verified" flag without breaking this schema.
  - One review per (reviewer, service) pair, enforced at the DB level via
    a UniqueConstraint — a user updates their existing review rather than
    spamming new ones.
  - `rating` has a DB-level CHECK constraint (1-5) as a defense-in-depth
    measure: even if a future code path bypasses Pydantic validation
    (e.g. a raw SQL script, a bug in another service), the database
    itself refuses to store an invalid rating.
"""
from typing import TYPE_CHECKING, Optional

from sqlalchemy import CheckConstraint, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.service import Service
    from app.models.user import User


class Review(TimestampMixin, Base):
    __tablename__ = "reviews"
    __table_args__ = (
        UniqueConstraint("reviewer_id", "service_id", name="uq_review_reviewer_service"),
        CheckConstraint("rating >= 1 AND rating <= 5", name="ck_review_rating_range"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    reviewer_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    service_id: Mapped[int] = mapped_column(
        ForeignKey("services.id", ondelete="CASCADE"), nullable=False, index=True
    )

    rating: Mapped[int] = mapped_column(Integer, nullable=False)
    comment: Mapped[Optional[str]] = mapped_column(String(2000), nullable=True)

    # --- Relationships ---
    reviewer: Mapped["User"] = relationship(back_populates="reviews_written", foreign_keys=[reviewer_id])
    service: Mapped["Service"] = relationship(back_populates="reviews", foreign_keys=[service_id])

    def __repr__(self) -> str:
        return f"<Review id={self.id} service_id={self.service_id} rating={self.rating}>"
