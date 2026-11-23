"""
Pydantic schemas for the User domain.

Kept strictly separate from the SQLAlchemy model: request schemas define
exactly what a client is allowed to send (so nobody can set `role` or
`is_active` from a registration payload), and response schemas define
exactly what gets serialized back (so `hashed_password` can never leak).
"""
import re
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models.user import UserRole

MIN_PASSWORD_LENGTH = 8
MIN_PHONE_DIGITS = 10
_PHONE_ALLOWED_CHARS = re.compile(r"^[0-9+\-\s()]+$")


def validate_password_strength(value: str) -> str:
    """Password rule: at least 8 characters."""
    if len(value) < MIN_PASSWORD_LENGTH:
        raise ValueError("كلمة المرور يجب أن تتكون من 8 أحرف على الأقل")
    return value


def validate_phone_number(value: Optional[str]) -> Optional[str]:
    """
    Phone rule: at least 10 digits. Spaces, dashes, parentheses and a leading
    '+' are allowed. Empty/None is accepted here (the field is optional on the
    API; the mobile app makes it mandatory on the register form).
    """
    if value is None:
        return value
    cleaned = value.strip()
    if cleaned == "":
        return cleaned
    if not _PHONE_ALLOWED_CHARS.match(cleaned):
        raise ValueError("رقم الجوال يجب أن يحتوي على أرقام فقط")
    if len(re.sub(r"\D", "", cleaned)) < MIN_PHONE_DIGITS:
        raise ValueError("رقم الجوال يجب أن يتكون من 10 أرقام على الأقل")
    return cleaned


# --------------------------------------------------------------------------
# Auth: register / login / tokens
# --------------------------------------------------------------------------

class UserRegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=2, max_length=150)
    phone_number: Optional[str] = Field(default=None, max_length=30)
    # Required at registration: every user must pick a city from the fixed
    # list (GET /api/v1/cities) so the app can immediately show them
    # city-filtered search results without an extra "set your city" step.
    city: str = Field(min_length=2, max_length=100)

    @field_validator("password")
    @classmethod
    def _check_password(cls, value: str) -> str:
        return validate_password_strength(value)

    @field_validator("phone_number")
    @classmethod
    def _check_phone(cls, value: Optional[str]) -> Optional[str]:
        return validate_phone_number(value)


class UserLoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshTokenRequest(BaseModel):
    refresh_token: str


class ForgotPasswordRequest(BaseModel):
    """Step 1 of password recovery: ask for a reset code by email."""
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    """Step 2: submit the emailed code together with the new password."""
    email: EmailStr
    code: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")
    new_password: str = Field(min_length=8, max_length=128)

    @field_validator("new_password")
    @classmethod
    def _check_password(cls, value: str) -> str:
        return validate_password_strength(value)


class MessageResponse(BaseModel):
    message: str


# --------------------------------------------------------------------------
# Profile
# --------------------------------------------------------------------------

class UserProfileBase(BaseModel):
    full_name: str = Field(min_length=2, max_length=150)
    phone_number: Optional[str] = Field(default=None, max_length=30)
    bio: Optional[str] = Field(default=None, max_length=2000)
    avatar_url: Optional[str] = Field(default=None, max_length=500)
    address_label: Optional[str] = Field(default=None, max_length=255)
    city: Optional[str] = Field(default=None, max_length=100)


class UserProfileUpdateRequest(BaseModel):
    """All fields optional: a PATCH-style partial update."""
    full_name: Optional[str] = Field(default=None, min_length=2, max_length=150)
    phone_number: Optional[str] = Field(default=None, max_length=30)
    bio: Optional[str] = Field(default=None, max_length=2000)
    avatar_url: Optional[str] = Field(default=None, max_length=500)
    address_label: Optional[str] = Field(default=None, max_length=255)
    # Lets a user change their city later from the profile/settings screen
    # (validated against app.core.constants.CITIES in user_service).
    city: Optional[str] = Field(default=None, max_length=100)

    @field_validator("phone_number")
    @classmethod
    def _check_phone(cls, value: Optional[str]) -> Optional[str]:
        return validate_phone_number(value)


class UserLocationUpdateRequest(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    address_label: Optional[str] = Field(default=None, max_length=255)


class UserProfileResponse(UserProfileBase):
    model_config = ConfigDict(from_attributes=True)

    latitude: Optional[float] = None
    longitude: Optional[float] = None


# --------------------------------------------------------------------------
# User (combined view)
# --------------------------------------------------------------------------

class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: EmailStr
    role: UserRole
    is_provider: bool
    is_active: bool
    created_at: datetime
    profile: Optional[UserProfileResponse] = None


class UserPublicResponse(BaseModel):
    """
    Slimmed-down public view of a user, used when exposing provider info
    on services/reviews/search results — never includes email or role.
    """
    model_config = ConfigDict(from_attributes=True)

    id: int
    is_provider: bool
    profile: Optional[UserProfileResponse] = None


class ProviderToggleRequest(BaseModel):
    is_provider: bool
