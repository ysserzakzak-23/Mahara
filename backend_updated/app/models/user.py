"""
User model — core identity and authentication record.

Deliberately lean: only fields needed for auth and authorization live here
(email, hashed password, role, is_provider, is_active). Everything else
(name, bio, avatar, location, etc.) lives on UserProfile (see profile.py)
so that the hot path of decoding a JWT and loading the user doesn't pull
in a wide row of rarely-needed columns.
"""
import enum
from typing import TYPE_CHECKING, List

from sqlalchemy import Boolean, Enum as SAEnum, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.appointment import Appointment
    from app.models.availability import ProviderAvailability
    from app.models.barter import BarterParticipant, BarterPreference
    from app.models.exchange import ExchangeProposal, ExchangeRequest
    from app.models.notification import Notification, PushDevice
    from app.models.profile import UserProfile
    from app.models.review import Review
    from app.models.service import Service


class UserRole(str, enum.Enum):
    """System-level permission role. Distinct from `is_provider`, which is
    about marketplace participation, not system permissions."""
    USER = "user"
    ADMIN = "admin"


class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    hashed_password: Mapped[str] = mapped_column(String(255), nullable=False)

    # values_callable is deliberate: SQLAlchemy's Enum type defaults to
    # persisting the Python member *name* ("USER"/"ADMIN"), not its
    # `.value` ("user"/"admin"). That's surprising for anyone editing the
    # role column directly with SQL (a common way to bootstrap the first
    # admin, since there's no self-service promotion) — `UPDATE users SET
    # role = 'admin'` looks correct but previously raised a LookupError on
    # the next read. Storing `.value` instead makes the column match what
    # you'd naturally type, and what the JSON API already sends/expects.
    role: Mapped[UserRole] = mapped_column(
        SAEnum(
            UserRole,
            name="user_role",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        default=UserRole.USER,
        nullable=False,
    )

    # True once the user has listed at least one service, or has opted in
    # manually from their profile settings. Independent of `role`: a USER
    # can be a provider, an ADMIN can also be a provider.
    is_provider: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    # --- Relationships ---
    profile: Mapped["UserProfile"] = relationship(
        back_populates="user",
        uselist=False,
        cascade="all, delete-orphan",
    )
    services: Mapped[List["Service"]] = relationship(
        back_populates="provider",
        cascade="all, delete-orphan",
        foreign_keys="Service.provider_id",
    )
    reviews_written: Mapped[List["Review"]] = relationship(
        back_populates="reviewer",
        foreign_keys="Review.reviewer_id",
        cascade="all, delete-orphan",
    )
    appointments_as_customer: Mapped[List["Appointment"]] = relationship(
        back_populates="customer",
        foreign_keys="Appointment.customer_id",
    )
    appointments_as_provider: Mapped[List["Appointment"]] = relationship(
        back_populates="provider",
        foreign_keys="Appointment.provider_id",
    )
    availabilities: Mapped[List["ProviderAvailability"]] = relationship(
        back_populates="provider",
        cascade="all, delete-orphan",
        foreign_keys="ProviderAvailability.provider_id",
    )
    notifications: Mapped[List["Notification"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    push_devices: Mapped[List["PushDevice"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    barter_participations: Mapped[List["BarterParticipant"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    barter_preferences: Mapped[List["BarterPreference"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        foreign_keys="BarterPreference.user_id",
    )
    exchange_requests: Mapped[List["ExchangeRequest"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        foreign_keys="ExchangeRequest.user_id",
    )
    exchange_proposals_sent: Mapped[List["ExchangeProposal"]] = relationship(
        back_populates="proposer",
        cascade="all, delete-orphan",
        foreign_keys="ExchangeProposal.proposer_id",
    )

    def __repr__(self) -> str:
        return f"<User id={self.id} email={self.email!r} role={self.role.value}>"
