"""
Database setup: engine, session factory, declarative base, and the
`get_db` dependency used throughout the app to obtain a request-scoped
SQLAlchemy session.
"""
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.core.config import settings

# `pool_pre_ping` avoids "server closed the connection unexpectedly" errors
# after long idle periods (common with managed Postgres providers).
engine = create_engine(
    settings.DATABASE_URL,
    pool_pre_ping=True,
    echo=settings.DEBUG and not settings.is_production,
)

SessionLocal = sessionmaker(
    bind=engine,
    autocommit=False,
    autoflush=False,
)


class Base(DeclarativeBase):
    """Shared declarative base for all ORM models."""
    pass


def get_db() -> Generator:
    """
    FastAPI dependency that yields a database session and guarantees
    it is closed after the request finishes, even if an exception
    is raised mid-request.

    Usage:
        def endpoint(db: Session = Depends(get_db)):
            ...
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
