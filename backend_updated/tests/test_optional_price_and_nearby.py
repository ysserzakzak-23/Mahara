"""
Services without a price / without a separate name, and the nearby
("خدمات قريبة مني") geo search.

The nearby search is exercised for real: `search_services` builds the same
SQL it sends to PostgreSQL, and here it runs against an in-memory SQLite
database with the few math functions it needs (radians, cos, sin, acos,
greatest, least) registered. That proves the category filter, the radius
cut-off, the nearest-first order and the latitude/longitude handling of the
actual query — not just its shape. (The PostgreSQL-specific parts are
covered by tests/integration_db/test_geo_search.py.)
"""
import math
import os
from decimal import Decimal
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session

import app.models  # noqa: F401  (registers every mapper)
import app.models.exchange  # noqa: F401
from app.algorithms.geo import EARTH_RADIUS_KM, bounding_box, haversine_distance_km
from app.core.config import settings
from app.core.database import Base
from app.models.category import ServiceCategory
from app.models.profile import UserProfile
from app.models.service import Service, ServiceStatus
from app.models.user import User
from app.schemas.search import ServiceSearchParams
from app.schemas.service import (
    ServiceCreateRequest,
    ServiceListItemResponse,
    ServiceResponse,
    ServiceUpdateRequest,
)
from app.services import search_service
from app.services import service_service as svc
from tests.test_routers import client, fake_db  # noqa: F401  (shared fixtures)

ALEMBIC_DIR = os.path.join(os.path.dirname(__file__), "..", "alembic", "versions")

NORMAL = SimpleNamespace(id=1, name="سباكة", is_other=False)
OTHERS = SimpleNamespace(id=9, name="أخرى", is_other=True)


# ===================================================== optional price (create)

@pytest.fixture
def create_env(monkeypatch):
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: "reloaded")
    monkeypatch.setattr(svc, "get_category_by_id", lambda db, cid: NORMAL)
    monkeypatch.setattr(svc, "provider_has_working_hours", lambda db, pid: True)


def test_a_service_can_be_published_without_price_or_name(db, create_env):
    payload = ServiceCreateRequest(category_id=1, description="أصلح جميع أنواع التمديدات")

    svc.create_service(db, SimpleNamespace(id=4, is_provider=True), payload)

    created = db.add.call_args.args[0]
    assert created.price is None          # NULL, never 0
    assert created.title is None          # no invented name
    assert created.category_id == 1
    assert created.description == "أصلح جميع أنواع التمديدات"


def test_a_null_price_in_the_request_is_stored_as_null(db, create_env):
    payload = ServiceCreateRequest(category_id=1, description="أصلح جميع أنواع التمديدات", price=None)
    svc.create_service(db, SimpleNamespace(id=4, is_provider=True), payload)
    assert db.add.call_args.args[0].price is None


def test_a_given_price_is_still_stored(db, create_env):
    payload = ServiceCreateRequest(
        category_id=1, description="أصلح جميع أنواع التمديدات", price=Decimal("25.50"),
    )
    svc.create_service(db, SimpleNamespace(id=4, is_provider=True), payload)
    assert db.add.call_args.args[0].price == Decimal("25.50")


def test_an_old_client_sending_a_title_still_works(db, create_env):
    payload = ServiceCreateRequest(
        category_id=1, title="  سباك محترف ", description="أصلح جميع أنواع التمديدات",
    )
    svc.create_service(db, SimpleNamespace(id=4, is_provider=True), payload)
    assert db.add.call_args.args[0].title == "سباك محترف"


@pytest.mark.parametrize("price", ["0", "-5", "1.234"])
def test_a_given_price_must_still_be_valid(price):
    with pytest.raises(ValueError):
        ServiceCreateRequest(category_id=1, description="أصلح جميع أنواع التمديدات", price=price)


def test_a_title_if_sent_must_still_be_valid():
    with pytest.raises(ValueError):
        ServiceCreateRequest(category_id=1, title="ab", description="أصلح جميع أنواع التمديدات")


# ===================================================== optional price (update)

def stored(price=Decimal("10"), title="سباك محترف"):
    return SimpleNamespace(
        id=1, provider_id=4, category=NORMAL, custom_category_label=None,
        title=title, price=price, description="وصف قديم للخدمة", is_remote=True,
    )


@pytest.fixture
def update_env(monkeypatch):
    def install(service):
        monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: service)
        return service
    return install


OWNER = SimpleNamespace(id=4, role="user")


def test_sending_a_null_price_removes_it(db, update_env):
    service = update_env(stored())
    svc.update_service(db, 1, OWNER, ServiceUpdateRequest(price=None))
    assert service.price is None
    db.commit.assert_called_once()


def test_not_sending_a_price_keeps_it(db, update_env):
    service = update_env(stored())
    svc.update_service(db, 1, OWNER, ServiceUpdateRequest(description="وصف جديد للخدمة كاملاً"))
    assert service.price == Decimal("10")
    assert service.title == "سباك محترف"       # the old name is preserved too


def test_a_price_can_be_added_to_a_service_without_one(db, update_env):
    service = update_env(stored(price=None))
    svc.update_service(db, 1, OWNER, ServiceUpdateRequest(price=Decimal("40")))
    assert service.price == Decimal("40")


def test_a_null_for_a_required_field_is_ignored_not_saved(db, update_env):
    service = update_env(stored())
    svc.update_service(db, 1, OWNER, ServiceUpdateRequest(description=None, is_remote=None))
    assert service.description == "وصف قديم للخدمة"
    assert service.is_remote is True


# ================================================= category as the identity

def make_service(category, label=None, title=None):
    service = Service(title=title, custom_category_label=label, description="d", price=None)
    service.category = category
    return service


def test_the_category_names_the_service():
    assert make_service(ServiceCategory(name="سباكة", is_other=False)).display_title == "سباكة"


def test_the_custom_label_names_an_other_service():
    other = ServiceCategory(name="أخرى", is_other=True)
    assert make_service(other, label=" منسق حفلات ").display_title == "منسق حفلات"


def test_the_category_is_shown_even_when_an_old_title_exists():
    service = make_service(ServiceCategory(name="كهرباء", is_other=False), title="Old name")
    assert service.display_title == "كهرباء"
    assert service.title == "Old name"            # the stored data is untouched


def test_responses_carry_display_title_and_allow_null_price_and_title():
    category = ServiceCategory(id=1, name="سباكة", is_other=False, is_active=True)
    provider = User(id=2, is_provider=True)
    provider.profile = None
    service = Service(
        id=5, title=None, description="أصلح التمديدات", price=None, price_unit="fixed",
        status=ServiceStatus.ACTIVE, is_remote=False, custom_category_label=None,
    )
    service.category = category
    service.provider = provider

    item = ServiceListItemResponse.model_validate(service).model_dump()
    assert item["display_title"] == "سباكة"
    assert item["title"] is None
    assert item["price"] is None

    from datetime import datetime
    service.created_at = datetime(2026, 11, 13)
    full = ServiceResponse.model_validate(service).model_dump()
    assert (full["display_title"], full["price"], full["title"]) == ("سباكة", None, None)


def test_an_existing_service_with_a_price_and_title_is_still_valid():
    category = ServiceCategory(id=1, name="سباكة", is_other=False, is_active=True)
    provider = User(id=2, is_provider=True)
    provider.profile = None
    service = Service(
        id=5, title="سباك محترف", description="أصلح التمديدات", price=Decimal("25.50"),
        price_unit="fixed", status=ServiceStatus.ACTIVE, is_remote=False,
    )
    service.category = category
    service.provider = provider
    item = ServiceListItemResponse.model_validate(service)
    assert item.price == Decimal("25.50")
    assert item.title == "سباك محترف"


# ================================================================= migration

def test_the_migration_relaxes_not_null_and_refuses_a_lossy_downgrade():
    path = os.path.join(ALEMBIC_DIR, "c9d0e1f2a3b4_optional_service_title_and_price.py")
    source = open(path, encoding="utf-8").read()
    assert 'down_revision: Union[str, None] = "b8c9d0e1f2a3"' in source
    assert '"services", "title"' in source and '"services", "price"' in source
    upgrade = source.split("def upgrade()")[1].split("def downgrade()")[0]
    assert upgrade.count("nullable=True") == 2
    assert "UPDATE" not in upgrade and "DELETE" not in upgrade     # no data rewritten
    downgrade = source.split("def downgrade()")[1]
    assert "IS NULL" in downgrade and "raise RuntimeError" in downgrade
    assert "DELETE" not in downgrade                                 # nothing destroyed


def test_the_migration_is_the_single_head():
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    ini = os.path.join(os.path.dirname(__file__), "..", "alembic.ini")
    config = Config(ini)
    config.set_main_option("script_location", os.path.join(os.path.dirname(__file__), "..", "alembic"))
    assert ScriptDirectory.from_config(config).get_heads() == ["c9d0e1f2a3b4"]


# ========================================================= nearby (real SQL)

ORIGIN = (33.5138, 36.2765)            # Damascus
PLUMBING, ELECTRICAL = 1, 2


def _point(km_north=0.0, km_east=0.0, origin=ORIGIN):
    """A point the given distance north/east of `origin` (spherical earth)."""
    km_per_deg = EARTH_RADIUS_KM * math.pi / 180
    lat = origin[0] + km_north / km_per_deg
    lon = origin[1] + km_east / (km_per_deg * math.cos(math.radians(origin[0])))
    return lat, lon


@pytest.fixture
def geo_db():
    """An in-memory SQLite database with just the tables nearby search reads."""
    engine = create_engine("sqlite://")

    @event.listens_for(engine, "connect")
    def _math(dbapi_conn, _):
        dbapi_conn.create_function("radians", 1, math.radians)
        dbapi_conn.create_function("cos", 1, math.cos)
        dbapi_conn.create_function("sin", 1, math.sin)
        dbapi_conn.create_function("acos", 1, math.acos)
        dbapi_conn.create_function("greatest", 2, max)
        dbapi_conn.create_function("least", 2, min)

    tables = [t.__table__ for t in (User, UserProfile, ServiceCategory, Service)]
    Base.metadata.create_all(engine, tables=tables)
    session = Session(engine)
    session.add_all([
        ServiceCategory(id=PLUMBING, name="سباكة", is_other=False, is_active=True),
        ServiceCategory(id=ELECTRICAL, name="كهرباء", is_other=False, is_active=True),
    ])
    session.commit()
    state = SimpleNamespace(session=session, next_id=1)

    def add(name, location, category=PLUMBING, *, on_profile=False, status=ServiceStatus.ACTIVE,
            provider_active=True, provider_id=None):
        pid = provider_id or state.next_id
        state.next_id += 1
        if session.get(User, pid) is None:
            session.add(User(id=pid, email=f"u{pid}@x.com", hashed_password="x", is_active=provider_active))
            session.add(UserProfile(
                user_id=pid, full_name=f"P{pid}",
                latitude=location[0] if on_profile else None,
                longitude=location[1] if on_profile else None,
            ))
        session.add(Service(
            provider_id=pid, category_id=category, title=name, description="وصف الخدمة",
            price=None, status=status,
            latitude=None if on_profile else location[0],
            longitude=None if on_profile else location[1],
        ))
        session.commit()

    state.add = add
    yield state
    session.close()


def _search(geo_db, origin=ORIGIN, radius_km=10.0, **kw):
    exclude = kw.pop("exclude_provider_id", None)
    params = ServiceSearchParams(latitude=origin[0], longitude=origin[1], radius_km=radius_km, **kw)
    return [
        (service.title, round(distance, 2))
        for service, distance in search_service.search_services(
            geo_db.session, params, exclude_provider_id=exclude
        )
    ]


def test_nearby_returns_only_the_selected_category(geo_db):
    geo_db.add("plumber", _point(km_north=1), PLUMBING)
    geo_db.add("electrician", _point(km_north=0.5), ELECTRICAL)

    assert [t for t, _ in _search(geo_db, category_id=PLUMBING)] == ["plumber"]
    assert [t for t, _ in _search(geo_db, category_id=ELECTRICAL)] == ["electrician"]
    assert {t for t, _ in _search(geo_db)} == {"plumber", "electrician"}   # no filter


def test_nearby_is_sorted_nearest_first_with_correct_distances(geo_db):
    geo_db.add("far", _point(km_east=7))
    geo_db.add("near", _point(km_north=0.5))
    geo_db.add("middle", _point(km_north=-3))

    results = _search(geo_db, category_id=PLUMBING)

    assert [t for t, _ in results] == ["near", "middle", "far"]
    assert [d for _, d in results] == pytest.approx([0.5, 3.0, 7.0], abs=0.01)


def test_nearby_excludes_services_outside_the_radius(geo_db):
    geo_db.add("inside", _point(km_north=9.9))
    geo_db.add("outside", _point(km_north=10.1))
    geo_db.add("corner", _point(km_north=7.2, km_east=7.2))     # in the box, ~10.2 km away

    assert [t for t, _ in _search(geo_db, radius_km=10)] == ["inside"]


def test_the_category_filter_is_combined_with_the_radius(geo_db):
    geo_db.add("plumber far away", _point(km_north=50), PLUMBING)
    geo_db.add("electrician nearby", _point(km_north=1), ELECTRICAL)
    assert _search(geo_db, radius_km=10, category_id=PLUMBING) == []


def test_latitude_and_longitude_are_not_swapped(geo_db):
    # A point 5 km north. If lat/lon were swapped anywhere, the distance
    # would come out wrong (or the point would be missed altogether).
    geo_db.add("north", _point(km_north=5))
    [(_, distance)] = _search(geo_db)
    expected = haversine_distance_km(*ORIGIN, *_point(km_north=5))
    assert distance == pytest.approx(expected, abs=0.01)
    assert distance == pytest.approx(5.0, abs=0.01)


def test_the_provider_profile_location_is_used_when_the_service_has_none(geo_db):
    geo_db.add("from profile", _point(km_east=2), on_profile=True)
    assert _search(geo_db) == [("from profile", pytest.approx(2.0, abs=0.01))]


def test_only_available_services_are_returned(geo_db):
    geo_db.add("active", _point(km_north=1))
    geo_db.add("paused", _point(km_north=1), status=ServiceStatus.INACTIVE)
    geo_db.add("suspended", _point(km_north=1), status=ServiceStatus.SUSPENDED)
    geo_db.add("deactivated provider", _point(km_north=1), provider_active=False)
    assert [t for t, _ in _search(geo_db)] == ["active"]


def test_the_callers_own_services_are_left_out(geo_db):
    geo_db.add("mine", _point(km_north=1), provider_id=50)
    geo_db.add("theirs", _point(km_north=2), provider_id=51)
    assert [t for t, _ in _search(geo_db, exclude_provider_id=50)] == ["theirs"]


def test_services_without_any_location_are_left_out(geo_db):
    geo_db.add("nowhere", (None, None))
    assert _search(geo_db) == []


# ======================================================= nearby parameters

def test_default_radius_comes_from_settings():
    params = ServiceSearchParams(latitude=33.5, longitude=36.3)
    assert params.radius_km == settings.NEARBY_DEFAULT_RADIUS_KM == 25.0


@pytest.mark.parametrize("bad", [
    {"latitude": "nan", "longitude": 36.3},
    {"latitude": 33.5, "longitude": "inf"},
    {"latitude": 91, "longitude": 36.3},
    {"latitude": 33.5, "longitude": -181},
    {"latitude": 33.5, "longitude": 36.3, "radius_km": settings.NEARBY_MAX_RADIUS_KM + 1},
    {"latitude": 33.5, "longitude": 36.3, "category_id": 0},
    {"longitude": 36.3},
    {"latitude": 33.5},
])
def test_invalid_or_missing_parameters_are_rejected(bad):
    with pytest.raises(ValueError):
        ServiceSearchParams(**bad)


@pytest.mark.parametrize("query", [
    "latitude=nan&longitude=36.3",
    "latitude=33.5",
    "latitude=33.5&longitude=36.3&category_id=abc",
    "latitude=abc&longitude=36.3",
])
def test_the_endpoint_rejects_invalid_coordinates(client, query):
    assert client.get(f"/api/v1/search/services?{query}").status_code == 422


@pytest.mark.parametrize("lat, radius", [(0, 200), (33.5, 25), (33.5, 200), (60, 100), (-45, 150)])
def test_the_bounding_box_covers_every_point_on_the_radius_circle(lat, radius):
    """Points just inside the circle, all around it, are inside the pre-filter box."""
    min_lat, max_lat, min_lon, max_lon = bounding_box(lat, 36.3, radius)
    d = radius * 0.999 / EARTH_RADIUS_KM
    p1, l1 = math.radians(lat), math.radians(36.3)
    for tenth in range(3600):
        t = math.radians(tenth / 10)
        p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(t))
        l2 = l1 + math.atan2(math.sin(t) * math.sin(d) * math.cos(p1),
                             math.cos(d) - math.sin(p1) * math.sin(p2))
        assert min_lat <= math.degrees(p2) <= max_lat
        assert min_lon <= math.degrees(l2) <= max_lon
