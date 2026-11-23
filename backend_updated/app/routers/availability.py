"""
Provider availability routes.
"""
from datetime import date

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.core.exceptions import PermissionDeniedError
from app.models.user import User
from app.schemas.availability import (
    DaySlotsResponse,
    ProviderAvailabilityCreateRequest,
    ProviderAvailabilityResponse,
)
from app.services import availability_service

router = APIRouter(prefix="/api/v1/providers/{provider_id}/availability", tags=["Availability"])


@router.get("", response_model=list[ProviderAvailabilityResponse])
def list_availability(provider_id: int, db: Session = Depends(get_db)) -> list[ProviderAvailabilityResponse]:
    """Lists a provider's active weekly availability windows. Public endpoint."""
    windows = availability_service.list_availability(db, provider_id)
    return [ProviderAvailabilityResponse.model_validate(w) for w in windows]


@router.get("/slots", response_model=DaySlotsResponse)
def get_day_slots(provider_id: int, day: date, db: Session = Depends(get_db)) -> DaySlotsResponse:
    """
    The one-hour slots a provider can be booked for on `day` (YYYY-MM-DD),
    each marked `is_booked` when a pending or confirmed appointment already
    holds it. Empty when the provider does not work that weekday. Public
    endpoint; it never reveals who booked a slot.
    """
    return availability_service.get_day_slots(db, provider_id, day)


@router.post("", response_model=ProviderAvailabilityResponse, status_code=status.HTTP_201_CREATED)
def create_availability_window(
    provider_id: int,
    payload: ProviderAvailabilityCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ProviderAvailabilityResponse:
    """
    Adds a recurring weekly availability window for the authenticated user.

    `provider_id` in the path must match the authenticated user's own ID —
    a provider can only manage their own schedule.
    """
    if provider_id != current_user.id:
        raise PermissionDeniedError("يمكنك إدارة أوقات توفرك الخاصة فقط")

    window = availability_service.create_availability_window(db, current_user, payload)
    return ProviderAvailabilityResponse.model_validate(window)


@router.delete("/{window_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_availability_window(
    provider_id: int,
    window_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Deactivates an availability window (e.g. for vacation), preserving its history."""
    availability_service.deactivate_availability_window(db, window_id, current_user)
