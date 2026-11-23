"""
Imports every ORM model so that:
  1. `Base.metadata` is fully populated for Alembic autogenerate.
  2. Other modules can import models from `app.models` directly,
     e.g. `from app.models import User, UserProfile`.

IMPORTANT: whenever a new model file is added, import it here too,
otherwise Alembic will not see its table when generating migrations.
"""
from app.models.appointment import Appointment, AppointmentStatus
from app.models.availability import ProviderAvailability
from app.models.barter import BarterMatch, BarterMatchType, BarterParticipant, BarterPreference
from app.models.category import ServiceCategory
from app.models.password_reset import PasswordResetToken
from app.models.notification import Notification, NotificationType, PushDevice
from app.models.portfolio import PortfolioItem
from app.models.profile import UserProfile
from app.models.review import Review
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)

__all__ = [
    "User",
    "UserRole",
    "UserProfile",
    "ServiceCategory",
    "Service",
    "ServiceStatus",
    "PortfolioItem",
    "Review",
    "Appointment",
    "AppointmentStatus",
    "ProviderAvailability",
    "Notification",
    "NotificationType",
    "PushDevice",
    "PasswordResetToken",
    "BarterPreference",
    "BarterMatch",
    "BarterMatchType",
    "BarterParticipant",
]
