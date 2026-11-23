"""
Service-layer tests for booking. The DB session is a MagicMock and the
notification layer is replaced with a recorder, so we test the BUSINESS RULES
(who may do what, which state transitions are legal, who gets notified)
without needing PostgreSQL.
"""
from datetime import datetime, time
from types import SimpleNamespace

import pytest

from app.core.exceptions import ConflictError, PermissionDeniedError, ValidationError
from app.models.appointment import Appointment, AppointmentStatus
from app.models.notification import NotificationType
from app.models.user import UserRole
from app.schemas.appointment import AppointmentCreateRequest
from app.services import appointment_service as svc

CUSTOMER_ID, PROVIDER_ID, OUTSIDER_ID = 1, 2, 3


@pytest.fixture
def notifications(monkeypatch):
    sent = []

    def fake_notify(db, **kwargs):
        sent.append(kwargs)

    monkeypatch.setattr(svc.notification_service, "notify_user", fake_notify)
    return sent


def appointment(status=AppointmentStatus.PENDING):
    return SimpleNamespace(
        id=50,
        customer_id=CUSTOMER_ID,
        provider_id=PROVIDER_ID,
        status=status,
        start_time=datetime(2026, 10, 5, 10, 0),
        end_time=datetime(2026, 10, 5, 11, 0),
        cancellation_reason=None,
    )


@pytest.fixture
def stored(monkeypatch):
    """Makes get_appointment_by_id return a controllable fake row."""

    def _install(appt):
        monkeypatch.setattr(svc, "get_appointment_by_id", lambda db, appointment_id: appt)
        return appt

    return _install


def user(id, role=UserRole.USER):
    return SimpleNamespace(id=id, role=role, profile=SimpleNamespace(full_name="Someone"))


# ================================================================= accept / reject

def test_provider_accepts_pending_appointment(db, stored, notifications):
    appt = stored(appointment())
    svc.accept_appointment(db, 50, user(PROVIDER_ID))

    assert appt.status == AppointmentStatus.CONFIRMED
    assert notifications[0]["user_id"] == CUSTOMER_ID
    assert notifications[0]["notification_type"] == NotificationType.APPOINTMENT_ACCEPTED


@pytest.mark.parametrize("who", [CUSTOMER_ID, OUTSIDER_ID])
def test_only_the_provider_can_accept(db, stored, notifications, who):
    appt = stored(appointment())
    with pytest.raises(PermissionDeniedError):
        svc.accept_appointment(db, 50, user(who))
    assert appt.status == AppointmentStatus.PENDING
    assert notifications == []


@pytest.mark.parametrize(
    "status",
    [AppointmentStatus.CONFIRMED, AppointmentStatus.REJECTED,
     AppointmentStatus.CANCELLED, AppointmentStatus.COMPLETED],
)
def test_only_pending_can_be_accepted(db, stored, notifications, status):
    stored(appointment(status))
    with pytest.raises(ConflictError):
        svc.accept_appointment(db, 50, user(PROVIDER_ID))


def test_provider_rejects_with_reason(db, stored, notifications):
    appt = stored(appointment())
    svc.reject_appointment(db, 50, user(PROVIDER_ID), "Fully booked")

    assert appt.status == AppointmentStatus.REJECTED
    assert appt.cancellation_reason == "Fully booked"
    assert notifications[0]["user_id"] == CUSTOMER_ID
    assert "Fully booked" in notifications[0]["message"]


def test_customer_cannot_reject(db, stored, notifications):
    stored(appointment())
    with pytest.raises(PermissionDeniedError):
        svc.reject_appointment(db, 50, user(CUSTOMER_ID), None)


def test_cannot_reject_a_confirmed_appointment(db, stored, notifications):
    stored(appointment(AppointmentStatus.CONFIRMED))
    with pytest.raises(ConflictError):
        svc.reject_appointment(db, 50, user(PROVIDER_ID), None)


# ======================================================================= cancel

def test_customer_cancels_and_provider_is_notified(db, stored, notifications):
    appt = stored(appointment(AppointmentStatus.CONFIRMED))
    svc.cancel_appointment(db, 50, user(CUSTOMER_ID), "Changed my mind")

    assert appt.status == AppointmentStatus.CANCELLED
    assert appt.cancellation_reason == "Changed my mind"
    assert notifications[0]["user_id"] == PROVIDER_ID
    assert notifications[0]["notification_type"] == NotificationType.APPOINTMENT_CANCELLED


def test_provider_cancels_and_customer_is_notified(db, stored, notifications):
    stored(appointment(AppointmentStatus.PENDING))
    svc.cancel_appointment(db, 50, user(PROVIDER_ID), None)
    assert notifications[0]["user_id"] == CUSTOMER_ID


def test_outsider_cannot_cancel(db, stored, notifications):
    appt = stored(appointment())
    with pytest.raises(PermissionDeniedError):
        svc.cancel_appointment(db, 50, user(OUTSIDER_ID), None)
    assert appt.status == AppointmentStatus.PENDING


def test_admin_can_cancel_any_appointment(db, stored, notifications):
    appt = stored(appointment())
    svc.cancel_appointment(db, 50, user(OUTSIDER_ID, role=UserRole.ADMIN), "policy")
    assert appt.status == AppointmentStatus.CANCELLED


@pytest.mark.parametrize(
    "status",
    [AppointmentStatus.CANCELLED, AppointmentStatus.REJECTED, AppointmentStatus.COMPLETED],
)
def test_finished_appointments_cannot_be_cancelled(db, stored, notifications, status):
    stored(appointment(status))
    with pytest.raises(ConflictError):
        svc.cancel_appointment(db, 50, user(CUSTOMER_ID), None)


# ===================================================================== complete

def test_confirmed_appointment_can_be_completed(db, stored, notifications):
    appt = stored(appointment(AppointmentStatus.CONFIRMED))
    svc.mark_appointment_completed(db, 50, user(PROVIDER_ID))

    assert appt.status == AppointmentStatus.COMPLETED
    assert notifications[0]["user_id"] == CUSTOMER_ID
    assert notifications[0]["notification_type"] == NotificationType.APPOINTMENT_COMPLETED


@pytest.mark.parametrize(
    "status",
    [AppointmentStatus.PENDING, AppointmentStatus.REJECTED,
     AppointmentStatus.CANCELLED, AppointmentStatus.COMPLETED],
)
def test_only_confirmed_can_be_completed(db, stored, notifications, status):
    stored(appointment(status))
    with pytest.raises(ConflictError):
        svc.mark_appointment_completed(db, 50, user(PROVIDER_ID))


def test_outsider_cannot_complete(db, stored, notifications):
    stored(appointment(AppointmentStatus.CONFIRMED))
    with pytest.raises(PermissionDeniedError):
        svc.mark_appointment_completed(db, 50, user(OUTSIDER_ID))


# ============================================================ participant access

def test_participants_and_admin_may_view(db, stored):
    stored(appointment())
    assert svc.get_appointment_for_user(db, 50, user(CUSTOMER_ID))
    assert svc.get_appointment_for_user(db, 50, user(PROVIDER_ID))
    assert svc.get_appointment_for_user(db, 50, user(OUTSIDER_ID, role=UserRole.ADMIN))


def test_outsider_may_not_view(db, stored):
    stored(appointment())
    with pytest.raises(PermissionDeniedError):
        svc.get_appointment_for_user(db, 50, user(OUTSIDER_ID))


# ============================================================ availability check

def _windows(db, rows):
    db.execute.return_value.scalars.return_value.all.return_value = rows


def window(start=9, end=17, day=0):
    return SimpleNamespace(day_of_week=day, start_time=time(start), end_time=time(end))


def test_no_availability_for_that_day(db):
    _windows(db, [])
    with pytest.raises(ValidationError, match="لم يحدد أوقات توفر"):
        svc._assert_fits_within_availability(
            db, PROVIDER_ID, datetime(2026, 10, 5, 10), datetime(2026, 10, 5, 11)   # a Monday
        )


def test_request_inside_working_hours_passes(db):
    _windows(db, [window()])
    svc._assert_fits_within_availability(
        db, PROVIDER_ID, datetime(2026, 10, 5, 10), datetime(2026, 10, 5, 11)
    )


def test_request_outside_working_hours_fails(db):
    _windows(db, [window()])
    with pytest.raises(ValidationError, match="أوقات عمل"):
        svc._assert_fits_within_availability(
            db, PROVIDER_ID, datetime(2026, 10, 5, 16), datetime(2026, 10, 5, 18)
        )


# ============================================================== conflict check

def test_conflict_with_existing_appointment_is_reported(db):
    db.execute.return_value.all.return_value = [
        (1, datetime(2026, 10, 5, 10, 30), datetime(2026, 10, 5, 11, 30)),
    ]
    with pytest.raises(ConflictError, match="1 موعد"):
        svc._assert_no_conflicts(
            db, PROVIDER_ID, datetime(2026, 10, 5, 10), datetime(2026, 10, 5, 11)
        )


def test_back_to_back_booking_is_allowed(db):
    db.execute.return_value.all.return_value = [
        (1, datetime(2026, 10, 5, 9), datetime(2026, 10, 5, 10)),
    ]
    svc._assert_no_conflicts(
        db, PROVIDER_ID, datetime(2026, 10, 5, 10), datetime(2026, 10, 5, 11)
    )


# ============================================================ create_appointment

def request(**overrides):
    data = dict(
        service_id=7,
        start_time=datetime(2026, 10, 5, 10),
        end_time=datetime(2026, 10, 5, 11),
        customer_notes="hello",
    )
    data.update(overrides)
    return AppointmentCreateRequest(**data)


@pytest.fixture
def a_service(monkeypatch):
    service = SimpleNamespace(id=7, provider_id=PROVIDER_ID, title="Plumbing", display_title="Plumbing")
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, service_id: service)
    return service


def test_cannot_book_your_own_service(db, a_service, notifications):
    with pytest.raises(ValidationError, match="خدمتك الخاصة"):
        svc.create_appointment(db, user(PROVIDER_ID), request())
    db.add.assert_not_called()


def test_booking_fails_on_a_day_the_provider_does_not_work(db, a_service, notifications):
    _windows(db, [])      # the weekday-filtered query finds no window: closed that day
    with pytest.raises(ValidationError, match="لم يحدد أوقات توفر"):
        svc.create_appointment(db, user(CUSTOMER_ID), request())
    db.add.assert_not_called()


def test_successful_booking_is_pending_and_notifies_provider(
    db, a_service, notifications, monkeypatch
):
    monkeypatch.setattr(svc, "_assert_fits_within_availability", lambda *a, **k: None)
    monkeypatch.setattr(svc, "_assert_no_conflicts", lambda *a, **k: None)
    monkeypatch.setattr(svc, "get_appointment_by_id", lambda db, appointment_id: "reloaded")

    result = svc.create_appointment(db, user(CUSTOMER_ID), request())

    created = db.add.call_args.args[0]
    assert isinstance(created, Appointment)
    assert created.status == AppointmentStatus.PENDING
    assert created.customer_id == CUSTOMER_ID
    assert created.provider_id == PROVIDER_ID
    assert created.customer_notes == "hello"
    db.commit.assert_called_once()

    assert notifications[0]["user_id"] == PROVIDER_ID
    assert notifications[0]["notification_type"] == NotificationType.APPOINTMENT_BOOKED
    assert result == "reloaded"


# ====================================================== requests without a day/hour

def remote_service(monkeypatch, is_remote=True):
    service = SimpleNamespace(id=7, provider_id=PROVIDER_ID, title="Plumbing", display_title="Plumbing", is_remote=is_remote)
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, service_id: service)
    monkeypatch.setattr(svc, "get_appointment_by_id", lambda db, appointment_id: appointment())
    return service


def undated(**overrides):
    return request(start_time=None, end_time=None, **overrides)


def no_working_hours(db):
    db.execute.return_value.first.return_value = None


def has_working_hours(db):
    db.execute.return_value.first.return_value = (1,)


def test_a_remote_service_without_working_hours_accepts_a_request_with_no_time(db, monkeypatch, notifications):
    remote_service(monkeypatch)
    no_working_hours(db)

    svc.create_appointment(db, user(CUSTOMER_ID), undated())

    created = db.add.call_args.args[0]
    assert created.start_time is None and created.end_time is None
    assert created.status == AppointmentStatus.PENDING
    assert created.customer_notes == "hello"
    assert "دون تحديد يوم أو ساعة" in notifications[0]["message"]
    assert "بتاريخ" not in notifications[0]["message"]


def test_a_request_with_no_time_skips_the_hours_and_conflict_checks(db, monkeypatch, notifications):
    remote_service(monkeypatch)
    no_working_hours(db)
    monkeypatch.setattr(svc, "_assert_fits_within_availability", lambda *a: pytest.fail("must not run"))
    monkeypatch.setattr(svc, "_assert_no_conflicts", lambda *a: pytest.fail("must not run"))

    svc.create_appointment(db, user(CUSTOMER_ID), undated())

    db.add.assert_called_once()


def test_a_service_that_is_not_remote_always_needs_a_time(db, monkeypatch, notifications):
    remote_service(monkeypatch, is_remote=False)
    no_working_hours(db)

    with pytest.raises(ValidationError, match="اختيار اليوم والساعة"):
        svc.create_appointment(db, user(CUSTOMER_ID), undated())
    db.add.assert_not_called()


def test_a_remote_service_whose_provider_set_hours_needs_a_time(db, monkeypatch, notifications):
    remote_service(monkeypatch)
    has_working_hours(db)

    with pytest.raises(ValidationError, match="حدّد مزوّد الخدمة أيام دوام"):
        svc.create_appointment(db, user(CUSTOMER_ID), undated())
    db.add.assert_not_called()


def test_you_still_cannot_book_your_own_remote_service_without_a_time(db, monkeypatch, notifications):
    remote_service(monkeypatch)
    with pytest.raises(ValidationError, match="خدمتك الخاصة"):
        svc.create_appointment(db, user(PROVIDER_ID), undated())


def undated_appointment(status):
    appt = appointment(status)
    appt.start_time = None
    appt.end_time = None
    return appt


@pytest.mark.parametrize(
    "status, action, who, expected",
    [
        (AppointmentStatus.PENDING, svc.accept_appointment, PROVIDER_ID, "تم قبول حجزك"),
        (AppointmentStatus.CONFIRMED, svc.mark_appointment_completed, PROVIDER_ID, "تم تحديد الموعد المحدد كمكتمل"),
    ],
)
def test_notifications_for_a_request_without_time_have_no_date(db, stored, notifications, status, action, who, expected):
    stored(undated_appointment(status))
    action(db, 50, user(who))
    assert notifications[0]["message"] == expected


def test_rejecting_and_cancelling_a_request_without_time_work(db, stored, notifications):
    stored(undated_appointment(AppointmentStatus.PENDING))
    svc.reject_appointment(db, 50, user(PROVIDER_ID), None)
    assert notifications[0]["message"] == "تم رفض حجزك"

    stored(undated_appointment(AppointmentStatus.PENDING))
    svc.cancel_appointment(db, 50, user(CUSTOMER_ID), None)
    assert notifications[1]["message"] == "تم إلغاء الموعد المحدد"


def test_my_appointments_are_ordered_with_undated_ones_by_creation_time(db):
    db.execute.return_value.scalars.return_value.all.return_value = []
    svc.list_my_appointments(db, user(CUSTOMER_ID))

    sql = str(db.execute.call_args.args[0]).lower()
    assert "coalesce" in sql and "created_at" in sql
