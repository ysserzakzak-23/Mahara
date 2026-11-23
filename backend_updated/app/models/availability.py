"""
ProviderAvailability model — a provider's recurring weekly working-hours
window, e.g. "every Monday, 09:00-17:00".

A provider can declare multiple windows per weekday (e.g. split shifts:
09:00-12:00 and 14:00-18:00). Appointment booking validates that the
requested [start_time, end_time) falls entirely within at least one
active availability window for that weekday — see
app/algorithms/scheduling.py for the containment check, and
app/services/appointment_service.py for how it's combined with conflict
detection against existing appointments.

`day_of_week` follows Python's datetime.weekday() convention: Monday=0
... Sunday=6. This is documented explicitly because ISO 8601, Python's
calendar module, and JavaScript's Date.getDay() all disagree on whether
weeks start at 0=Sunday or 0=Monday — an easy source of off-by-one bugs
between this backend and the Flutter frontend if not pinned down clearly.
"""
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, CheckConstraint, ForeignKey, Integer, Time
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.user import User


class ProviderAvailability(TimestampMixin, Base):
    __tablename__ = "provider_availabilities"
    __table_args__ = (
        CheckConstraint("day_of_week >= 0 AND day_of_week <= 6", name="ck_availability_day_of_week_range"),
        CheckConstraint("end_time > start_time", name="ck_availability_end_after_start"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    provider_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # 0=Monday ... 6=Sunday (matches Python's date.weekday()/datetime.weekday()).
    day_of_week: Mapped[int] = mapped_column(Integer, nullable=False, index=True)
    start_time: Mapped[Time] = mapped_column(Time, nullable=False)
    end_time: Mapped[Time] = mapped_column(Time, nullable=False)

    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False,
        doc="Lets a provider temporarily pause a window (e.g. vacation) without deleting it",
    )

    # --- Relationships ---
    provider: Mapped["User"] = relationship(back_populates="availabilities", foreign_keys=[provider_id])

    def __repr__(self) -> str:
        return (
            f"<ProviderAvailability provider_id={self.provider_id} "
            f"day={self.day_of_week} {self.start_time}-{self.end_time}>"
        )
