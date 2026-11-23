"""
The `ex_appointment_no_overlap` EXCLUDE USING gist constraint, tested
directly against PostgreSQL. Rows are inserted through the ORM with NO
application-level checks, so what is being proven is the database itself.
"""
import pytest

from app.models import AppointmentStatus as S

from .helpers import CHECK_VIOLATION, EXCLUSION_VIOLATION, at, book, expect_db_error

CONSTRAINT = "ex_appointment_no_overlap"


def overlap_error(session):
    return expect_db_error(session, pgcode=EXCLUSION_VIOLATION, constraint=CONSTRAINT)


# Existing booking is always 10:00-11:00 (UTC).
@pytest.mark.parametrize(
    "start,end",
    [
        pytest.param(at(10), at(11), id="identical"),
        pytest.param(at(10, 30), at(11, 30), id="starts-inside"),
        pytest.param(at(9, 30), at(10, 30), id="ends-inside"),
        pytest.param(at(10, 15), at(10, 45), id="fully-inside"),
        pytest.param(at(9), at(12), id="fully-containing"),
        pytest.param(at(10, 59), at(12), id="one-minute-overlap-at-end"),
        pytest.param(at(9), at(10, 1), id="one-minute-overlap-at-start"),
    ],
)
def test_overlapping_booking_for_same_provider_is_rejected(world, start, end):
    s = world.session
    book(s, world.customer, world.service, at(10), at(11))

    with overlap_error(s):
        book(s, world.other_customer, world.service, start, end)


def test_back_to_back_bookings_are_allowed(world):
    """Range is half-open '[)': 10-11 followed by 11-12 (and 9-10) must not conflict."""
    s = world.session
    book(s, world.customer, world.service, at(10), at(11))
    book(s, world.customer, world.service, at(11), at(12))
    book(s, world.customer, world.service, at(9), at(10))


def test_overlap_is_checked_across_all_of_a_providers_services(world):
    """The whole reason provider_id is denormalised onto appointments."""
    s = world.session
    book(s, world.customer, world.service, at(10), at(11))

    with overlap_error(s):
        book(s, world.other_customer, world.second_service, at(10, 30), at(11, 30))


def test_same_slot_for_different_providers_is_allowed(world):
    s = world.session
    book(s, world.customer, world.service, at(10), at(11))
    book(s, world.customer, world.other_service, at(10), at(11))


def test_same_slot_on_different_days_is_allowed(world):
    s = world.session
    book(s, world.customer, world.service, at(10, day=7), at(11, day=7))
    book(s, world.customer, world.service, at(10, day=8), at(11, day=8))


@pytest.mark.parametrize("blocking", [S.PENDING, S.CONFIRMED, S.COMPLETED])
def test_active_statuses_hold_the_slot(world, blocking):
    s = world.session
    book(s, world.customer, world.service, at(10), at(11), status=blocking)

    with overlap_error(s):
        book(s, world.other_customer, world.service, at(10), at(11))


@pytest.mark.parametrize("freeing", [S.CANCELLED, S.REJECTED])
def test_cancelled_and_rejected_free_the_slot(world, freeing):
    s = world.session
    book(s, world.customer, world.service, at(10), at(11), status=freeing)

    book(s, world.other_customer, world.service, at(10), at(11))  # must not raise


def test_cancelling_an_existing_booking_frees_the_slot(world):
    s = world.session
    first = book(s, world.customer, world.service, at(10), at(11))

    first.status = S.CANCELLED
    s.commit()

    book(s, world.other_customer, world.service, at(10), at(11))


def test_rejecting_a_pending_booking_frees_the_slot(world):
    s = world.session
    first = book(s, world.customer, world.service, at(10), at(11), status=S.PENDING)

    first.status = S.REJECTED
    s.commit()

    book(s, world.other_customer, world.service, at(10), at(11))


def test_reactivating_a_cancelled_booking_into_a_taken_slot_is_rejected(world):
    """The constraint also guards UPDATE, not just INSERT."""
    s = world.session
    old = book(s, world.customer, world.service, at(10), at(11), status=S.CANCELLED)
    book(s, world.other_customer, world.service, at(10), at(11))  # someone took the slot

    old.status = S.PENDING
    with overlap_error(s):
        s.commit()


def test_moving_a_booking_onto_another_one_is_rejected(world):
    s = world.session
    book(s, world.customer, world.service, at(10), at(11))
    movable = book(s, world.other_customer, world.service, at(14), at(15))

    movable.start_time, movable.end_time = at(10, 30), at(11, 30)
    with overlap_error(s):
        s.commit()


def test_accepting_a_pending_booking_does_not_conflict_with_itself(world):
    s = world.session
    appt = book(s, world.customer, world.service, at(10), at(11), status=S.PENDING)

    appt.status = S.CONFIRMED
    s.commit()  # must not raise

    appt.status = S.COMPLETED
    s.commit()


def test_overlap_is_computed_on_absolute_instants_not_wall_clock(world):
    """
    The constraint uses tstzrange (not tsrange). 10:00-11:00 at +02:00 is the
    same instant as 08:00-09:00 UTC, so it must collide with that booking.
    """
    from datetime import timedelta, timezone

    plus2 = timezone(timedelta(hours=2))
    s = world.session
    book(s, world.customer, world.service, at(8), at(9))  # 08:00-09:00 UTC

    with overlap_error(s):
        book(s, world.other_customer, world.service, at(10, tz=plus2), at(11, tz=plus2))


def test_adjacent_instants_in_a_different_timezone_are_allowed(world):
    from datetime import timedelta, timezone

    plus2 = timezone(timedelta(hours=2))
    s = world.session
    book(s, world.customer, world.service, at(8), at(9))  # 08:00-09:00 UTC

    # 09:00-10:00 at +02:00 == 07:00-08:00 UTC -> ends exactly when the other starts
    book(s, world.other_customer, world.service, at(9, tz=plus2), at(10, tz=plus2))


@pytest.mark.parametrize(
    "start,end",
    [pytest.param(at(10), at(10), id="zero-length"), pytest.param(at(11), at(10), id="negative")],
)
def test_end_must_be_after_start_at_db_level(world, start, end):
    with expect_db_error(world.session, pgcode=CHECK_VIOLATION, constraint="ck_appointment_end_after_start"):
        book(world.session, world.customer, world.service, start, end)
