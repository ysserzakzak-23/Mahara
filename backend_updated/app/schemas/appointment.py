"""
Pydantic schemas for the Appointment domain.
"""
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.appointment import AppointmentStatus
from app.schemas.user import UserPublicResponse


class AppointmentCreateRequest(BaseModel):
    service_id: int
    # Both omitted = a request without a day/hour: allowed only for a remote
    # service whose provider has set no working hours (see appointment_service).
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None
    customer_notes: Optional[str] = Field(default=None, max_length=1000)

    @model_validator(mode="after")
    def times_are_consistent(self) -> "AppointmentCreateRequest":
        if (self.start_time is None) != (self.end_time is None):
            raise ValueError("يجب تحديد وقت البداية ووقت النهاية معاً أو تركهما فارغين")
        if self.start_time is not None and self.end_time <= self.start_time:
            raise ValueError("يجب أن يكون وقت النهاية بعد وقت البداية")
        return self

    @property
    def has_time(self) -> bool:
        return self.start_time is not None


class AppointmentCancelRequest(BaseModel):
    cancellation_reason: Optional[str] = Field(default=None, max_length=500)


class AppointmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    service_id: int
    service_title: str
    start_time: Optional[datetime]   # None: no day/hour was chosen (see create request)
    end_time: Optional[datetime]
    status: AppointmentStatus
    customer_notes: Optional[str] = None
    cancellation_reason: Optional[str] = None
    created_at: datetime

    customer: UserPublicResponse
    provider: UserPublicResponse
