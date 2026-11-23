import math
import random

import pytest
from sqlalchemy import column

from app.algorithms.geo import (
    EARTH_RADIUS_KM,
    bounding_box,
    haversine_distance_expr,
    haversine_distance_km,
)

DAMASCUS = (33.5138, 36.2765)
ALEPPO = (36.2021, 37.1343)


def test_same_point_is_zero():
    assert haversine_distance_km(*DAMASCUS, *DAMASCUS) == pytest.approx(0.0, abs=1e-9)


def test_distance_is_symmetric():
    ab = haversine_distance_km(*DAMASCUS, *ALEPPO)
    ba = haversine_distance_km(*ALEPPO, *DAMASCUS)
    assert ab == pytest.approx(ba)


def test_damascus_to_aleppo_is_roughly_300km():
    d = haversine_distance_km(*DAMASCUS, *ALEPPO)
    assert 290 < d < 320


def test_one_degree_of_latitude_is_about_111km():
    d = haversine_distance_km(0, 0, 1, 0)
    assert d == pytest.approx(111.19, rel=0.01)


def test_antipodal_points_are_half_the_circumference():
    d = haversine_distance_km(0, 0, 0, 180)
    assert d == pytest.approx(math.pi * EARTH_RADIUS_KM, rel=1e-6)


def test_triangle_inequality_holds():
    a, b, c = (0.0, 0.0), (10.0, 10.0), (20.0, 5.0)
    ab = haversine_distance_km(*a, *b)
    bc = haversine_distance_km(*b, *c)
    ac = haversine_distance_km(*a, *c)
    assert ac <= ab + bc + 1e-9


# ---------------------------------------------------------------- bounding box

def test_bounding_box_contains_its_center_and_is_ordered():
    min_lat, max_lat, min_lon, max_lon = bounding_box(*DAMASCUS, 10)
    assert min_lat < DAMASCUS[0] < max_lat
    assert min_lon < DAMASCUS[1] < max_lon


def test_bounding_box_latitude_span_matches_radius():
    min_lat, max_lat, _, _ = bounding_box(0.0, 0.0, 111.0)
    assert max_lat - min_lat == pytest.approx(2.0)


def test_bounding_box_longitude_widens_away_from_equator():
    _, _, lo_eq, hi_eq = bounding_box(0.0, 0.0, 50)
    _, _, lo_hi, hi_hi = bounding_box(60.0, 0.0, 50)
    assert (hi_hi - lo_hi) > (hi_eq - lo_eq)


def test_bounding_box_latitude_is_clamped_at_poles():
    min_lat, max_lat, _, _ = bounding_box(89.9, 0.0, 500)
    assert max_lat == 90.0
    min_lat, max_lat, _, _ = bounding_box(-89.9, 0.0, 500)
    assert min_lat == -90.0


def test_bounding_box_never_excludes_points_inside_the_radius():
    """The docstring's promise: the box may over-include but never under-include."""
    rng = random.Random(42)
    center_lat, center_lon, radius = 33.5, 36.3, 25.0
    min_lat, max_lat, min_lon, max_lon = bounding_box(center_lat, center_lon, radius)

    checked = 0
    for _ in range(2000):
        lat = center_lat + rng.uniform(-0.5, 0.5)
        lon = center_lon + rng.uniform(-0.5, 0.5)
        if haversine_distance_km(center_lat, center_lon, lat, lon) <= radius:
            checked += 1
            assert min_lat <= lat <= max_lat
            assert min_lon <= lon <= max_lon
    assert checked > 0  # sanity: the sample really did contain inside-points


# ----------------------------------------------------------------- SQL builder

def test_haversine_expr_compiles_to_clamped_acos():
    expr = haversine_distance_expr(column("lat"), column("lon"), 33.5, 36.3)
    sql = str(expr.compile()).lower()
    assert "acos" in sql
    assert "greatest" in sql and "least" in sql  # the NaN-protection clamp
