"""
Appointment routes.
"""
from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.appointment import AppointmentCancelRequest, AppointmentCreateRequest, AppointmentResponse
from app.schemas.pagination import Page, PageParams, page_or_list, page_params
from app.services import appointment_service

router = APIRouter(prefix="/api/v1/appointments", tags=["Appointments"])


@router.get("/me", response_model=list[AppointmentResponse] | Page[AppointmentResponse])
def list_my_appointments(
    as_provider: bool = Query(default=False, description="If true, lists appointments where the user is the provider"),
    params: PageParams = Depends(page_params()),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[AppointmentResponse] | Page[AppointmentResponse]:
    """
    Lists the authenticated user's appointments, as customer (default) or as provider.

    Pagination is opt-in: without `page`/`page_size` this returns every
    matching appointment as a plain array, exactly as it always has. With
    either of them it returns one page in the shared envelope. `as_provider`
    picks the side first, so a page never mixes the two.

    No `total`: nothing on the bookings screen shows a count, and `has_next`
    is what decides whether to ask for more.
    """
    appointments, has_next = appointment_service.list_my_appointments(
        db, current_user, as_provider=as_provider, params=params
    )
    items = [AppointmentResponse.model_validate(a) for a in appointments]
    return page_or_list(items, params, has_next)


@router.get("/{appointment_id}", response_model=AppointmentResponse)
def get_appointment(
    appointment_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """Retrieves a single appointment. Only its customer, provider, or an admin may view it."""
    appointment = appointment_service.get_appointment_for_user(db, appointment_id, current_user)
    return AppointmentResponse.model_validate(appointment)


@router.post("", response_model=AppointmentResponse, status_code=status.HTTP_201_CREATED)
def create_appointment(
    payload: AppointmentCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """
    Requests an appointment for a service.

    Validates that the requested time falls within the provider's
    declared availability AND does not conflict with any of the
    provider's existing pending/confirmed appointments. The booking
    starts as PENDING — the provider must accept or reject it (see
    /accept and /reject below) before it's actually confirmed.
    """
    appointment = appointment_service.create_appointment(db, current_user, payload)
    return AppointmentResponse.model_validate(appointment)


@router.post("/{appointment_id}/accept", response_model=AppointmentResponse)
def accept_appointment(
    appointment_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """Provider-only: accepts a pending appointment request."""
    appointment = appointment_service.accept_appointment(db, appointment_id, current_user)
    return AppointmentResponse.model_validate(appointment)


@router.post("/{appointment_id}/reject", response_model=AppointmentResponse)
def reject_appointment(
    appointment_id: int,
    payload: AppointmentCancelRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """Provider-only: rejects a pending appointment request, freeing up the time slot."""
    appointment = appointment_service.reject_appointment(
        db, appointment_id, current_user, payload.cancellation_reason
    )
    return AppointmentResponse.model_validate(appointment)


@router.post("/{appointment_id}/cancel", response_model=AppointmentResponse)
def cancel_appointment(
    appointment_id: int,
    payload: AppointmentCancelRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """Cancels an appointment, freeing up the time slot. Either participant may cancel."""
    appointment = appointment_service.cancel_appointment(
        db, appointment_id, current_user, payload.cancellation_reason
    )
    return AppointmentResponse.model_validate(appointment)


@router.post("/{appointment_id}/complete", response_model=AppointmentResponse)
def mark_appointment_completed(
    appointment_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AppointmentResponse:
    """Marks a confirmed appointment as completed."""
    appointment = appointment_service.mark_appointment_completed(db, appointment_id, current_user)
    return AppointmentResponse.model_validate(appointment)
