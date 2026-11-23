"""
Geo-aware search service.

Strategy for performance, in order of execution by Postgres:
  1. Bounding-box pre-filter on indexed lat/lng columns (cheap, sargable,
     uses the btree indexes on Service.latitude/longitude and
     UserProfile.latitude/longitude defined in Phase 2/3).
  2. Exact Haversine distance computed in SQL for rows that survive
     step 1 (more expensive trig, but only run on a small candidate set).
  3. Filter to the precise circular radius and sort nearest-first.

Effective location resolution: a service uses its own lat/lng if set,
otherwise falls back to its provider's profile lat/lng. This is expressed
once via func.coalesce() so every part of the query (bounding box, exact
distance, ordering) is consistent about which location it's using.
"""
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.algorithms.geo import bounding_box, haversine_distance_expr
from app.core.config import settings
from app.core.exceptions import ValidationError
from app.models.profile import UserProfile
from app.models.service import Service, ServiceStatus
from app.models.user import User
from app.schemas.search import ServiceSearchParams


def search_services(
    db: Session,
    params: ServiceSearchParams,
    exclude_provider_id: int | None = None,
) -> list[tuple[Service, float]]:
    """
    Returns a list of (Service, distance_km) tuples for active services
    within `radius_km` of the given origin point, nearest first.

    Only available services are returned: ACTIVE, from an active (not
    deactivated) provider account, and — when `category_id` is given —
    filed under exactly that category (by id, never by text). The
    category filter is applied together with the radius.

    Services with no resolvable location (no override AND no provider
    profile location set) are excluded — they cannot be meaningfully
    placed on a map or sorted by distance.

    `exclude_provider_id`, when given, drops that provider's own listings
    from the results — used so a logged-in provider browsing "services
    near me" sees other people's services, not their own. It's derived
    from the caller's auth token by the router, never from client input,
    so it can't be used to hide someone else's listings.
    """
    effective_lat = func.coalesce(Service.latitude, UserProfile.latitude)
    effective_lon = func.coalesce(Service.longitude, UserProfile.longitude)

    min_lat, max_lat, min_lon, max_lon = bounding_box(
        params.latitude, params.longitude, params.radius_km
    )

    distance_expr = haversine_distance_expr(
        effective_lat, effective_lon, params.latitude, params.longitude
    )

    stmt = (
        select(Service, distance_expr.label("distance_km"))
        .join(User, Service.provider_id == User.id)
        .outerjoin(UserProfile, UserProfile.user_id == User.id)
        .options(
            selectinload(Service.category),
            selectinload(Service.provider).selectinload(User.profile),
        )
        .where(
            Service.status == ServiceStatus.ACTIVE,
            User.is_active.is_(True),
            effective_lat.isnot(None),
            effective_lon.isnot(None),
            effective_lat.between(min_lat, max_lat),
            effective_lon.between(min_lon, max_lon),
        )
    )

    if params.category_id is not None:
        stmt = stmt.where(Service.category_id == params.category_id)

    if params.city is not None:
        stmt = stmt.where(UserProfile.city == params.city)

    if exclude_provider_id is not None:
        stmt = stmt.where(Service.provider_id != exclude_provider_id)

    # The bounding box is a rough rectangle, not a true circle, so we still
    # need to filter precisely by the real Haversine distance afterward.
    stmt = stmt.where(distance_expr <= params.radius_km)
    stmt = stmt.order_by(distance_expr.asc()).limit(params.max_results)

    rows = db.execute(stmt).all()
    return [(row[0], float(row[1])) for row in rows]


def validate_search_params(params: ServiceSearchParams) -> None:
    """
    Extra business-rule validation beyond Pydantic's field-level bounds
    (kept separate so it's easy to extend without bloating the schema).
    """
    if params.radius_km > settings.NEARBY_MAX_RADIUS_KM:
        raise ValidationError(
            f"لا يمكن أن يتجاوز نطاق البحث {settings.NEARBY_MAX_RADIUS_KM:g} كم"
        )
