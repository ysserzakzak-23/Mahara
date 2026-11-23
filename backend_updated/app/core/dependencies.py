"""
Reusable FastAPI dependencies for authentication and authorization.

`get_current_user` decodes the bearer token and loads the user from the DB.
`require_admin` builds on top of it to guard admin-only routes.
"""
from fastapi import Depends
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.exceptions import PermissionDeniedError, UnauthorizedError
from app.core.security import TokenType, decode_token
from app.models.user import User, UserRole

# tokenUrl points at the login endpoint purely for OpenAPI docs (Swagger's
# "Authorize" button); FastAPI doesn't call it internally.
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login", auto_error=False)


def get_current_user(
    token: str | None = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    """
    Decodes the bearer access token and returns the corresponding active User.

    Raises UnauthorizedError if the token is missing, invalid, expired,
    not an access token, or if the user no longer exists / is deactivated.
    """
    if token is None:
        raise UnauthorizedError("رمز الدخول مفقود")

    payload = decode_token(token)
    if payload is None:
        raise UnauthorizedError("رمز الدخول غير صالح أو منتهي الصلاحية")

    if payload.get("type") != TokenType.ACCESS.value:
        raise UnauthorizedError("نوع الرمز غير صحيح")

    user_id_raw = payload.get("sub")
    if user_id_raw is None:
        raise UnauthorizedError("رمز الدخول غير صالح")

    try:
        user_id = int(user_id_raw)
    except (TypeError, ValueError):
        # A correctly signed token whose subject is not a user id. Only the
        # conversion is guarded — the lookup below stays outside, so a real
        # database or programming error is never mistaken for a bad token.
        raise UnauthorizedError("رمز الدخول غير صالح")

    user = db.get(User, user_id)
    if user is None:
        raise UnauthorizedError("هذا المستخدم لم يعد موجوداً")

    if not user.is_active:
        raise UnauthorizedError("تم تعطيل هذا الحساب")

    return user


def get_current_user_optional(
    token: str | None = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User | None:
    """
    Same idea as `get_current_user`, but for endpoints that must stay
    public (no login required) while still personalizing behavior for a
    caller who happens to be logged in — e.g. nearby-service search
    excluding the caller's own listings from the results.

    Returns None instead of raising whenever the token is missing,
    invalid, expired, the wrong type, or belongs to a deactivated/deleted
    user — this must never turn a public route into a gated one.
    """
    if token is None:
        return None

    payload = decode_token(token)
    if payload is None:
        return None

    if payload.get("type") != TokenType.ACCESS.value:
        return None

    user_id_raw = payload.get("sub")
    if user_id_raw is None:
        return None

    try:
        user_id = int(user_id_raw)
    except (TypeError, ValueError):
        # Same unusable subject as above, answered the way this dependency
        # answers everything it cannot verify: None, never an exception. A
        # public route must not turn into a 500 over it.
        return None

    user = db.get(User, user_id)
    if user is None or not user.is_active:
        return None

    return user


def require_admin(current_user: User = Depends(get_current_user)) -> User:
    """Guard dependency: ensures the current user has the admin role."""
    if current_user.role != UserRole.ADMIN:
        raise PermissionDeniedError("هذا الإجراء متاح للمشرفين فقط")
    return current_user
