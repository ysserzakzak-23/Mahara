"""
SQL statement counts of hot read paths (N+1 regression tests).

The real service functions run against an in-memory SQLite database and every
statement they emit is recorded. A path that eager-loads correctly issues the
same number of statements however many rows / categories / results it returns;
an N+1 shows up as a count that grows with the data.

Nothing here touches PostgreSQL or the project's database.
"""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session

import app.models  # noqa: F401  (registers every mapper)
import app.models.exchange  # noqa: F401
from app.core.database import Base
from app.models import (
    Appointment,
    AppointmentStatus,
    Review,
    Service,
    ServiceCategory,
    ServiceStatus,
    User,
    UserProfile,
)
from app.schemas.appointment import AppointmentResponse
from app.schemas.semantic_search import SemanticSearchParams, SmartSearchParams
from app.services import appointment_service
from app.services import semantic_search_service as sem
from app.services import smart_search_service as smart

CUSTOMER, PROVIDER = 1, 2
NOW = datetime(2026, 11, 2, 9, 0, tzinfo=timezone.utc)


@pytest.fixture
def sqlite():
    """(session, statements): a fresh database and the log of SQL sent to it."""
    engine = create_engine("sqlite://")
    statements: list[str] = []

    @event.listens_for(engine, "before_cursor_execute")
    def _record(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    Base.metadata.create_all(engine)
    session = Session(engine)
    for user_id in (CUSTOMER, PROVIDER, 3, 4):
        session.add(User(id=user_id, email=f"u{user_id}@x.com", hashed_password="x", is_active=True))
        session.add(UserProfile(user_id=user_id, full_name=f"User {user_id}"))
    session.commit()
    yield SimpleNamespace(session=session, statements=statements)
    session.close()


def _categories(db, count):
    db.session.add_all(
        ServiceCategory(id=i, name=f"تصنيف {i}", is_other=False, is_active=True)
        for i in range(1, count + 1)
    )
    db.session.commit()


def _service(db, service_id, category_id, title=None, description="وصف الخدمة"):
    db.session.add(Service(
        id=service_id, provider_id=PROVIDER, category_id=category_id, title=title,
        description=description, price=None, status=ServiceStatus.ACTIVE,
    ))


def _fresh(db):
    """Forget loaded objects and the statement log (like a new request would)."""
    db.session.expunge_all()
    db.statements.clear()


# ================================================= appointments (audit B1)

def _book(db, n_appointments, n_categories):
    _categories(db, n_categories)
    for i in range(1, n_appointments + 1):
        _service(db, i, category_id=(i % n_categories) + 1)
        db.session.add(Appointment(
            customer_id=CUSTOMER, provider_id=PROVIDER, service_id=i,
            start_time=NOW + timedelta(days=i), end_time=NOW + timedelta(days=i, hours=1),
            status=AppointmentStatus.PENDING,
        ))
    db.session.commit()


def _my_appointments(db):
    """What GET /appointments/me does: load, then serialise every row."""
    _fresh(db)
    rows, _has_next = appointment_service.list_my_appointments(
        db.session, SimpleNamespace(id=CUSTOMER)
    )
    return [AppointmentResponse.model_validate(row) for row in rows]


@pytest.mark.parametrize("n_categories", [1, 4, 12])
def test_appointment_list_query_count_does_not_grow_with_categories(sqlite, n_categories):
    _book(sqlite, n_appointments=24, n_categories=n_categories)

    responses = _my_appointments(sqlite)

    assert len(responses) == 24
    # appointments + customer + provider + their profiles + services + categories
    assert len(sqlite.statements) == 7, "\n".join(sqlite.statements)
    assert sum("FROM service_categories" in s for s in sqlite.statements) == 1


def test_appointment_list_query_count_does_not_grow_with_rows(sqlite):
    _book(sqlite, n_appointments=3, n_categories=3)
    _my_appointments(sqlite)
    few = len(sqlite.statements)

    for i in range(4, 40):     # 36 more bookings on more services
        _service(sqlite, i, category_id=(i % 3) + 1)
        sqlite.session.add(Appointment(
            customer_id=CUSTOMER, provider_id=PROVIDER, service_id=i,
            start_time=NOW + timedelta(days=i), end_time=NOW + timedelta(days=i, hours=1),
            status=AppointmentStatus.PENDING,
        ))
    sqlite.session.commit()
    _my_appointments(sqlite)

    assert len(sqlite.statements) == few


def test_appointment_titles_filtering_and_order_are_unchanged(sqlite):
    _book(sqlite, n_appointments=5, n_categories=5)
    # Somebody else's appointment must not appear.
    sqlite.session.add(Appointment(
        customer_id=3, provider_id=PROVIDER, service_id=1,
        start_time=NOW + timedelta(days=50), end_time=NOW + timedelta(days=50, hours=1),
        status=AppointmentStatus.PENDING,
    ))
    sqlite.session.commit()

    responses = _my_appointments(sqlite)

    assert [r.service_id for r in responses] == [5, 4, 3, 2, 1]          # latest first
    # service i is filed under category (i % 5) + 1, and is named by it.
    assert [r.service_title for r in responses] == [
        f"تصنيف {(i % 5) + 1}" for i in (5, 4, 3, 2, 1)
    ]
    assert all(r.customer.id == CUSTOMER for r in responses)


def test_a_single_appointment_also_loads_its_category_eagerly(sqlite):
    _book(sqlite, n_appointments=1, n_categories=1)
    appointment_id = sqlite.session.query(Appointment.id).scalar()
    _fresh(sqlite)

    appointment = appointment_service.get_appointment_by_id(sqlite.session, appointment_id)
    before_serialising = len(sqlite.statements)
    assert AppointmentResponse.model_validate(appointment).service_title == "تصنيف 1"

    assert len(sqlite.statements) == before_serialising       # nothing lazy-loaded


# ============================================ search ratings (audit B2)

PLUMBING = 1


def _catalog(db, n_plumbers, reviewed):
    """`n_plumbers` matching services; ids in `reviewed` get reviews."""
    _categories(db, 2)
    for i in range(1, n_plumbers + 1):
        _service(db, i, PLUMBING, title="سباك محترف", description="تصليح حنفيات وتسريب مياه")
    _service(db, 900, 2, title="كهربائي", description="تمديدات كهربائية")
    for service_id, ratings in reviewed.items():
        for reviewer, rating in zip((CUSTOMER, 3, 4), ratings):
            db.session.add(Review(reviewer_id=reviewer, service_id=service_id, rating=rating))
    db.session.commit()


def _rating_queries(db):
    return [s for s in db.statements if "FROM reviews" in s]


def _smart(db, limit=30):
    _fresh(db)
    return smart.search_services_smart(db.session, SmartSearchParams(q="بدي اصلح حنفية", limit=limit))


@pytest.fixture(autouse=True)
def _model(monkeypatch):
    """Search ranks by meaning only, so it needs a model: fixed vectors under
    which the plumbers match «حنفية» and the electrician does not."""
    monkeypatch.setattr(smart, "_semantic_failed", False)
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", True)
    monkeypatch.setattr(sem, "_embed", lambda text: [1.0, 0.0])
    monkeypatch.setattr(sem, "_calibration_centroid", lambda lang: [0.0, 0.0])
    monkeypatch.setattr(
        sem,
        "_cached_chunk_embeddings",
        lambda s: [([1.0, 0.0] if "سباك" in s.title else [0.0, 1.0], sem._searchable_chunks(s)[0])],
    )


@pytest.mark.parametrize("n_results", [1, 5, 25])
def test_smart_search_reads_all_ratings_in_one_query(sqlite, n_results):
    _catalog(sqlite, n_plumbers=n_results, reviewed={1: (5, 4)})

    results = _smart(sqlite)

    assert len(results) == n_results
    assert len(_rating_queries(sqlite)) == 1, "\n".join(sqlite.statements)
    # services + category + provider + profile + ratings, whatever the page size
    assert len(sqlite.statements) == 5


def test_smart_search_ratings_are_identical_to_the_per_service_lookup(sqlite):
    _catalog(sqlite, n_plumbers=6, reviewed={1: (5, 4, 4), 2: (3,), 4: (5, 5), 5: (1, 2, 2)})

    results = _smart(sqlite)

    assert len(results) == 6
    for service, _score, rating in results:
        # `_service_rating` is the original one-query-per-service implementation.
        assert rating == sem._service_rating(sqlite.session, service.id), service.id
    by_id = {service.id: rating for service, _, rating in results}
    assert by_id[1] == (4.33, 3)          # rounded to two decimals
    assert by_id[2] == (3.0, 1)
    assert by_id[3] == (0.0, 0)           # no reviews -> (0.0, 0), as before
    assert by_id[5] == (1.67, 3)


def test_smart_search_order_and_scores_do_not_depend_on_ratings(sqlite):
    _catalog(sqlite, n_plumbers=4, reviewed={})
    unrated = [(s.id, score) for s, score, _ in _smart(sqlite)]

    for reviewer, service_id, rating in ((CUSTOMER, 4, 5), (3, 4, 5), (CUSTOMER, 2, 1)):
        sqlite.session.add(Review(reviewer_id=reviewer, service_id=service_id, rating=rating))
    sqlite.session.commit()
    rated = [(s.id, score) for s, score, _ in _smart(sqlite)]

    assert rated == unrated               # relevance and tie-breaking untouched


def test_smart_search_limit_only_rates_the_returned_page(sqlite):
    _catalog(sqlite, n_plumbers=10, reviewed={})

    results = _smart(sqlite, limit=3)

    assert len(results) == 3
    assert len(_rating_queries(sqlite)) == 1


def test_smart_search_without_results_reads_no_ratings(sqlite):
    _catalog(sqlite, n_plumbers=0, reviewed={})
    _fresh(sqlite)

    results = smart.search_services_smart(sqlite.session, SmartSearchParams(q="نجار"))

    assert results == []
    assert _rating_queries(sqlite) == []


def test_service_ratings_helper_handles_empty_and_unrated(sqlite):
    _catalog(sqlite, n_plumbers=2, reviewed={1: (4, 5)})
    _fresh(sqlite)

    assert sem.service_ratings(sqlite.session, []) == {}
    assert sqlite.statements == []                         # no query for nothing

    assert sem.service_ratings(sqlite.session, [1, 2, 777]) == {
        1: (4.5, 2), 2: (0.0, 0), 777: (0.0, 0),
    }
    assert len(sqlite.statements) == 1


# ---------------------------------------------------------------- semantic

@pytest.fixture
def embeddings(monkeypatch):
    """The embedding model replaced by fixed vectors: every service scores 1.0."""
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", True)
    monkeypatch.setattr(
        sem, "_cached_chunk_embeddings", lambda s: [([1.0, 0.0], sem._searchable_chunks(s)[0])]
    )
    monkeypatch.setattr(sem, "_embed", lambda text: [1.0, 0.0])
    monkeypatch.setattr(sem, "_calibration_centroid", lambda lang: [0.0, 0.0])


def _semantic(db, **params):
    _fresh(db)
    params.setdefault("q", "سباك")
    return sem.search_services_semantic(db.session, SemanticSearchParams(**params))


@pytest.mark.parametrize("limit", [1, 5, 20])
def test_semantic_search_reads_all_ratings_in_one_query(sqlite, embeddings, limit):
    _catalog(sqlite, n_plumbers=20, reviewed={1: (5,)})

    results = _semantic(sqlite, limit=limit)

    assert len(results) == limit
    assert len(_rating_queries(sqlite)) == 1, "\n".join(sqlite.statements)
    assert len(sqlite.statements) == 5


def test_semantic_search_ratings_are_identical_to_the_per_service_lookup(sqlite, embeddings):
    _catalog(sqlite, n_plumbers=5, reviewed={1: (5, 4, 4), 3: (2,), 5: (5, 5)})

    results = _semantic(sqlite, limit=50)

    assert len(results) == 6              # the 5 plumbers and the electrician
    for service, _score, rating in results:
        assert rating == sem._service_rating(sqlite.session, service.id), service.id
    by_id = {service.id: rating for service, _, rating in results}
    assert by_id[1] == (4.33, 3) and by_id[2] == (0.0, 0) and by_id[900] == (0.0, 0)


def test_semantic_search_without_results_reads_no_ratings(sqlite, embeddings):
    _categories(sqlite, 1)

    assert _semantic(sqlite) == []
    assert _rating_queries(sqlite) == []
