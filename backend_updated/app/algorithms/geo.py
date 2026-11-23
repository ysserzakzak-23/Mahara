"""
Haversine great-circle distance calculations.

Two forms are provided:
  1. `haversine_distance_km()` — pure Python, used for unit tests and any
     one-off distance calculation where a value is already in hand.
  2. `haversine_distance_expr()` — builds a SQLAlchemy SQL expression so
     the distance is computed BY POSTGRES, directly in the SELECT/WHERE/
     ORDER BY clauses. This is what search queries actually use: it lets
     the database sort and filter by distance without pulling every row
     into Python first.

Earth's radius is taken as 6371.0 km (mean radius), which is the standard
constant for Haversine — accurate to within ~0.5% for any two points on
Earth, more than sufficient for "find a plumber near me" use cases.
"""
import math

from sqlalchemy import ColumnElement, func

EARTH_RADIUS_KM = 6371.0


def haversine_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """
    Computes the great-circle distance between two lat/lng points in
    kilometers, using the Haversine formula. Pure Python — used for unit
    tests and standalone calculations outside of a database query.
    """
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return EARTH_RADIUS_KM * c


def haversine_distance_expr(
    lat_col: ColumnElement, lon_col: ColumnElement, origin_lat: float, origin_lon: float
) -> ColumnElement:
    """
    Builds a SQLAlchemy expression that computes the Haversine distance
    (in km) between a fixed origin point and a lat/lng column pair, to be
    evaluated by Postgres itself.

    `lat_col` / `lon_col` can be plain columns OR pre-built COALESCE
    expressions (see app/services/search_service.py, which falls back from
    Service.latitude to UserProfile.latitude when a service has no
    location override). This function doesn't care which — it just needs
    two numeric expressions in degrees.

    Equivalent SQL:
        6371 * acos(
            cos(radians(:origin_lat)) * cos(radians(lat_col)) *
            cos(radians(lon_col) - radians(:origin_lon)) +
            sin(radians(:origin_lat)) * sin(radians(lat_col))
        )

    Note: this uses the acos/cos/sin form (mathematically equivalent to
    the atan2 form used in the pure-Python version above) because it
    translates more directly into standard SQL functions available on
    plain PostgreSQL without any extension.
    """
    origin_lat_rad = math.radians(origin_lat)
    origin_lon_rad = math.radians(origin_lon)

    lat_rad = func.radians(lat_col)
    lon_rad = func.radians(lon_col)

    cos_angle = (
        func.cos(origin_lat_rad) * func.cos(lat_rad) * func.cos(lon_rad - origin_lon_rad)
        + func.sin(origin_lat_rad) * func.sin(lat_rad)
    )

    # Clamp to [-1, 1] before acos: floating-point rounding can push the
    # cosine sum very slightly outside this domain for near-identical
    # points (e.g. searching from the exact location of a result), which
    # would otherwise make acos() return NULL/NaN in Postgres.
    clamped = func.greatest(-1.0, func.least(1.0, cos_angle))

    return EARTH_RADIUS_KM * func.acos(clamped)


def bounding_box(lat: float, lon: float, radius_km: float) -> tuple[float, float, float, float]:
    """
    Computes a cheap rectangular lat/lng bounding box around a point for a
    given radius, used as an indexed pre-filter before the precise (and
    more expensive) Haversine calculation runs.

    Returns (min_lat, max_lat, min_lon, max_lon).

    This is intentionally approximate — it may include a few points just
    outside the true circular radius near the box's corners, but never
    excludes points that are actually within the radius. The exact
    Haversine WHERE clause applied afterward filters those edge cases out.
    """
    lat_delta = radius_km / 111.0  # ~111 km per degree of latitude, everywhere on Earth
    # Degrees of longitude per km shrinks toward the poles by cos(latitude);
    # guard against division by ~0 near the poles.
    lon_delta = radius_km / max(111.0 * math.cos(math.radians(lat)), 1e-6)

    min_lat = max(lat - lat_delta, -90.0)
    max_lat = min(lat + lat_delta, 90.0)
    # Longitude is intentionally NOT wrapped/clamped to [-180, 180] here:
    # this is a realistic regional service-marketplace use case (a single
    # city/country), and antimeridian wraparound is out of scope. The exact
    # Haversine filter applied afterward still correctly excludes any false
    # positives the unwrapped box might admit.
    min_lon = lon - lon_delta
    max_lon = lon + lon_delta

    return (min_lat, max_lat, min_lon, max_lon)
