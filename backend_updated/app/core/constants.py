"""
Fixed reference data that doesn't warrant its own database table.

CITIES is intentionally a hard-coded Python list rather than a DB table
(unlike ServiceCategory): the set of cities the platform operates in
changes far less often than categories, doesn't need admin CRUD, and
keeping it in code means it can be validated with a plain `in` check
with zero extra queries on the hot registration/search paths. If this
ever needs to grow into an admin-managed table, mirror the
ServiceCategory pattern in app/models/category.py.
"""

CITIES: list[str] = [
    "دمشق",
    "ريف دمشق",
    "حلب",
    "حمص",
    "حماة",
    "اللاذقية",
    "طرطوس",
    "إدلب",
    "درعا",
    "السويداء",
    "القنيطرة",
    "دير الزور",
    "الرقة",
    "الحسكة",
]
