"""
Centralized application configuration.

All environment-dependent values are loaded here ONCE via Pydantic Settings.
Every other module should import `settings` from this file rather than
reading os.environ directly — this keeps configuration testable, validated,
and in one place.
"""
from functools import lru_cache
from typing import List

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # --- App ---
    APP_NAME: str = "مهارة"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    API_V1_PREFIX: str = "/api/v1"

    # --- Database ---
    DATABASE_URL: str

    # --- JWT ---
    JWT_SECRET_KEY: str
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    REFRESH_TOKEN_EXPIRE_DAYS: int = 7

    # --- CORS ---
    CORS_ORIGINS: str = "http://localhost:3000"

    # --- Firebase Cloud Messaging ---
    FIREBASE_CREDENTIALS_PATH: str = "./firebase-service-account.json"
    FCM_ENABLED: bool = False

    # --- Semantic (AI) search ---
    # Off by default: the sentence-transformers model is a heavy optional
    # dependency (pulls in torch, ~500MB) and downloads weights on first use.
    # See SEMANTIC_SEARCH_SETUP.md.
    SEMANTIC_SEARCH_ENABLED: bool = False

    # --- Nearby ("خدمات قريبة مني") geo search ---
    # Radius used when the app doesn't send one, and the largest radius a
    # client may ask for. The app's own default radius slider position is
    # kept in sync with NEARBY_DEFAULT_RADIUS_KM (see the Flutter
    # NearbySearchConfig).
    NEARBY_DEFAULT_RADIUS_KM: float = 25.0
    NEARBY_MAX_RADIUS_KM: float = 200.0

    # --- Email (SMTP) — used for "forgot password" codes ---
    # Leave SMTP_HOST empty in development: the email is then NOT sent, it is
    # printed to the server log instead (so you can copy the reset code).
    SMTP_HOST: str = ""
    SMTP_PORT: int = 587
    SMTP_USERNAME: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM_EMAIL: str = ""
    SMTP_FROM_NAME: str = "مهارة"
    SMTP_USE_TLS: bool = True   # STARTTLS (port 587). Set SMTP_USE_SSL for port 465.
    SMTP_USE_SSL: bool = False

    # --- Password reset ---
    PASSWORD_RESET_CODE_EXPIRE_MINUTES: int = 15
    PASSWORD_RESET_MAX_ATTEMPTS: int = 5
    PASSWORD_RESET_RESEND_SECONDS: int = 60

    # --- Pagination ---
    DEFAULT_PAGE_SIZE: int = 20
    MAX_PAGE_SIZE: int = 100

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    @property
    def cors_origins_list(self) -> List[str]:
        """Parses the comma-separated CORS_ORIGINS string into a list."""
        return [origin.strip() for origin in self.CORS_ORIGINS.split(",") if origin.strip()]

    @property
    def is_production(self) -> bool:
        return self.ENVIRONMENT.lower() == "production"


@lru_cache
def get_settings() -> Settings:
    """
    Cached settings accessor.

    Using lru_cache means the .env file is parsed only once per process,
    and `get_settings()` can be safely used as a FastAPI dependency.
    """
    return Settings()


# Convenience singleton for direct imports: `from app.core.config import settings`
settings = get_settings()
