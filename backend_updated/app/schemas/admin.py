"""
Pydantic schemas for admin-only endpoints.

AdminUserResponse is deliberately distinct from the regular UserResponse/
UserPublicResponse in app/schemas/user.py: admins need to see everything
(email, role, is_active) about ANY user, not just their own account or a
stranger's public profile slice.
"""
from datetime import datetime
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, ConfigDict, EmailStr

from app.models.service import ServiceStatus
from app.models.user import UserRole
from app.schemas.user import UserProfileResponse


class AdminUserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: EmailStr
    role: UserRole
    is_provider: bool
    is_active: bool
    created_at: datetime
    profile: Optional[UserProfileResponse] = None


class AdminSetUserActiveRequest(BaseModel):
    is_active: bool


class AdminSetUserRoleRequest(BaseModel):
    role: UserRole


class AdminServiceResponse(BaseModel):
    """Slim service view for the admin moderation list — avoids over-fetching full nested objects."""
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: Optional[str] = None
    display_title: str
    price: Optional[Decimal] = None
    status: ServiceStatus
    provider_id: int
    category_id: int
    created_at: datetime


class AdminSetServiceStatusRequest(BaseModel):
    status: ServiceStatus


class PlatformStatsResponse(BaseModel):
    total_users: int
    total_providers: int
    active_services: int
    total_appointments: int
    completed_appointments: int
    total_reviews: int
    average_platform_rating: float
