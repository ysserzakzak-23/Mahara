"""
Provider availability service layer — managing recurring weekly
working-hours windows.
"""
from datetime import date, datetime, time, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.algorithms.scheduling import build_day_slots
from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.appointment import Appointment, AppointmentStatus
from app.models.availability import ProviderAvailability
from app.models.user import User, UserRole
from app.schemas.availability import DaySlotsResponse, ProviderAvailabilityCreateRequest, SlotResponse


def list_availability(db: Session, provider_id: int, active_only: bool = True) -> list[ProviderAvailability]:
    stmt = select(ProviderAvailability).where(ProviderAvailability.provider_id == provider_id)
    if active_only:
        stmt = stmt.where(ProviderAvailability.is_active.is_(True))
    stmt = stmt.order_by(ProviderAvailability.day_of_week, ProviderAvailability.start_time)
    return list(db.execute(stmt).scalars().all())


def create_availability_window(
    db: Session, provider: User, payload: ProviderAvailabilityCreateRequest
) -> ProviderAvailability:
    window = ProviderAvailability(provider_id=provider.id, **payload.model_dump())
    db.add(window)
    db.commit()
    db.refresh(window)
    return window


def deactivate_availability_window(db: Session, window_id: int, user: User) -> None:
    window = db.get(ProviderAvailability, window_id)
    if window is None:
        raise NotFoundError("فترة التوفر غير موجودة")
    if window.provider_id != user.id and user.role != UserRole.ADMIN:
        raise PermissionDeniedError("ليس لديك صلاحية لتعديل فترة التوفر هذه")

    window.is_active = False
    db.commit()


def get_day_slots(db: Session, provider_id: int, day: date) -> DaySlotsResponse:
    """
    The hours a provider can be booked on `day`, each marked booked / free,
    so the booking screen can grey out taken hours before the customer
    even tries them. Public information: nothing about who booked is returned.
    """
    weekday = day.weekday()  # 0=Monday ... 6=Sunday, like ProviderAvailability
    windows_stmt = select(ProviderAvailability.start_time, ProviderAvailability.end_time).where(
        ProviderAvailability.provider_id == provider_id,
        ProviderAvailability.day_of_week == weekday,
        ProviderAvailability.is_active.is_(True),
    )
    windows: list[tuple[time, time]] = [(row[0], row[1]) for row in db.execute(windows_stmt).all()]
    if not windows:
        return DaySlotsResponse(day=day, day_of_week=weekday, slots=[])

    day_start = datetime.combine(day, time.min, tzinfo=timezone.utc)
    busy_stmt = select(Appointment.start_time, Appointment.end_time).where(
        Appointment.provider_id == provider_id,
        Appointment.status.not_in([AppointmentStatus.CANCELLED, AppointmentStatus.REJECTED]),
        Appointment.start_time < day_start + timedelta(days=1),
        Appointment.end_time > day_start,
    )
    busy = [(row[0], row[1]) for row in db.execute(busy_stmt).all()]

    slots = [
        SlotResponse(start_time=start, end_time=end, is_booked=booked)
        for start, end, booked in build_day_slots(day, windows, busy)
    ]
    return DaySlotsResponse(day=day, day_of_week=weekday, slots=slots)
