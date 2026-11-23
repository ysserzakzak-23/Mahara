"""
Domain-level exceptions.

Services and repositories raise these instead of FastAPI's HTTPException
directly. This keeps the service layer framework-agnostic and unit-testable
without needing a running ASGI app. A single exception handler registered
in main.py translates these into proper HTTP responses (see
app/core/error_handlers.py).
"""


class AppError(Exception):
    """Base class for all custom application errors."""

    def __init__(self, message: str = "حدث خطأ في التطبيق"):
        self.message = message
        super().__init__(message)


class NotFoundError(AppError):
    """Raised when a requested resource does not exist."""

    def __init__(self, message: str = "العنصر المطلوب غير موجود"):
        super().__init__(message)


class ConflictError(AppError):
    """Raised when an operation conflicts with existing state (e.g. double booking, duplicate email)."""

    def __init__(self, message: str = "يوجد تعارض مع بيانات موجودة"):
        super().__init__(message)


class PermissionDeniedError(AppError):
    """Raised when an authenticated user lacks permission for an action."""

    def __init__(self, message: str = "ليس لديك صلاحية لتنفيذ هذا الإجراء"):
        super().__init__(message)


class InvalidCredentialsError(AppError):
    """Raised when login credentials are invalid."""

    def __init__(self, message: str = "البريد الإلكتروني أو كلمة المرور غير صحيحة"):
        super().__init__(message)


class UnauthorizedError(AppError):
    """Raised when a request lacks valid authentication."""

    def __init__(self, message: str = "يجب تسجيل الدخول أولاً"):
        super().__init__(message)


class ValidationError(AppError):
    """Raised for business-rule validation failures not covered by Pydantic schema validation."""

    def __init__(self, message: str = "فشل التحقق من البيانات"):
        super().__init__(message)


class ServiceUnavailableError(AppError):
    """Raised when a feature is temporarily disabled or a required optional
    dependency isn't installed (e.g. semantic search when SEMANTIC_SEARCH_ENABLED
    is false or `sentence-transformers` isn't installed)."""

    def __init__(self, message: str = "هذه الميزة غير متاحة حالياً"):
        super().__init__(message)
