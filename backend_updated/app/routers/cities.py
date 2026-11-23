"""
Cities routes.

Read-only and public: the Flutter app needs this list on the registration
screen (before the user is authenticated) and on the search/change-city
screens. See app/core/constants.py for why this is a hard-coded list
rather than a database table.
"""
from fastapi import APIRouter

from app.core.constants import CITIES

router = APIRouter(prefix="/api/v1/cities", tags=["Cities"])


@router.get("", response_model=list[str])
def list_cities() -> list[str]:
    """Lists every city a user can select at registration or in search."""
    return CITIES
