from datetime import datetime

import pytest
from pydantic import ValidationError as PydanticValidationError

from app.core.constants import CITIES
from app.schemas.appointment import AppointmentCreateRequest
from app.schemas.user import (
    UserLocationUpdateRequest,
    UserProfileUpdateRequest,
    UserRegisterRequest,
)


def valid_registration(**overrides):
    data = {
        "email": "ahmad@example.com",
        "password": "Secret123!",
        "full_name": "Ahmad Ali",
        "city": "دمشق",
    }
    data.update(overrides)
    return data


# ----------------------------------------------------------------- registration

def test_valid_registration_is_accepted():
    req = UserRegisterRequest(**valid_registration())
    assert req.phone_number is None


@pytest.mark.parametrize(
    "override",
    [
        {"email": "not-an-email"},
        {"password": "short7!"},          # 7 chars < min 8
        {"password": "x" * 129},          # > max 128
        {"full_name": "A"},               # < min 2
        {"city": "X"},                    # < min 2
        {"phone_number": "1" * 31},       # > max 30
    ],
)
def test_invalid_registration_is_rejected(override):
    with pytest.raises(PydanticValidationError):
        UserRegisterRequest(**valid_registration(**override))


def test_city_is_required():
    data = valid_registration()
    del data["city"]
    with pytest.raises(PydanticValidationError):
        UserRegisterRequest(**data)


def test_client_cannot_set_role_or_is_active_on_registration():
    req = UserRegisterRequest(**valid_registration(role="admin", is_active=False))
    dumped = req.model_dump()
    assert "role" not in dumped and "is_active" not in dumped


# ---------------------------------------------------------------------- profile

def test_profile_update_is_partial():
    req = UserProfileUpdateRequest(bio="hello")
    assert req.model_dump(exclude_unset=True) == {"bio": "hello"}


def test_profile_update_still_validates_fields():
    with pytest.raises(PydanticValidationError):
        UserProfileUpdateRequest(full_name="A")
    with pytest.raises(PydanticValidationError):
        UserProfileUpdateRequest(bio="x" * 2001)


@pytest.mark.parametrize(
    "lat, lon, ok",
    [
        (0, 0, True),
        (90, 180, True),
        (-90, -180, True),
        (90.0001, 0, False),
        (-90.0001, 0, False),
        (0, 180.0001, False),
        (0, -180.0001, False),
    ],
)
def test_location_bounds(lat, lon, ok):
    if ok:
        UserLocationUpdateRequest(latitude=lat, longitude=lon)
    else:
        with pytest.raises(PydanticValidationError):
            UserLocationUpdateRequest(latitude=lat, longitude=lon)


# ------------------------------------------------------------------ appointment

def test_appointment_end_must_be_after_start():
    start = datetime(2026, 10, 5, 10, 0)
    with pytest.raises(PydanticValidationError):
        AppointmentCreateRequest(service_id=1, start_time=start, end_time=start)
    with pytest.raises(PydanticValidationError):
        AppointmentCreateRequest(service_id=1, start_time=start, end_time=datetime(2026, 10, 5, 9, 0))


def test_valid_appointment_request():
    req = AppointmentCreateRequest(
        service_id=1,
        start_time=datetime(2026, 10, 5, 10, 0),
        end_time=datetime(2026, 10, 5, 11, 0),
        customer_notes="please bring tools",
    )
    assert req.service_id == 1


def test_appointment_notes_length_limit():
    with pytest.raises(PydanticValidationError):
        AppointmentCreateRequest(
            service_id=1,
            start_time=datetime(2026, 10, 5, 10, 0),
            end_time=datetime(2026, 10, 5, 11, 0),
            customer_notes="x" * 1001,
        )


# -------------------------------------------------------------------- constants

def test_cities_are_unique_and_non_empty():
    assert len(CITIES) == len(set(CITIES)) > 0
    assert "دمشق" in CITIES


def test_an_appointment_request_may_have_no_time_at_all():
    req = AppointmentCreateRequest(service_id=1)
    assert req.start_time is None and req.end_time is None
    assert req.has_time is False


def test_an_appointment_request_needs_both_times_or_none():
    with pytest.raises(PydanticValidationError):
        AppointmentCreateRequest(service_id=1, start_time=datetime(2026, 10, 5, 10, 0))
    with pytest.raises(PydanticValidationError):
        AppointmentCreateRequest(service_id=1, end_time=datetime(2026, 10, 5, 10, 0))


def test_a_complete_appointment_request_reports_it_has_a_time():
    req = AppointmentCreateRequest(
        service_id=1, start_time=datetime(2026, 10, 5, 10, 0), end_time=datetime(2026, 10, 5, 11, 0)
    )
    assert req.has_time is True
