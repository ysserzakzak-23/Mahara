"""
Appointment model — a booking of a specific Service at a specific time.

Status workflow — appointments now require explicit provider approval
(per product decision update; previously auto-confirmed):

    PENDING ----> CONFIRMED ----> COMPLETED
       |               |
       v               v
    REJECTED       CANCELLED
       ^               ^
       |               |
       +---- (either terminal state also reachable from PENDING via CANCELLED,
              e.g. the customer withdraws their own request before the
              provider responds)

A PENDING appointment still occupies/blocks the time slot (so two
customers can't both be approved for the same slot), but a REJECTED one
does not — both the application-level conflict check
(_assert_no_conflicts in appointment_service.py) and the database
exclusion constraint's WHERE clause exclude REJECTED alongside CANCELLED.

Conflict prevention is enforced at TWO layers, the standard, defensible
approach for booking systems:

  1. Application layer (app/algorithms/scheduling.py + appointment_service.py):
     checks the new appointment's time range against the provider's
     existing PENDING/CONFIRMED appointments and declared availability
     windows, returning a clear error before attempting to insert.

  2. Database layer: a PostgreSQL EXCLUSION CONSTRAINT (added via the
     btree_gist extension in the Alembic migration, NOT expressible
     through SQLAlchemy's declarative column API) guarantees, at the
     database level, that two non-cancelled/non-rejected appointments for
     the same provider can never have overlapping time ranges — even if
     two requests race past the application-level check simultaneously.
     The application check exists for a fast, friendly error message;
     the DB constraint is the actual source of truth / last line of
     defense. See the Phase 6 migration (and its Phase 10 follow-up that
     added REJECTED to the exclusion) for the exact DDL.

provider_id is a DELIBERATE DENORMALIZATION of Service.provider_id at
booking time, not an oversight: the DB exclusion constraint needs
provider_id directly on THIS table to check conflicts across ALL of a
provider's services in one constraint — a GIST exclusion constraint
cannot reach through a join to Service.provider_id. It is set once at
creation (see appointment_service.create_appointment) and never changes,
since a service's provider never changes after creation.
"""
import enum
from datetime import datetime
from typing import TYPE_CHECKING, Optional

from sqlalchemy import CheckConstraint, DateTime, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.service import Service
    from app.models.user import User


class AppointmentStatus(str, enum.Enum):
    PENDING = "pending"       # awaiting the provider's accept/reject
    CONFIRMED = "confirmed"   # accepted by the provider
    REJECTED = "rejected"     # declined by the provider; frees up the time slot
    COMPLETED = "completed"   # marked done after the appointment time has passed
    CANCELLED = "cancelled"   # cancelled by either party; frees up the time slot


class Appointment(TimestampMixin, Base):
    __tablename__ = "appointments"
    __table_args__ = (
        CheckConstraint("end_time > start_time", name="ck_appointment_end_after_start"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    customer_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    service_id: Mapped[int] = mapped_column(
        ForeignKey("services.id", ondelete="CASCADE"), nullable=False, index=True
    )
    provider_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # NULL for a booking request on a REMOTE service whose provider set no
    # working hours: the customer names no day or hour, and the two sides
    # agree on it afterwards. Such rows never take part in the overlap checks.
    start_time: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    end_time: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    status: Mapped[AppointmentStatus] = mapped_column(
        SAEnum(
            AppointmentStatus,
            name="appointment_status",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        default=AppointmentStatus.PENDING,
        nullable=False,
        index=True,
    )
    customer_notes: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)
    cancellation_reason: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)

    # --- Relationships ---
    customer: Mapped["User"] = relationship(
        back_populates="appointments_as_customer", foreign_keys=[customer_id]
    )
    provider: Mapped["User"] = relationship(
        back_populates="appointments_as_provider", foreign_keys=[provider_id]
    )
    service: Mapped["Service"] = relationship(back_populates="appointments", foreign_keys=[service_id])

    @property
    def service_title(self) -> str:
        """Lets AppointmentResponse expose a readable title (via from_attributes)
        without the schema layer needing to know about the Service model."""
        return self.service.display_title

    def __repr__(self) -> str:
        return (
            f"<Appointment id={self.id} service_id={self.service_id} "
            f"status={self.status.value} {self.start_time}-{self.end_time}>"
        )
