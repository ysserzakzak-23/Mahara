"""
User service layer: registration, authentication, and profile management.

Routers should contain no business logic — they parse the request,
delegate to these functions, and serialize the result. This keeps the
logic here unit-testable without spinning up FastAPI or HTTP at all.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.constants import CITIES
from app.core.exceptions import ConflictError, InvalidCredentialsError, NotFoundError, ValidationError
from app.core.security import (
    create_access_token,
    create_refresh_token,
    hash_password,
    verify_password,
)
from app.models.user import User
from app.models.profile import UserProfile
from app.schemas.user import (
    UserLocationUpdateRequest,
    UserProfileUpdateRequest,
    UserRegisterRequest,
)


def get_user_by_email(db: Session, email: str) -> User | None:
    stmt = select(User).where(User.email == email)
    return db.execute(stmt).scalar_one_or_none()


def get_user_by_id(db: Session, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise NotFoundError("المستخدم غير موجود")
    return user


def register_user(db: Session, payload: UserRegisterRequest) -> User:
    """
    Creates a new user + their profile in a single transaction.

    Raises ConflictError if the email is already registered.
    """
    existing = get_user_by_email(db, payload.email)
    if existing is not None:
        raise ConflictError("يوجد حساب مسجّل بهذا البريد الإلكتروني مسبقاً")

    if payload.city not in CITIES:
        raise ValidationError("يرجى اختيار مدينة صحيحة من القائمة")

    user = User(
        email=payload.email,
        hashed_password=hash_password(payload.password),
    )
    user.profile = UserProfile(
        full_name=payload.full_name,
        phone_number=payload.phone_number,
        city=payload.city,
    )

    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def authenticate_user(db: Session, email: str, password: str) -> User:
    """Verifies credentials and returns the user. Raises InvalidCredentialsError on failure."""
    user = get_user_by_email(db, email)
    if user is None or not verify_password(password, user.hashed_password):
        raise InvalidCredentialsError()
    if not user.is_active:
        raise InvalidCredentialsError("تم تعطيل هذا الحساب")
    return user


def issue_tokens(user: User) -> tuple[str, str]:
    """Returns a (access_token, refresh_token) pair for the given user."""
    return create_access_token(user.id), create_refresh_token(user.id)


def update_profile(db: Session, user: User, payload: UserProfileUpdateRequest) -> User:
    """Applies a partial update to the user's profile. Only provided fields are changed."""
    update_data = payload.model_dump(exclude_unset=True)
    if "city" in update_data and update_data["city"] is not None and update_data["city"] not in CITIES:
        raise ValidationError("يرجى اختيار مدينة صحيحة من القائمة")
    for field, value in update_data.items():
        setattr(user.profile, field, value)

    db.commit()
    db.refresh(user)
    return user


def update_location(db: Session, user: User, payload: UserLocationUpdateRequest) -> User:
    """Updates the user's latitude/longitude, used by geo search (Phase 4)."""
    user.profile.latitude = payload.latitude
    user.profile.longitude = payload.longitude
    if payload.address_label is not None:
        user.profile.address_label = payload.address_label

    db.commit()
    db.refresh(user)
    return user


def set_provider_status(db: Session, user: User, is_provider: bool) -> User:
    """Manually toggles whether a user is acting as a provider."""
    user.is_provider = is_provider
    db.commit()
    db.refresh(user)
    return user
