"""Tests for the one-hour slots of a provider's day (GET .../availability/slots)."""
from datetime import date, datetime, time, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from app.algorithms.scheduling import build_day_slots

MONDAY = date(2026, 11, 2)           # a Monday -> day_of_week 0


def utc(hour, minute=0, day=MONDAY):
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=timezone.utc)


def booked_hours(slots):
    return [start.hour for start, _, is_booked in slots if is_booked]


# ------------------------------------------------------------------ algorithm
def test_a_window_is_cut_into_one_hour_slots():
    slots = build_day_slots(MONDAY, [(time(9), time(17))], [])
    assert [(s.hour, e.hour, b) for s, e, b in slots] == [(h, h + 1, False) for h in range(9, 17)]


def test_a_booked_hour_is_marked_and_its_neighbours_stay_free():
    slots = build_day_slots(MONDAY, [(time(9), time(13))], [(utc(11), utc(12))])
    assert booked_hours(slots) == [11]
    assert len(slots) == 4


def test_back_to_back_appointments_do_not_block_the_next_hour():
    slots = build_day_slots(MONDAY, [(time(9), time(13))], [(utc(10), utc(11))])
    assert booked_hours(slots) == [10]


def test_an_off_grid_appointment_blocks_every_slot_it_touches():
    slots = build_day_slots(MONDAY, [(time(9), time(13))], [(utc(10, 30), utc(11, 30))])
    assert booked_hours(slots) == [10, 11]


def test_the_leftover_of_a_window_is_dropped():
    slots = build_day_slots(MONDAY, [(time(9), time(12, 30))], [])
    assert [s.hour for s, _, _ in slots] == [9, 10, 11]


def test_two_windows_give_one_ordered_list_without_duplicates():
    slots = build_day_slots(MONDAY, [(time(14), time(16)), (time(9), time(11)), (time(10), time(12))], [])
    assert [s.hour for s, _, _ in slots] == [9, 10, 11, 14, 15]


def test_no_window_means_no_slots():
    assert build_day_slots(MONDAY, [], [(utc(10), utc(11))]) == []


def test_an_appointment_stored_in_another_timezone_is_compared_as_utc():
    plus_two = timezone(timedelta(hours=2))
    busy = [(datetime(2026, 11, 2, 13, 0, tzinfo=plus_two), datetime(2026, 11, 2, 14, 0, tzinfo=plus_two))]
    # 13:00+02:00 is 11:00 UTC
    assert booked_hours(build_day_slots(MONDAY, [(time(9), time(13))], busy)) == [11]


def test_naive_datetimes_are_taken_as_they_are():
    busy = [(datetime(2026, 11, 2, 9, 0), datetime(2026, 11, 2, 10, 0))]
    assert booked_hours(build_day_slots(MONDAY, [(time(9), time(11))], busy)) == [9]


def test_an_appointment_on_another_day_does_not_matter():
    tomorrow = MONDAY + timedelta(days=1)
    busy = [(utc(10, day=tomorrow), utc(11, day=tomorrow))]
    assert booked_hours(build_day_slots(MONDAY, [(time(9), time(13))], busy)) == []


# ------------------------------------------------------------------ service
from app.services import availability_service  # noqa: E402
from tests.helpers import make_result, where_clause  # noqa: E402


def rows(*pairs):
    return make_result(all=[tuple(pair) for pair in pairs])


def test_the_service_returns_slots_and_marks_the_booked_ones():
    db = MagicMock()
    db.execute.side_effect = [rows((time(9), time(12))), rows((utc(10), utc(11)))]

    result = availability_service.get_day_slots(db, provider_id=5, day=MONDAY)

    assert result.day == MONDAY and result.day_of_week == 0
    assert [(s.start_time.hour, s.is_booked) for s in result.slots] == [(9, False), (10, True), (11, False)]


def test_a_day_without_working_hours_is_empty_and_skips_the_appointments_query():
    db = MagicMock()
    db.execute.side_effect = [rows()]

    result = availability_service.get_day_slots(db, provider_id=5, day=MONDAY)

    assert result.slots == []
    assert db.execute.call_count == 1


def test_the_weekday_follows_the_date():
    db = MagicMock()
    db.execute.side_effect = [rows()]
    assert availability_service.get_day_slots(db, 5, date(2026, 11, 8)).day_of_week == 6   # Sunday


def test_cancelled_and_rejected_appointments_free_their_slot():
    db = MagicMock()
    db.execute.side_effect = [rows((time(9), time(12))), rows()]

    availability_service.get_day_slots(db, provider_id=5, day=MONDAY)

    appointments_query = where_clause(db.execute.call_args_list[1].args[0])
    assert "NOT IN" in appointments_query.upper().replace("\n", " ")
    assert ":provider_id_1" in appointments_query


# ------------------------------------------------------------------ route
from fastapi.testclient import TestClient  # noqa: E402

from app.core.database import get_db  # noqa: E402
from app.main import app  # noqa: E402
from app.schemas.availability import DaySlotsResponse, SlotResponse  # noqa: E402


@pytest.fixture
def client():
    app.dependency_overrides[get_db] = lambda: MagicMock(name="Session")
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def test_the_route_is_public_and_returns_time_strings(client, monkeypatch):
    seen = []

    def fake(db, provider_id, day):
        seen.append((provider_id, day))
        return DaySlotsResponse(
            day=day, day_of_week=0,
            slots=[SlotResponse(start_time=time(9), end_time=time(10), is_booked=True)],
        )

    monkeypatch.setattr(availability_service, "get_day_slots", fake)
    response = client.get("/api/v1/providers/7/availability/slots", params={"day": "2026-11-02"})

    assert response.status_code == 200
    assert response.json() == {
        "day": "2026-11-02",
        "day_of_week": 0,
        "slots": [{"start_time": "09:00:00", "end_time": "10:00:00", "is_booked": True}],
    }
    assert seen == [(7, date(2026, 11, 2))]


def test_a_bad_date_is_rejected(client):
    response = client.get("/api/v1/providers/7/availability/slots", params={"day": "not-a-date"})
    assert response.status_code == 422


def test_the_day_is_required(client):
    assert client.get("/api/v1/providers/7/availability/slots").status_code == 422
