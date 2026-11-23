"""
Geo search executed by PostgreSQL: bounding-box pre-filter + SQL Haversine +
COALESCE(service location, provider profile location).
"""
import math

import pytest

from app.algorithms.geo import EARTH_RADIUS_KM, haversine_distance_km
from app.models import ServiceStatus
from app.schemas.search import ServiceSearchParams
from app.services.search_service import search_services

from .helpers import make_category, make_service, make_user

ORIGIN = (31.9, 35.9)
KM_PER_DEG_LAT = EARTH_RADIUS_KM * math.pi / 180


def offset(origin, km_north=0.0, km_east=0.0):
    lat = origin[0] + km_north / KM_PER_DEG_LAT
    lon = origin[1] + km_east / (KM_PER_DEG_LAT * math.cos(math.radians(origin[0])))
    return lat, lon


def destination(lat, lon, bearing_deg, dist_km):
    """Point `dist_km` away from (lat, lon) along a bearing (spherical earth)."""
    d = dist_km / EARTH_RADIUS_KM
    t, p1, l1 = math.radians(bearing_deg), math.radians(lat), math.radians(lon)
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(t))
    l2 = l1 + math.atan2(math.sin(t) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), math.degrees(l2)


def search(session, origin=ORIGIN, radius_km=10.0, **kwargs):
    exclude = kwargs.pop("exclude_provider_id", None)
    params = ServiceSearchParams(latitude=origin[0], longitude=origin[1], radius_km=radius_km, **kwargs)
    return search_services(session, params, exclude_provider_id=exclude)


@pytest.fixture
def geo(session):
    class G:
        pass

    g = G()
    g.session = session
    g.category = make_category(session)
    g.provider = make_user(session, is_provider=True)  # profile row exists but has no coordinates
    return g


def add(g, km_north=0.0, km_east=0.0, **kwargs):
    lat, lon = offset(ORIGIN, km_north, km_east)
    return make_service(g.session, kwargs.pop("provider", g.provider), kwargs.pop("category", g.category),
                        lat=lat, lon=lon, **kwargs)


# ---------------------------------------------------------------- ordering / distance
def test_results_are_sorted_nearest_first_and_distances_match_python(geo):
    far = add(geo, km_north=20, title="far")
    near = add(geo, km_north=5, title="near")
    mid = add(geo, km_north=12, title="mid")

    results = search(geo.session, radius_km=50)

    assert [s.title for s, _ in results] == ["near", "mid", "far"]
    for service, distance in results:
        expected = haversine_distance_km(*ORIGIN, service.latitude, service.longitude)
        assert distance == pytest.approx(expected, abs=1e-4)
    assert {near.id, mid.id, far.id} == {s.id for s, _ in results}


@pytest.mark.parametrize(
    "origin",
    [(-34.6037, -58.3816), (51.5074, -0.1278), (0.0, 0.0), (35.6762, 139.6503), (31.9, 35.9)],
    ids=["buenos-aires", "london", "null-island", "tokyo", "amman"],
)
def test_sql_distance_equals_python_haversine_in_every_hemisphere(geo, origin):
    service = make_service(geo.session, geo.provider, geo.category, lat=origin[0] + 0.1, lon=origin[1] + 0.1)

    [(found, distance)] = search(geo.session, origin=origin, radius_km=100)

    assert found.id == service.id
    assert distance == pytest.approx(haversine_distance_km(*origin, service.latitude, service.longitude), abs=1e-4)


# ---------------------------------------------------------------- radius / bounding box
def test_radius_boundary_is_exact(geo):
    inside = add(geo, km_north=9.9, title="inside")
    add(geo, km_north=10.1, title="outside")

    results = search(geo.session, radius_km=10)

    assert [s.id for s, _ in results] == [inside.id]


def test_bounding_box_corner_is_removed_by_exact_haversine(geo):
    """8 km north + 8 km east is inside the 10 km square but 11.3 km away."""
    corner = add(geo, km_north=8, km_east=8)

    assert search(geo.session, radius_km=10) == []
    assert [s.id for s, _ in search(geo.session, radius_km=12)] == [corner.id]


@pytest.mark.parametrize("lat", [0.0, 31.9, 60.0, 75.0])
def test_bounding_box_never_drops_a_point_inside_the_radius(geo, lat):
    origin = (lat, 20.0)
    for bearing in range(0, 360, 45):
        plat, plon = destination(*origin, bearing, 9.9)
        make_service(geo.session, geo.provider, geo.category, lat=plat, lon=plon)

    assert len(search(geo.session, origin=origin, radius_km=10)) == 8


@pytest.mark.parametrize("lat", [0.0, 31.9, 60.0, 75.0])
def test_nothing_just_outside_the_radius_is_returned(geo, lat):
    origin = (lat, 20.0)
    for bearing in range(0, 360, 45):
        plat, plon = destination(*origin, bearing, 10.1)
        make_service(geo.session, geo.provider, geo.category, lat=plat, lon=plon)

    assert search(geo.session, origin=origin, radius_km=10) == []


@pytest.mark.parametrize(
    "origin",
    [(31.9, 35.9), (33.5138, 36.2765), (-34.6037, -58.3816), (51.9803, 4.2), (0.0, 0.0)],
)
def test_searching_from_the_exact_service_location_is_not_null_or_excluded(geo, origin):
    """Guards the acos() domain clamp: cos can round to 1.0000000000000002."""
    service = make_service(geo.session, geo.provider, geo.category, lat=origin[0], lon=origin[1])

    [(found, distance)] = search(geo.session, origin=origin, radius_km=1)

    assert found.id == service.id
    assert distance is not None and 0 <= distance < 0.01


# ---------------------------------------------------------------- COALESCE location resolution
def test_service_without_own_location_uses_provider_profile_location(session):
    category = make_category(session)
    lat, lon = offset(ORIGIN, km_north=3)
    provider = make_user(session, is_provider=True, lat=lat, lon=lon)
    service = make_service(session, provider, category)  # no lat/lon on the service

    [(found, distance)] = search(session)

    assert found.id == service.id
    assert distance == pytest.approx(3, abs=0.01)


def test_service_location_overrides_provider_profile_location(session):
    category = make_category(session)
    far_lat, far_lon = offset(ORIGIN, km_north=100)
    provider = make_user(session, is_provider=True, lat=far_lat, lon=far_lon)
    near_lat, near_lon = offset(ORIGIN, km_north=2)
    service = make_service(session, provider, category, lat=near_lat, lon=near_lon)

    assert [s.id for s, _ in search(session)] == [service.id]


def test_provider_profile_nearby_does_not_rescue_a_far_service_override(session):
    category = make_category(session)
    near_lat, near_lon = offset(ORIGIN, km_north=2)
    provider = make_user(session, is_provider=True, lat=near_lat, lon=near_lon)
    far_lat, far_lon = offset(ORIGIN, km_north=100)
    make_service(session, provider, category, lat=far_lat, lon=far_lon)

    assert search(session) == []


def test_services_with_no_resolvable_location_are_excluded(session):
    category = make_category(session)
    no_coords = make_user(session, is_provider=True)                       # profile, no coordinates
    no_profile = make_user(session, is_provider=True, with_profile=False)  # no profile row at all
    make_service(session, no_coords, category)
    make_service(session, no_profile, category)

    assert search(session, radius_km=200) == []


# ---------------------------------------------------------------- filters
@pytest.mark.parametrize("hidden", [ServiceStatus.INACTIVE, ServiceStatus.SUSPENDED])
def test_only_active_services_are_returned(geo, hidden):
    visible = add(geo, km_north=1, status=ServiceStatus.ACTIVE)
    add(geo, km_north=1, status=hidden)

    assert [s.id for s, _ in search(geo.session)] == [visible.id]


def test_category_filter(geo):
    other = make_category(geo.session)
    wanted = add(geo, km_north=1)
    add(geo, km_north=1, category=other)

    results = search(geo.session, category_id=geo.category.id)

    assert [s.id for s, _ in results] == [wanted.id]


def test_city_filter_uses_the_providers_profile_city(session):
    category = make_category(session)
    lat, lon = offset(ORIGIN, km_north=1)
    amman = make_user(session, is_provider=True, city="Amman", lat=lat, lon=lon)
    irbid = make_user(session, is_provider=True, city="Irbid", lat=lat, lon=lon)
    in_amman = make_service(session, amman, category)
    make_service(session, irbid, category)

    assert [s.id for s, _ in search(session, city="Amman")] == [in_amman.id]


def test_exclude_provider_id_hides_the_callers_own_listings(geo):
    mine = add(geo, km_north=1)
    other_provider = make_user(geo.session, is_provider=True)
    theirs = add(geo, km_north=2, provider=other_provider)

    results = search(geo.session, exclude_provider_id=geo.provider.id)

    assert [s.id for s, _ in results] == [theirs.id]
    assert mine.id not in {s.id for s, _ in results}


def test_max_results_keeps_the_nearest_ones(geo):
    add(geo, km_north=1, title="1km")
    add(geo, km_north=2, title="2km")
    add(geo, km_north=3, title="3km")

    results = search(geo.session, max_results=2)

    assert [s.title for s, _ in results] == ["1km", "2km"]
