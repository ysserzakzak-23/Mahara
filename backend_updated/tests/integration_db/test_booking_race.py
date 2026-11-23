"""
Race condition: two customers book the same slot at the same moment.

Both requests pass the application-level availability/conflict check (each
sees an empty calendar) BEFORE either inserts. A threading.Barrier placed
right after that check makes the race deterministic instead of "hoping" the
threads interleave. Only the database constraint can save us here.
"""
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import time

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from app.core.exceptions import ConflictError
from app.models import AppointmentStatus, ProviderAvailability, User
from app.schemas.appointment import AppointmentCreateRequest
from app.services import appointment_service

from .helpers import at, book, new_session

ACTIVE_COUNT_SQL = text(
    "SELECT count(*) FROM appointments "
    "WHERE provider_id = :pid AND status NOT IN ('cancelled', 'rejected')"
)


@pytest.fixture
def bookable(world):
    """Provider works Mondays 09:00-17:00; 2030-01-07 is a Monday."""
    world.session.add(
        ProviderAvailability(provider_id=world.provider.id, day_of_week=0, start_time=time(9), end_time=time(17))
    )
    world.session.commit()
    return world


def _payload(service_id: int) -> AppointmentCreateRequest:
    return AppointmentCreateRequest(service_id=service_id, start_time=at(10), end_time=at(11))


def _run_race(engine, monkeypatch, world):
    barrier = threading.Barrier(2, timeout=20)
    original = appointment_service._assert_no_conflicts

    def check_then_wait(db, provider_id, start, end):
        original(db, provider_id, start, end)  # both threads see a free calendar...
        barrier.wait()                         # ...and only then do either of them insert

    monkeypatch.setattr(appointment_service, "_assert_no_conflicts", check_then_wait)

    def attempt(customer_id: int):
        s = new_session(engine)
        try:
            customer = s.get(User, customer_id)
            appt = appointment_service.create_appointment(s, customer, _payload(world.service.id))
            return ("ok", appt.id)
        except Exception as exc:  # noqa: BLE001 - we inspect the type below
            s.rollback()
            return ("error", exc)
        finally:
            s.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(attempt, [world.customer.id, world.other_customer.id]))


def test_race_never_double_books_the_slot(db_engine, monkeypatch, bookable):
    results = _run_race(db_engine, monkeypatch, bookable)

    winners = [r for r in results if r[0] == "ok"]
    losers = [r for r in results if r[0] == "error"]
    assert len(winners) == 1, results
    assert len(losers) == 1, results
    assert isinstance(losers[0][1], (IntegrityError, ConflictError)), losers[0][1]

    with db_engine.connect() as conn:
        assert conn.execute(ACTIVE_COUNT_SQL, {"pid": bookable.provider.id}).scalar() == 1


def test_race_loser_gets_a_clean_409_not_a_500(db_engine, monkeypatch, bookable):
    """
    FAILS until create_appointment() translates the database's
    IntegrityError into ConflictError (see the fix in the chat message).
    As written, the loser of a real race gets an unhandled exception,
    i.e. HTTP 500 "An unexpected error occurred".
    """
    results = _run_race(db_engine, monkeypatch, bookable)

    loser = next(r[1] for r in results if r[0] == "error")
    assert isinstance(loser, ConflictError), f"got {type(loser).__name__}: {loser}"


def test_sequential_double_booking_gets_friendly_app_level_error(bookable):
    s = bookable.session
    appointment_service.create_appointment(s, bookable.customer, _payload(bookable.service.id))

    with pytest.raises(ConflictError):
        appointment_service.create_appointment(s, bookable.other_customer, _payload(bookable.service.id))


def test_slot_can_be_rebooked_after_cancellation(bookable):
    s = bookable.session
    first = appointment_service.create_appointment(s, bookable.customer, _payload(bookable.service.id))

    row = s.get(type(first), first.id)
    row.status = AppointmentStatus.CANCELLED
    s.commit()

    appointment_service.create_appointment(s, bookable.other_customer, _payload(bookable.service.id))
