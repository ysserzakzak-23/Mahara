"""
"Forgot password" business logic (email + 6-digit code).

Flow:
  1. request_reset_code(): user enters their email -> we create a code and email it.
  2. reset_password(): user enters email + code + new password -> password changes.

Security notes:
  * The endpoint never reveals whether an email is registered (no user enumeration).
  * Only an HMAC hash of the code is stored; codes expire and have a guess limit.
  * Requesting a new code invalidates the previous ones; requests are throttled.
"""
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import ValidationError
from app.core.security import hash_password
from app.models.password_reset import PasswordResetToken
from app.models.user import User
from app.services import user_service

INVALID_CODE_MESSAGE = "رمز التحقق غير صحيح أو منتهي الصلاحية"
TOO_MANY_ATTEMPTS_MESSAGE = "تجاوزت عدد المحاولات المسموحة، يرجى طلب رمز جديد"


def _hash_code(user_id: int, code: str) -> str:
    key = settings.JWT_SECRET_KEY.encode("utf-8")
    return hmac.new(key, f"{user_id}:{code}".encode("utf-8"), hashlib.sha256).hexdigest()


def _as_utc(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def request_reset_code(db: Session, email: str) -> tuple[User, str] | None:
    """
    Creates a fresh reset code for the account with this email.

    Returns (user, plain_code) so the caller can email it, or None when nothing
    should be sent (unknown/inactive account, or asked again too quickly). The
    caller must respond identically in every case.
    """
    user = user_service.get_user_by_email(db, email)
    if user is None or not user.is_active:
        return None

    now = datetime.now(timezone.utc)
    latest = db.execute(
        select(PasswordResetToken)
        .where(PasswordResetToken.user_id == user.id)
        .order_by(PasswordResetToken.created_at.desc(), PasswordResetToken.id.desc())
        .limit(1)
    ).scalar_one_or_none()
    if latest is not None and latest.created_at is not None:
        if now - _as_utc(latest.created_at) < timedelta(seconds=settings.PASSWORD_RESET_RESEND_SECONDS):
            return None

    # Only one active code per user.
    db.execute(delete(PasswordResetToken).where(PasswordResetToken.user_id == user.id))

    code = f"{secrets.randbelow(1_000_000):06d}"
    db.add(
        PasswordResetToken(
            user_id=user.id,
            code_hash=_hash_code(user.id, code),
            expires_at=now + timedelta(minutes=settings.PASSWORD_RESET_CODE_EXPIRE_MINUTES),
            attempts=0,
        )
    )
    db.commit()
    return user, code


def reset_password(db: Session, email: str, code: str, new_password: str) -> None:
    """Validates the emailed code and sets the new password."""
    user = user_service.get_user_by_email(db, email)
    if user is None or not user.is_active:
        raise ValidationError(INVALID_CODE_MESSAGE)

    token = db.execute(
        select(PasswordResetToken)
        .where(PasswordResetToken.user_id == user.id)
        .order_by(PasswordResetToken.id.desc())
        .limit(1)
    ).scalar_one_or_none()
    if token is None:
        raise ValidationError(INVALID_CODE_MESSAGE)

    now = datetime.now(timezone.utc)
    if _as_utc(token.expires_at) < now:
        db.delete(token)
        db.commit()
        raise ValidationError(INVALID_CODE_MESSAGE)

    if token.attempts >= settings.PASSWORD_RESET_MAX_ATTEMPTS:
        db.delete(token)
        db.commit()
        raise ValidationError(TOO_MANY_ATTEMPTS_MESSAGE)

    if not hmac.compare_digest(token.code_hash, _hash_code(user.id, code)):
        token.attempts += 1
        db.commit()
        raise ValidationError(INVALID_CODE_MESSAGE)

    user.hashed_password = hash_password(new_password)
    db.execute(delete(PasswordResetToken).where(PasswordResetToken.user_id == user.id))
    db.commit()
