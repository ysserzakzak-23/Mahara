"""
Lookup / list helpers in the service layer. The DB session is a fake; what we
verify is that the right query is built (filters, joins, ordering) and that
"not found" becomes a 404 instead of returning None.
"""
from types import SimpleNamespace

import pytest

from app.core.exceptions import NotFoundError
from app.models.service import ServiceStatus
from app.services import (
    admin_service,
    appointment_service,
    barter_preference_service,
    exchange_service,
    portfolio_service,
    review_service,
    service_service,
    user_service,
)
from tests.helpers import make_result, where_clause


def sql(db):
    return str(db.execute.call_args.args[0])


def returns_one(db, value):
    db.execute.return_value = make_result(scalar_one_or_none=value)


def returns_many(db, items=()):
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: list(items)))


# ------------------------------------------------------------ "not found" -> 404
@pytest.mark.parametrize(
    "call, message",
    [
        (lambda db: exchange_service.get_request_by_id(db, 1), "طلب التبادل غير موجود"),
        (lambda db: exchange_service.get_proposal_by_id(db, 1), "عرض التبادل غير موجود"),
        (lambda db: appointment_service.get_appointment_by_id(db, 1), "الموعد غير موجود"),
        (lambda db: service_service.get_service_by_id(db, 1), "الخدمة غير موجودة"),
        (lambda db: admin_service.get_user_by_id(db, 1), "المستخدم غير موجود"),
    ],
)
def test_missing_rows_raise_not_found(db, call, message):
    returns_one(db, None)
    with pytest.raises(NotFoundError, match=message):
        call(db)


@pytest.mark.parametrize(
    "call",
    [
        lambda db: exchange_service.get_request_by_id(db, 1),
        lambda db: exchange_service.get_proposal_by_id(db, 1),
        lambda db: appointment_service.get_appointment_by_id(db, 1),
        lambda db: service_service.get_service_by_id(db, 1),
        lambda db: admin_service.get_user_by_id(db, 1),
    ],
)
def test_existing_rows_are_returned_as_is(db, call):
    row = object()
    returns_one(db, row)
    assert call(db) is row


def test_user_lookup_by_id(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        user_service.get_user_by_id(db, 5)

    user = object()
    db.get.return_value = user
    assert user_service.get_user_by_id(db, 5) is user


def test_user_lookup_by_email_returns_none_when_unknown(db):
    returns_one(db, None)
    assert user_service.get_user_by_email(db, "nobody@example.com") is None
    assert "email" in where_clause(db.execute.call_args.args[0])


# ----------------------------------------------------------------- list queries
def test_open_exchange_requests_filter_by_status(db):
    returns_many(db)
    exchange_service.list_open_requests(db)
    assert "status" in where_clause(db.execute.call_args.args[0])
    assert "!=" not in where_clause(db.execute.call_args.args[0])


def test_open_exchange_requests_can_exclude_a_user(db):
    returns_many(db)
    exchange_service.list_open_requests(db, exclude_user_id=7)
    assert "!=" in where_clause(db.execute.call_args.args[0])


def test_my_exchange_requests_filter_by_owner(db):
    returns_many(db, ["a"])
    result = exchange_service.list_my_requests(db, SimpleNamespace(id=3))
    assert result == ["a"]
    assert "user_id" in where_clause(db.execute.call_args.args[0])


def test_sent_proposals_filter_by_proposer_without_a_join(db):
    returns_many(db)
    exchange_service.list_my_proposals(db, SimpleNamespace(id=3), sent=True)
    assert "proposer_id" in where_clause(db.execute.call_args.args[0])
    assert "JOIN" not in sql(db)


def test_received_proposals_join_the_request_owner(db):
    returns_many(db)
    exchange_service.list_my_proposals(db, SimpleNamespace(id=3), sent=False)
    assert "JOIN" in sql(db)
    assert "exchange_requests.user_id" in where_clause(db.execute.call_args.args[0])


def test_appointments_list_uses_customer_or_provider_column_and_newest_first(db):
    returns_many(db)

    appointment_service.list_my_appointments(db, SimpleNamespace(id=3))
    customer_query = db.execute.call_args.args[0]
    appointment_service.list_my_appointments(db, SimpleNamespace(id=3), as_provider=True)
    provider_query = db.execute.call_args.args[0]

    assert "customer_id" in where_clause(customer_query)
    assert "provider_id" not in where_clause(customer_query)
    assert "provider_id" in where_clause(provider_query)
    assert "customer_id" not in where_clause(provider_query)
    assert "DESC" in str(customer_query)


def test_moderation_list_filters_only_when_asked(db):
    returns_many(db)

    admin_service.list_services_for_moderation(db)
    unfiltered = where_clause(db.execute.call_args.args[0])
    admin_service.list_services_for_moderation(db, status_filter=ServiceStatus.SUSPENDED)
    filtered = where_clause(db.execute.call_args.args[0])

    assert "status" not in unfiltered
    assert "status" in filtered


def test_services_of_a_provider(db):
    returns_many(db, ["s"])
    assert service_service.list_services_by_provider(db, 9) == ["s"]
    assert "provider_id" in where_clause(db.execute.call_args.args[0])


def test_portfolio_listing_checks_the_service_exists_and_orders_items(db, monkeypatch):
    checked = []
    monkeypatch.setattr(portfolio_service, "get_service_by_id", lambda db, sid: checked.append(sid))
    returns_many(db, ["p1", "p2"])

    assert portfolio_service.list_portfolio_items(db, 100) == ["p1", "p2"]
    assert checked == [100]
    assert "display_order" in sql(db).split("ORDER BY")[1]


def test_portfolio_listing_of_a_missing_service_is_404(db, monkeypatch):
    def missing(db, sid):
        raise NotFoundError("الخدمة غير موجودة")

    monkeypatch.setattr(portfolio_service, "get_service_by_id", missing)
    with pytest.raises(NotFoundError):
        portfolio_service.list_portfolio_items(db, 1)
    db.execute.assert_not_called()


def test_reviews_listing_is_newest_first_and_checks_the_service(db, monkeypatch):
    checked = []
    monkeypatch.setattr(review_service, "get_service_by_id", lambda db, sid: checked.append(sid))
    returns_many(db, ["r"])

    assert review_service.list_reviews_for_service(db, 100) == ["r"]
    assert checked == [100]
    assert "created_at DESC" in sql(db)


def test_my_barter_preferences_filter_by_owner(db):
    returns_many(db, ["pref"])
    assert barter_preference_service.list_my_preferences(db, SimpleNamespace(id=4)) == ["pref"]
    assert "user_id" in where_clause(db.execute.call_args.args[0])
