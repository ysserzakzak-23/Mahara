"""
Appointment service layer — booking orchestration.

This is where the two-layer conflict-prevention strategy described in
app/models/appointment.py is actually exercised at the application level:

  1. Fetch the provider's active availability windows for the requested
     weekday, and confirm the requested time range fits entirely within
     at least one of them (app.algorithms.scheduling.find_matching_availability_window).
  2. Fetch the provider's existing CONFIRMED appointments and confirm none
     of them overlap the requested time range (app.algorithms.scheduling.
     find_conflicting_appointments).

Both checks happen here, before any INSERT is attempted, so the common
case returns a fast, specific, friendly error. The database-level
exclusion constraint (added in the Phase 6 migration) is what actually
guarantees correctness under concurrent requests — this application-level
check is a courtesy, not the sole guarantee.
"""
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.algorithms.scheduling import find_conflicting_appointments, find_matching_availability_window
from app.core.exceptions import ConflictError, NotFoundError, PermissionDeniedError, ValidationError
from app.core.pagination import fetch_page
from app.models.appointment import Appointment, AppointmentStatus
from app.models.availability import ProviderAvailability
from app.models.notification import NotificationType
from app.models.service import Service
from app.models.user import User, UserRole
from app.schemas.appointment import AppointmentCreateRequest
from app.schemas.pagination import PageParams
from app.services import notification_service
from app.services.service_service import get_service_by_id
from sqlalchemy.exc import IntegrityError


def _query_with_relations():
    return select(Appointment).options(
        selectinload(Appointment.customer).selectinload(User.profile),
        selectinload(Appointment.provider).selectinload(User.profile),
        # The category too: Appointment.service_title is the service's
        # display_title, which is its category. Without this, serialising a
        # list lazy-loads one category per distinct category in it.
        selectinload(Appointment.service).selectinload(Service.category),
    )


def get_appointment_by_id(db: Session, appointment_id: int) -> Appointment:
    stmt = _query_with_relations().where(Appointment.id == appointment_id)
    appointment = db.execute(stmt).scalar_one_or_none()
    if appointment is None:
        raise NotFoundError("الموعد غير موجود")
    return appointment


def _fmt_dt(value: datetime) -> str:
    """Formats a datetime for Arabic notification text, e.g. 2026/10/05 الساعة 14:30."""
    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)
    return f"{value:%Y/%m/%d} الساعة {value:%H:%M}"


def _when(value: Optional[datetime]) -> str:
    """" بتاريخ 2026/10/05 الساعة 14:30" for a scheduled appointment, "" when
    the customer chose no day/hour."""
    return f" بتاريخ {_fmt_dt(value)}" if value is not None else ""


def _assert_is_participant(appointment: Appointment, user: User) -> None:
    if user.id not in (appointment.customer_id, appointment.provider_id) and user.role != UserRole.ADMIN:
        raise PermissionDeniedError("أنت لست طرفاً في هذا الموعد")


def get_appointment_for_user(db: Session, appointment_id: int, user: User) -> Appointment:
    """
    Fetches an appointment and verifies the requesting user is allowed to
    view it (its customer, its provider, or an admin). This is the public
    entry point routers should use rather than reaching into the private
    _assert_is_participant helper directly.
    """
    appointment = get_appointment_by_id(db, appointment_id)
    _assert_is_participant(appointment, user)
    return appointment


def _my_appointments_query(user: User, as_provider: bool):
    """
    One side of one user's appointments, soonest-looking first.

    The order is unchanged: COALESCE(start_time, created_at) DESC, so a
    request with no agreed time sorts by when it was asked for. The id
    breaks ties — two appointments can share that COALESCE value (both
    undated and created in the same transaction, or genuinely booked for
    the same instant), and a page boundary falling between them would
    otherwise repeat or skip one.

    The eager loads come from _query_with_relations, which is what keeps
    serialising a page to a fixed number of queries instead of one per row
    (Appointment.service.category feeds service.display_title). selectinload
    issues its own follow-up SELECTs, so it stays correct under the LIMIT
    that pagination adds here.
    """
    column = Appointment.provider_id if as_provider else Appointment.customer_id
    return (
        _query_with_relations()
        .where(column == user.id)
        .order_by(
            func.coalesce(Appointment.start_time, Appointment.created_at).desc(),
            Appointment.id.desc(),
        )
    )


def list_my_appointments(
    db: Session,
    user: User,
    as_provider: bool = False,
    params: PageParams | None = None,
) -> tuple[list[Appointment], bool]:
    """
    Returns (appointments, has_next).

    Without pagination (the default) that is every appointment on that side
    and False — the behaviour this endpoint has always had.
    """
    return fetch_page(db, _my_appointments_query(user, as_provider), params or PageParams())


def _assert_fits_within_availability(db: Session, provider_id: int, start: datetime, end: datetime) -> None:
    weekday = start.weekday()  # 0=Monday ... 6=Sunday, matching ProviderAvailability's convention
    stmt = select(ProviderAvailability).where(
        ProviderAvailability.provider_id == provider_id,
        ProviderAvailability.day_of_week == weekday,
        ProviderAvailability.is_active.is_(True),
    )
    windows = [(w.day_of_week, w.start_time, w.end_time) for w in db.execute(stmt).scalars().all()]

    if not windows:
        raise ValidationError("مزوّد الخدمة لم يحدد أوقات توفر في هذا اليوم")

    match = find_matching_availability_window(start, end, windows)
    if match is None:
        raise ValidationError(
            "الوقت المطلوب لا يقع ضمن أوقات عمل مزوّد الخدمة المتاحة"
        )


def _assert_no_conflicts(db: Session, provider_id: int, start: datetime, end: datetime) -> None:
    stmt = select(Appointment.id, Appointment.start_time, Appointment.end_time).where(
        Appointment.provider_id == provider_id,
        Appointment.status.not_in([AppointmentStatus.CANCELLED, AppointmentStatus.REJECTED]),
    )
    existing = [(row[0], row[1], row[2]) for row in db.execute(stmt).all()]

    conflicts = find_conflicting_appointments(start, end, existing)
    if conflicts:
        raise ConflictError(
            f"الوقت المطلوب يتعارض مع {len(conflicts)} موعد/مواعيد موجودة لدى مزوّد الخدمة"
        )


def _assert_can_book_without_time(db: Session, service) -> None:
    """
    A request with no day/hour is accepted only for a REMOTE service whose
    provider has set no working hours: the two sides then agree on the time
    themselves. Everything else must pick a time inside the provider's hours.
    """
    if not service.is_remote:
        raise ValidationError("يجب اختيار اليوم والساعة لحجز هذه الخدمة")
    has_hours = db.execute(
        select(ProviderAvailability.id)
        .where(
            ProviderAvailability.provider_id == service.provider_id,
            ProviderAvailability.is_active.is_(True),
        )
        .limit(1)
    ).first()
    if has_hours is not None:
        raise ValidationError("حدّد مزوّد الخدمة أيام دوام، يجب اختيار اليوم والساعة")


def create_appointment(db: Session, customer: User, payload: AppointmentCreateRequest) -> Appointment:
    service = get_service_by_id(db, payload.service_id)

    if service.provider_id == customer.id:
        raise ValidationError("لا يمكنك حجز خدمتك الخاصة")

    if payload.has_time:
        _assert_fits_within_availability(db, service.provider_id, payload.start_time, payload.end_time)
        _assert_no_conflicts(db, service.provider_id, payload.start_time, payload.end_time)
    else:
        _assert_can_book_without_time(db, service)

    appointment = Appointment(
        customer_id=customer.id,
        provider_id=service.provider_id,
        service_id=service.id,
        start_time=payload.start_time,
        end_time=payload.end_time,
        customer_notes=payload.customer_notes,
        status=AppointmentStatus.PENDING,
    )
    db.add(appointment)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        if getattr(exc.orig, "pgcode", None) == "23P01":
            raise ConflictError("تم حجز هذا الوقت للتو من قبل شخص آخر") from exc
        raise
    db.refresh(appointment)

    customer_display_name = customer.profile.full_name if customer.profile else "عميل"
    notification_service.notify_user(
        db,
        user_id=service.provider_id,
        notification_type=NotificationType.APPOINTMENT_BOOKED,
        title="طلب حجز جديد",
        message=(
            f"طلب {customer_display_name} حجز '{service.display_title}'{_when(payload.start_time)}"
            + ("" if payload.has_time else " دون تحديد يوم أو ساعة، تواصل معه للاتفاق على الموعد")
            + " — يمكنك القبول أو الرفض"
        ),
        related_entity_id=appointment.id,
    )

    return get_appointment_by_id(db, appointment.id)


def accept_appointment(db: Session, appointment_id: int, user: User) -> Appointment:
    """Only the provider can accept — moves a PENDING request to CONFIRMED."""
    appointment = get_appointment_by_id(db, appointment_id)
    if user.id != appointment.provider_id:
        raise PermissionDeniedError("مزوّد الخدمة فقط يمكنه قبول هذا الموعد")
    if appointment.status != AppointmentStatus.PENDING:
        raise ConflictError("يمكن قبول الموعد المعلّق فقط")

    appointment.status = AppointmentStatus.CONFIRMED
    db.commit()
    db.refresh(appointment)

    notification_service.notify_user(
        db,
        user_id=appointment.customer_id,
        notification_type=NotificationType.APPOINTMENT_ACCEPTED,
        title="تم قبول الحجز",
        message=f"تم قبول حجزك{_when(appointment.start_time)}",
        related_entity_id=appointment.id,
    )
    return appointment


def reject_appointment(
    db: Session, appointment_id: int, user: User, cancellation_reason: str | None
) -> Appointment:
    """
    Only the provider can reject — moves a PENDING request to REJECTED,
    freeing up the time slot for someone else (see the exclusion
    constraint update in the Phase 10 migration).
    """
    appointment = get_appointment_by_id(db, appointment_id)
    if user.id != appointment.provider_id:
        raise PermissionDeniedError("مزوّد الخدمة فقط يمكنه رفض هذا الموعد")
    if appointment.status != AppointmentStatus.PENDING:
        raise ConflictError("يمكن رفض الموعد المعلّق فقط")

    appointment.status = AppointmentStatus.REJECTED
    appointment.cancellation_reason = cancellation_reason
    db.commit()
    db.refresh(appointment)

    notification_service.notify_user(
        db,
        user_id=appointment.customer_id,
        notification_type=NotificationType.APPOINTMENT_REJECTED,
        title="تم رفض الحجز",
        message=(
            f"تم رفض حجزك{_when(appointment.start_time)}"
            + (f": {cancellation_reason}" if cancellation_reason else "")
        ),
        related_entity_id=appointment.id,
    )
    return appointment


def cancel_appointment(
    db: Session, appointment_id: int, user: User, cancellation_reason: str | None
) -> Appointment:
    appointment = get_appointment_by_id(db, appointment_id)
    _assert_is_participant(appointment, user)

    if appointment.status == AppointmentStatus.CANCELLED:
        raise ConflictError("تم إلغاء هذا الموعد مسبقاً")
    if appointment.status == AppointmentStatus.REJECTED:
        raise ConflictError("تم رفض هذا الموعد مسبقاً")
    if appointment.status == AppointmentStatus.COMPLETED:
        raise ConflictError("لا يمكن إلغاء موعد مكتمل")

    appointment.status = AppointmentStatus.CANCELLED
    appointment.cancellation_reason = cancellation_reason
    db.commit()
    db.refresh(appointment)

    other_party_id = appointment.provider_id if user.id == appointment.customer_id else appointment.customer_id
    notification_service.notify_user(
        db,
        user_id=other_party_id,
        notification_type=NotificationType.APPOINTMENT_CANCELLED,
        title="تم إلغاء الموعد",
        message=f"تم إلغاء الموعد المحدد{_when(appointment.start_time)}"
        + (f": {cancellation_reason}" if cancellation_reason else ""),
        related_entity_id=appointment.id,
    )

    return appointment


def mark_appointment_completed(db: Session, appointment_id: int, user: User) -> Appointment:
    appointment = get_appointment_by_id(db, appointment_id)
    _assert_is_participant(appointment, user)

    if appointment.status != AppointmentStatus.CONFIRMED:
        raise ConflictError("يمكن إكمال الموعد المؤكَّد فقط")

    appointment.status = AppointmentStatus.COMPLETED
    db.commit()
    db.refresh(appointment)

    other_party_id = appointment.provider_id if user.id == appointment.customer_id else appointment.customer_id
    notification_service.notify_user(
        db,
        user_id=other_party_id,
        notification_type=NotificationType.APPOINTMENT_COMPLETED,
        title="تم إكمال الموعد",
        message=f"تم تحديد الموعد المحدد{_when(appointment.start_time)} كمكتمل",
        related_entity_id=appointment.id,
    )

    return appointment
