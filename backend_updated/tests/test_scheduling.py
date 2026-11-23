from datetime import datetime, time

import pytest

from app.algorithms.scheduling import (
    find_conflicting_appointments,
    find_matching_availability_window,
    intervals_overlap,
    is_within_availability_window,
)


def dt(h, m=0, day=5):
    return datetime(2026, 10, day, h, m)


# ------------------------------------------------------------- intervals_overlap

@pytest.mark.parametrize(
    "a, b, expected",
    [
        ((10, 11), (10, 11), True),    # identical
        ((10, 12), (11, 13), True),    # partial overlap
        ((9, 13), (10, 11), True),     # one contains the other
        ((10, 11), (9, 13), True),     # ... in the other direction
        ((10, 11), (11, 12), False),   # back-to-back: end is exclusive
        ((11, 12), (10, 11), False),   # back-to-back reversed
        ((8, 9), (14, 15), False),     # far apart
    ],
)
def test_intervals_overlap(a, b, expected):
    assert intervals_overlap(dt(a[0]), dt(a[1]), dt(b[0]), dt(b[1])) is expected


def test_overlap_by_one_minute_counts():
    assert intervals_overlap(dt(10), dt(11, 1), dt(11), dt(12)) is True


# ------------------------------------------------- find_conflicting_appointments

def test_no_existing_appointments_means_free_slot():
    assert find_conflicting_appointments(dt(10), dt(11), []) == []


def test_returns_all_conflicting_ids_not_just_the_first():
    existing = [
        (1, dt(9), dt(10, 30)),   # overlaps
        (2, dt(10, 30), dt(11, 30)),  # overlaps
        (3, dt(12), dt(13)),      # free
    ]
    assert find_conflicting_appointments(dt(10), dt(11), existing) == [1, 2]


def test_back_to_back_appointments_do_not_conflict():
    existing = [(1, dt(9), dt(10)), (2, dt(11), dt(12))]
    assert find_conflicting_appointments(dt(10), dt(11), existing) == []


def test_other_day_never_conflicts():
    existing = [(1, dt(10, day=6), dt(11, day=6))]
    assert find_conflicting_appointments(dt(10), dt(11), existing) == []


# ---------------------------------------------- is_within_availability_window

@pytest.mark.parametrize(
    "start, end, expected",
    [
        (dt(9), dt(17), True),        # exactly the window
        (dt(10), dt(11), True),       # inside
        (dt(8, 59), dt(10), False),   # starts a minute early
        (dt(16), dt(17, 1), False),   # ends a minute late
        (dt(7), dt(8), False),        # entirely before
        (dt(18), dt(19), False),      # entirely after
    ],
)
def test_is_within_availability_window(start, end, expected):
    assert is_within_availability_window(start, end, time(9), time(17)) is expected


def test_request_spanning_midnight_is_rejected():
    start = datetime(2026, 10, 5, 23, 0)
    end = datetime(2026, 10, 6, 1, 0)
    assert is_within_availability_window(start, end, time(0, 0), time(23, 59)) is False


# --------------------------------------------- find_matching_availability_window

def test_returns_day_of_first_fitting_window():
    windows = [(0, time(9), time(12)), (0, time(13), time(17))]
    assert find_matching_availability_window(dt(14), dt(15), windows) == 0


def test_returns_none_when_request_straddles_a_gap():
    windows = [(0, time(9), time(12)), (0, time(13), time(17))]
    assert find_matching_availability_window(dt(11), dt(14), windows) is None


def test_returns_none_for_empty_windows():
    assert find_matching_availability_window(dt(10), dt(11), []) is None
