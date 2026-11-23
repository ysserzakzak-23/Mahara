"""
Scheduling algorithms: interval overlap detection and availability-window
containment checks.

Kept as pure functions with no DB dependency so they're trivially unit
testable and reusable (the application-layer check in
appointment_service.py calls these against data it has already fetched;
no algorithm here queries the database itself).
"""
from datetime import date, datetime, time, timedelta, timezone


def intervals_overlap(start_a: datetime, end_a: datetime, start_b: datetime, end_b: datetime) -> bool:
    """
    Returns True if half-open intervals [start_a, end_a) and [start_b, end_b)
    overlap at all.

    This is the standard interval-overlap test: two ranges overlap if and
    only if each one starts before the other ends. Using half-open
    intervals (end is exclusive) means back-to-back bookings — one ending
    exactly when the next begins, e.g. 10:00-11:00 followed by 11:00-12:00 —
    are correctly treated as NON-overlapping, which matches how real-world
    scheduling works.
    """
    return start_a < end_b and start_b < end_a


def find_conflicting_appointments(
    new_start: datetime,
    new_end: datetime,
    existing_appointments: list[tuple[int, datetime, datetime]],
) -> list[int]:
    """
    Given a candidate [new_start, new_end) range and a list of
    (appointment_id, start, end) tuples representing a provider's existing
    CONFIRMED appointments, returns the IDs of every one that overlaps the
    candidate range.

    An empty list means the slot is free. Returning ALL conflicts (not just
    the first one found) lets the caller report a complete, useful error
    message rather than "something conflicts, try again and find out which."
    """
    return [
        appointment_id
        for appointment_id, existing_start, existing_end in existing_appointments
        if intervals_overlap(new_start, new_end, existing_start, existing_end)
    ]


def is_within_availability_window(
    requested_start: datetime, requested_end: datetime, window_start: time, window_end: time
) -> bool:
    """
    Returns True if the requested [start, end) datetime range falls
    entirely within a single day's [window_start, window_end) time-of-day
    window, on the SAME calendar day.

    Deliberately does not support appointments that span midnight (e.g.
    23:00-01:00) — a provider's availability window is itself scoped to
    one weekday with a same-day start/end (enforced by the
    ck_availability_end_after_start DB constraint), so a request that
    crosses midnight could never fit within a single window anyway. This
    is a reasonable scope boundary for a local service marketplace, where
    appointments are realistically booked within ordinary daytime hours.
    """
    if requested_start.date() != requested_end.date():
        return False

    return (
        requested_start.time() >= window_start
        and requested_end.time() <= window_end
    )


def find_matching_availability_window(
    requested_start: datetime,
    requested_end: datetime,
    windows: list[tuple[int, time, time]],
) -> int | None:
    """
    Given a list of (day_of_week, window_start, window_end) tuples for the
    requested weekday, returns the day_of_week of the first window the
    request fits entirely within, or None if no window accommodates it.

    Callers are expected to have already filtered `windows` down to the
    correct day_of_week for requested_start (see appointment_service.py),
    since a request can only ever be validated against windows for the
    single weekday it falls on.
    """
    for day_of_week, window_start, window_end in windows:
        if is_within_availability_window(requested_start, requested_end, window_start, window_end):
            return day_of_week
    return None


# Every booking in the app is exactly one hour long.
SLOT_MINUTES = 60


def _as_naive_utc(value: datetime) -> datetime:
    """Appointments are stored as UTC instants whose clock numbers are the
    wall-clock time the customer picked (see the notes in appointment_service
    / the Flutter booking screen). Compare them on that same clock."""
    if value.tzinfo is not None:
        return value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def build_day_slots(
    day: date,
    windows: list[tuple[time, time]],
    busy: list[tuple[datetime, datetime]],
    slot_minutes: int = SLOT_MINUTES,
) -> list[tuple[time, time, bool]]:
    """
    Cuts a provider's working windows for `day` into back-to-back slots of
    `slot_minutes` and marks which of them are already taken.

    Returns [(slot_start, slot_end, is_booked)] ordered by start time.
    A window that is not a whole number of slots simply loses the remainder
    (09:00-12:30 gives 09-10, 10-11, 11-12). Overlapping windows never
    produce the same slot twice. `busy` holds the provider's existing
    [start, end) appointments (the caller leaves out cancelled / rejected
    ones, since those free the time up).
    """
    step = timedelta(minutes=slot_minutes)
    slots: dict[time, tuple[datetime, datetime]] = {}
    for window_start, window_end in sorted(windows):
        current = datetime.combine(day, window_start)
        limit = datetime.combine(day, window_end)
        while current + step <= limit:
            slots.setdefault(current.time(), (current, current + step))
            current += step

    taken = [(_as_naive_utc(start), _as_naive_utc(end)) for start, end in busy]
    result: list[tuple[time, time, bool]] = []
    for start_time in sorted(slots):
        slot_start, slot_end = slots[start_time]
        is_booked = any(intervals_overlap(slot_start, slot_end, b_start, b_end) for b_start, b_end in taken)
        result.append((slot_start.time(), slot_end.time(), is_booked))
    return result
