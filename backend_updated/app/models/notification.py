"""
Notification & PushDevice models.

Notification is the in-app feed record (what shows up in a bell-icon /
notification list in the Flutter app). PushDevice is the FCM device-token
registry used to additionally deliver a push notification.

These are deliberately separate concerns: writing a Notification row
always succeeds and is the source of truth for "what happened"; sending
an FCM push is a best-effort side channel that can fail (token expired,
device offline, FCM service hiccup) without that failure affecting
whether the user sees the notification in-app. See
app/services/notification_service.py for how the two are combined.
"""
import enum
from typing import TYPE_CHECKING, Optional

from sqlalchemy import Boolean, Enum as SAEnum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin

if TYPE_CHECKING:
    from app.models.user import User


class NotificationType(str, enum.Enum):
    """
    Categorizes a notification so the Flutter app can pick an icon and a
    deep-link target. `related_entity_id` (below) is interpreted according
    to this type — e.g. for APPOINTMENT_* types it's an appointment ID,
    for BARTER_MATCH it's a barter match ID (added in Phase 9).
    """
    APPOINTMENT_BOOKED = "appointment_booked"
    APPOINTMENT_CANCELLED = "appointment_cancelled"
    APPOINTMENT_COMPLETED = "appointment_completed"
    APPOINTMENT_ACCEPTED = "appointment_accepted"
    APPOINTMENT_REJECTED = "appointment_rejected"
    NEW_REVIEW = "new_review"
    BARTER_MATCH = "barter_match"
    EXCHANGE_MATCH_FOUND = "exchange_match_found"
    EXCHANGE_PROPOSAL_RECEIVED = "exchange_proposal_received"
    EXCHANGE_PROPOSAL_ACCEPTED = "exchange_proposal_accepted"
    EXCHANGE_PROPOSAL_REJECTED = "exchange_proposal_rejected"
    SYSTEM = "system"


class Notification(TimestampMixin, Base):
    __tablename__ = "notifications"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    type: Mapped[NotificationType] = mapped_column(
        SAEnum(
            NotificationType,
            name="notification_type",
            native_enum=False,
            length=30,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        nullable=False,
        index=True,
    )
    title: Mapped[str] = mapped_column(String(150), nullable=False)
    message: Mapped[str] = mapped_column(String(500), nullable=False)

    # Generic pointer to whatever entity this notification is about,
    # interpreted according to `type` (see NotificationType docstring).
    # Kept as a plain nullable int rather than a real FK because it can
    # point at different tables depending on `type` — a polymorphic
    # association, which a single FK constraint can't express cleanly.
    related_entity_id: Mapped[Optional[int]] = mapped_column(nullable=True)

    is_read: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)

    # --- Relationships ---
    user: Mapped["User"] = relationship(back_populates="notifications", foreign_keys=[user_id])

    def __repr__(self) -> str:
        return f"<Notification id={self.id} user_id={self.user_id} type={self.type.value}>"


class PushDevice(TimestampMixin, Base):
    """
    A registered device (FCM token) belonging to a user. A user may have
    several rows here (phone + tablet, or a reinstalled app generating a
    new token) — pushes are fanned out to every active token on file.
    """
    __tablename__ = "push_devices"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    fcm_token: Mapped[str] = mapped_column(String(500), unique=True, nullable=False, index=True)
    device_label: Mapped[Optional[str]] = mapped_column(
        String(100), nullable=True, doc="Optional human-readable label, e.g. 'Ahmed's Pixel 8'"
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, nullable=False,
        doc="Set False when FCM reports the token as invalid/expired, instead of deleting the row",
    )

    # --- Relationships ---
    user: Mapped["User"] = relationship(back_populates="push_devices", foreign_keys=[user_id])

    def __repr__(self) -> str:
        return f"<PushDevice id={self.id} user_id={self.user_id} active={self.is_active}>"
