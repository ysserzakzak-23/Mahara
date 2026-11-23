"""
Security primitives: password hashing and JWT access/refresh token
creation & verification.

Kept isolated from business logic so all auth-sensitive code lives
in one auditable place.
"""
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any, Optional

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.core.config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


class TokenType(str, Enum):
    ACCESS = "access"
    REFRESH = "refresh"


# --------------------------------------------------------------------------
# Password hashing
# --------------------------------------------------------------------------

def hash_password(plain_password: str) -> str:
    """Hashes a plaintext password using bcrypt."""
    return pwd_context.hash(plain_password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """Verifies a plaintext password against a bcrypt hash."""
    return pwd_context.verify(plain_password, hashed_password)


# --------------------------------------------------------------------------
# JWT tokens
# --------------------------------------------------------------------------

def _create_token(subject: str, token_type: TokenType, expires_delta: timedelta) -> str:
    """
    Internal helper that builds and signs a JWT.

    `subject` is the user id (as a string). `token_type` is embedded in the
    payload so that access and refresh tokens can never be confused with
    each other even though they share the same secret/algorithm.
    """
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": subject,
        "type": token_type.value,
        "iat": now,
        "exp": now + expires_delta,
    }
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)


def create_access_token(user_id: int) -> str:
    """Creates a short-lived access token for authenticating API requests."""
    return _create_token(
        subject=str(user_id),
        token_type=TokenType.ACCESS,
        expires_delta=timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES),
    )


def create_refresh_token(user_id: int) -> str:
    """Creates a long-lived refresh token used solely to mint new access tokens."""
    return _create_token(
        subject=str(user_id),
        token_type=TokenType.REFRESH,
        expires_delta=timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS),
    )


def decode_token(token: str) -> Optional[dict]:
    """
    Decodes and verifies a JWT's signature and expiry.

    Returns the payload dict on success, or None if the token is invalid,
    expired, or malformed. Callers are responsible for checking the
    "type" field if they need to enforce access-vs-refresh usage.
    """
    try:
        return jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])
    except JWTError:
        return None
