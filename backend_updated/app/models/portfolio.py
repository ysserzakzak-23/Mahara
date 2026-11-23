"""
PortfolioItem model — a single photo in a provider's gallery for a service.

Attached to a Service (not directly to a User) because portfolio images
are evidence of work done under that specific service category — e.g.
a user who offers both "Plumbing" and "Phone Repair" should be able to
show separate, relevant galleries for each, not one undifferentiated pile.
"""
from typing import TYPE_CHECKING, Optional

from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.service import Service


class PortfolioItem(TimestampMixin, Base):
    __tablename__ = "portfolio_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    service_id: Mapped[int] = mapped_column(
        ForeignKey("services.id", ondelete="CASCADE"), nullable=False, index=True
    )

    image_url: Mapped[str] = mapped_column(String(500), nullable=False)
    caption: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    display_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    # --- Relationships ---
    service: Mapped["Service"] = relationship(back_populates="portfolio_items")

    def __repr__(self) -> str:
        return f"<PortfolioItem id={self.id} service_id={self.service_id}>"
