"""
Authentication routes: register, login, refresh.

Thin by design — all logic lives in app.services.user_service.
"""
from fastapi import APIRouter, BackgroundTasks, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.config import settings
from app.core.exceptions import UnauthorizedError
from app.core.security import TokenType, create_access_token, decode_token
from app.schemas.user import (
    ForgotPasswordRequest,
    MessageResponse,
    RefreshTokenRequest,
    ResetPasswordRequest,
    TokenResponse,
    UserLoginRequest,
    UserRegisterRequest,
    UserResponse,
)
from app.services import password_reset_service, user_service
from app.utils.email_sender import send_password_reset_email

router = APIRouter(prefix="/api/v1/auth", tags=["Auth"])


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register(payload: UserRegisterRequest, db: Session = Depends(get_db)) -> UserResponse:
    """Creates a new user account and profile."""
    user = user_service.register_user(db, payload)
    return UserResponse.model_validate(user)


@router.post("/login", response_model=TokenResponse)
def login(payload: UserLoginRequest, db: Session = Depends(get_db)) -> TokenResponse:
    """Authenticates a user and returns a fresh access/refresh token pair."""
    user = user_service.authenticate_user(db, payload.email, payload.password)
    access_token, refresh_token = user_service.issue_tokens(user)
    return TokenResponse(access_token=access_token, refresh_token=refresh_token)


@router.post("/refresh", response_model=TokenResponse)
def refresh(payload: RefreshTokenRequest, db: Session = Depends(get_db)) -> TokenResponse:
    """
    Exchanges a valid, unexpired refresh token for a new access/refresh pair.

    Note: this issues a brand-new refresh token too (rotation), which limits
    the window in which a leaked refresh token remains useful.
    """
    decoded = decode_token(payload.refresh_token)
    if decoded is None or decoded.get("type") != TokenType.REFRESH.value:
        raise UnauthorizedError("رمز التحديث غير صالح أو منتهي الصلاحية")

    user_id = int(decoded["sub"])
    user = user_service.get_user_by_id(db, user_id)
    if not user.is_active:
        raise UnauthorizedError("تم تعطيل هذا الحساب")

    access_token, refresh_token = user_service.issue_tokens(user)
    return TokenResponse(access_token=access_token, refresh_token=refresh_token)


@router.post("/forgot-password", response_model=MessageResponse)
def forgot_password(
    payload: ForgotPasswordRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
) -> MessageResponse:
    """
    Emails a 6-digit reset code to the account's address.

    Always answers with the same message whether or not the email is
    registered, so the endpoint cannot be used to discover which emails exist.
    """
    result = password_reset_service.request_reset_code(db, payload.email)
    if result is not None:
        user, code = result
        full_name = user.profile.full_name if user.profile else None
        background_tasks.add_task(
            send_password_reset_email,
            user.email,
            full_name,
            code,
            settings.PASSWORD_RESET_CODE_EXPIRE_MINUTES,
        )
    return MessageResponse(message="إذا كان البريد الإلكتروني مسجلاً لدينا، فقد أرسلنا إليه رمز استعادة كلمة المرور")


@router.post("/reset-password", response_model=MessageResponse)
def reset_password(payload: ResetPasswordRequest, db: Session = Depends(get_db)) -> MessageResponse:
    """Sets a new password using the code that was emailed by /forgot-password."""
    password_reset_service.reset_password(db, payload.email, payload.code, payload.new_password)
    return MessageResponse(message="تم تغيير كلمة المرور بنجاح، يمكنك الآن تسجيل الدخول")
