"""
Pydantic schemas for ProviderAvailability.

day_of_week uses the same convention as the model: 0=Monday ... 6=Sunday
(Python's datetime.weekday()). This is restated here in the schema, not
just the model, because it's the contract boundary the Flutter client
actually has to get right.
"""
from datetime import date, time

from pydantic import BaseModel, ConfigDict, Field, model_validator


class ProviderAvailabilityCreateRequest(BaseModel):
    day_of_week: int = Field(ge=0, le=6, description="0=Monday ... 6=Sunday")
    start_time: time
    end_time: time

    @model_validator(mode="after")
    def end_after_start(self) -> "ProviderAvailabilityCreateRequest":
        if self.end_time <= self.start_time:
            raise ValueError("يجب أن يكون وقت النهاية بعد وقت البداية")
        return self


class ProviderAvailabilityResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    day_of_week: int
    start_time: time
    end_time: time
    is_active: bool


class SlotResponse(BaseModel):
    """One bookable hour in a provider's day. `is_booked` slots are taken
    already (by a pending or confirmed appointment); who took them is never
    exposed."""
    start_time: time
    end_time: time
    is_booked: bool


class DaySlotsResponse(BaseModel):
    day: date
    day_of_week: int = Field(description="0=Monday ... 6=Sunday")
    slots: list[SlotResponse]
