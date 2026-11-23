"""
Pydantic schemas for Notification and PushDevice.
"""
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.models.notification import NotificationType


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    type: NotificationType
    title: str
    message: str
    related_entity_id: Optional[int] = None
    is_read: bool
    created_at: datetime


class UnreadCountResponse(BaseModel):
    unread_count: int


class PushDeviceRegisterRequest(BaseModel):
    fcm_token: str = Field(min_length=10, max_length=500)
    device_label: Optional[str] = Field(default=None, max_length=100)


class PushDeviceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    device_label: Optional[str] = None
    is_active: bool
    created_at: datetime
