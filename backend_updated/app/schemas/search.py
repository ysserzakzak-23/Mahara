"""
Pydantic schemas for geographic search.
"""
from typing import Optional

from pydantic import BaseModel, Field

from app.core.config import settings
from app.schemas.service import ServiceListItemResponse


class ServiceSearchParams(BaseModel):
    """
    Query parameters for geo-aware service search.

    Used by the Flutter app's "find providers near me" screen: the device
    obtains lat/lng via its location API and sends them here along with
    an optional category filter and search radius.
    """
    # The device's real position (the app never substitutes a default).
    latitude: float = Field(ge=-90, le=90, allow_inf_nan=False)
    longitude: float = Field(ge=-180, le=180, allow_inf_nan=False)
    radius_km: float = Field(
        default=settings.NEARBY_DEFAULT_RADIUS_KM,
        gt=0,
        le=settings.NEARBY_MAX_RADIUS_KM,
        allow_inf_nan=False,
    )
    # Exact category id (not text): only services filed under it are
    # returned, combined with — never instead of — the distance filter.
    category_id: Optional[int] = Field(default=None, gt=0)
    # Extra AND filter on top of the geo radius: restricts results to
    # services whose provider profile is set to this city.
    city: Optional[str] = None
    max_results: int = Field(default=50, ge=1, le=100)


class ServiceSearchResultResponse(ServiceListItemResponse):
    """
    A list item (same fields as every other service list, including the cover
    photo the app shows on the card) annotated with its distance from the
    search origin.
    """

    distance_km: float
