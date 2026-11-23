"""
Global exception handlers.

Registered on the FastAPI app in main.py. Translates the domain exceptions
defined in app/core/exceptions.py into consistent JSON error responses,
so routers never need repetitive try/except blocks around service calls.
"""
import logging

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.core.exceptions import (
    AppError,
    ConflictError,
    InvalidCredentialsError,
    NotFoundError,
    PermissionDeniedError,
    ServiceUnavailableError,
    UnauthorizedError,
    ValidationError,
)

logger = logging.getLogger(__name__)

# Arabic labels for request fields, used when building validation messages.
_FIELD_LABELS = {
    "email": "البريد الإلكتروني",
    "password": "كلمة المرور",
    "new_password": "كلمة المرور الجديدة",
    "confirm_password": "تأكيد كلمة المرور",
    "code": "رمز التحقق",
    "full_name": "الاسم الكامل",
    "phone_number": "رقم الجوال",
    "city": "المدينة",
    "bio": "النبذة",
    "title": "العنوان",
    "description": "الوصف",
    "price": "السعر",
    "name": "الاسم",
    "comment": "التعليق",
    "rating": "التقييم",
    "start_time": "وقت البداية",
    "end_time": "وقت النهاية",
    "latitude": "خط العرض",
    "longitude": "خط الطول",
    "refresh_token": "رمز التحديث",
    "day": "اليوم",
}


def _field_label(loc: tuple) -> str:
    """Returns the Arabic label of the offending field (last str in `loc`)."""
    name = next((str(part) for part in reversed(loc) if isinstance(part, str)), "")
    return _FIELD_LABELS.get(name, "الحقل")


def _arabic_validation_message(error: dict) -> str:
    """Translates one Pydantic v2 error dict into a friendly Arabic sentence."""
    kind = error.get("type", "")
    ctx = error.get("ctx") or {}
    label = _field_label(tuple(error.get("loc", ())))
    msg = str(error.get("msg", ""))

    # Messages raised by our own validators (ValueError("...")) are already
    # written in Arabic: pass them through without Pydantic's English prefix.
    if kind == "value_error" and msg.startswith("Value error, "):
        custom = msg[len("Value error, "):]
        if "@" in custom and "email" in custom.lower():
            return "البريد الإلكتروني غير صالح"
        return custom

    if kind == "value_error" and "email" in msg.lower():
        return "البريد الإلكتروني غير صالح"
    if kind == "missing":
        return f"{label} مطلوب"
    if kind == "string_too_short":
        return f"{label} يجب ألا يقل عن {ctx.get('min_length')} أحرف"
    if kind == "string_too_long":
        return f"{label} يجب ألا يزيد عن {ctx.get('max_length')} حرفاً"
    if kind in ("int_parsing", "float_parsing", "int_from_float", "decimal_parsing"):
        return f"{label} يجب أن يكون رقماً صحيحاً"
    if kind == "greater_than_equal":
        return f"{label} يجب ألا يقل عن {ctx.get('ge')}"
    if kind == "less_than_equal":
        return f"{label} يجب ألا يزيد عن {ctx.get('le')}"
    if kind == "greater_than":
        return f"{label} يجب أن يكون أكبر من {ctx.get('gt')}"
    if kind == "less_than":
        return f"{label} يجب أن يكون أقل من {ctx.get('lt')}"
    if kind in ("json_invalid", "model_attributes_type", "dict_type"):
        return "البيانات المرسلة غير صالحة"
    if kind == "bool_parsing":
        return f"{label} يجب أن يكون صح أو خطأ"
    if kind in ("datetime_parsing", "datetime_from_date_parsing", "date_parsing", "time_parsing"):
        return f"صيغة التاريخ/الوقت في {label} غير صحيحة"
    if kind == "enum" or kind == "literal_error":
        return f"القيمة المدخلة في {label} غير صالحة"
    if kind == "string_type":
        return f"{label} يجب أن يكون نصاً"
    return f"القيمة المدخلة في {label} غير صالحة"

_STATUS_MAP = {
    NotFoundError: status.HTTP_404_NOT_FOUND,
    ConflictError: status.HTTP_409_CONFLICT,
    PermissionDeniedError: status.HTTP_403_FORBIDDEN,
    InvalidCredentialsError: status.HTTP_401_UNAUTHORIZED,
    UnauthorizedError: status.HTTP_401_UNAUTHORIZED,
    ValidationError: status.HTTP_422_UNPROCESSABLE_ENTITY,
    ServiceUnavailableError: status.HTTP_503_SERVICE_UNAVAILABLE,
}


def _status_for(exc: AppError) -> int:
    """
    The status mapped to `exc`'s class, or to the nearest class it inherits
    from.

    __mro__ is walked in order, so the closest registered ancestor wins and
    an exact mapping still matches itself first. An exact-type lookup gave a
    subclass of, say, NotFoundError the generic fallback instead of its
    parent's 404.
    """
    for klass in type(exc).__mro__:
        if klass in _STATUS_MAP:
            return _STATUS_MAP[klass]
    return status.HTTP_400_BAD_REQUEST


def register_error_handlers(app: FastAPI) -> None:
    """Attaches all custom exception handlers to the given FastAPI app instance."""

    @app.exception_handler(AppError)
    async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
        status_code = _status_for(exc)
        return JSONResponse(
            status_code=status_code,
            content={"detail": exc.message, "error_type": type(exc).__name__},
        )

    @app.exception_handler(RequestValidationError)
    async def handle_request_validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # Same shape as FastAPI's default 422 body (a list of error objects) so
        # existing clients keep working, but with Arabic `msg` text.
        detail = [
            {
                "loc": list(error.get("loc", ())),
                "msg": _arabic_validation_message(error),
                "type": error.get("type", "value_error"),
            }
            for error in exc.errors()
        ]
        return JSONResponse(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, content={"detail": detail})

    @app.exception_handler(Exception)
    async def handle_unexpected_error(request: Request, exc: Exception) -> JSONResponse:
        # Catch-all safety net: never leak stack traces or internals to clients.
        logger.exception("Unhandled exception on %s %s", request.method, request.url.path)
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={"detail": "حدث خطأ غير متوقع، يرجى المحاولة لاحقاً", "error_type": "InternalServerError"},
        )
