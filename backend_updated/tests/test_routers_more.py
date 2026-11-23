"""
Router wiring for every remaining endpoint.

The service layer is replaced by a stub that returns plain dicts shaped like
the response schemas (pydantic accepts dicts for `model_validate`). This
verifies, per endpoint: URL + HTTP method, auth rule (401 without a token),
status code, request-body/query handling, and that the response is serialised
through the right schema. The business rules themselves are tested in the
service tests.
"""
from datetime import datetime, time, timedelta
from decimal import Decimal
from types import SimpleNamespace

import pytest

from app.core.exceptions import ServiceUnavailableError
from app.models.user import UserRole
from app.routers import uploads
from app.services import (
    admin_service,
    appointment_service,
    availability_service,
    barter_matching_service,
    barter_preference_service,
    category_service,
    exchange_service,
    notification_service,
    portfolio_service,
    review_service,
    search_service,
    semantic_search_service,
    service_service,
    user_service,
)
from tests.test_routers import client, fake_db, login_as  # noqa: F401  (shared fixtures)

NOW = datetime(2026, 10, 5, 12, 0)


# ----------------------------------------------------------------- payloads
def user_public(id=1, provider=False):
    return {"id": id, "is_provider": provider, "profile": {"full_name": "Ahmad"}}


def category(id=1, name="Plumbing"):
    return {"id": id, "name": name, "description": None, "icon_name": None,
            "is_active": True, "is_other": False}


def service_item(id=100):
    return {"id": id, "title": "Fix pipes", "display_title": "Plumbing",
            "price": "25.50", "price_unit": "fixed",
            "status": "active", "cover_image_url": None, "is_remote": False,
            "custom_category_label": None, "category": category(),
            "provider": user_public(2, True)}


def service_full(id=100):
    return {**service_item(id), "description": "I fix all kinds of pipes",
            "latitude": None, "longitude": None, "created_at": NOW}


def appointment(id=5):
    return {"id": id, "service_id": 100, "service_title": "Fix pipes",
            "start_time": NOW, "end_time": NOW + timedelta(hours=1), "status": "pending",
            "customer_notes": None, "cancellation_reason": None, "created_at": NOW,
            "customer": user_public(1), "provider": user_public(2, True)}


def window(id=1):
    return {"id": id, "day_of_week": 0, "start_time": time(9), "end_time": time(17), "is_active": True}


def preference(id=1):
    return {"id": id, "is_active": True, "offered_category": category(1),
            "needed_category": category(2, "Electrical")}


def exchange_request(id=7):
    return {"id": id, "status": "open", "user": user_public(10),
            "offered_service": service_item(), "offered_category": category(1),
            "wanted_category": category(2, "Electrical"), "wanted_custom_category_label": None}


def ranked_request(id=7, rating=4.5, count=2, relevance=None):
    """What exchange_service.list_interests / search_requests return."""
    return (exchange_request(id), rating, count, relevance)


def proposal(id=3):
    return {"id": id, "status": "pending", "message": None, "proposer": user_public(20),
            "proposed_service": service_item(55), "request": exchange_request()}


def notification(id=1):
    return {"id": id, "type": "system", "title": "T", "message": "M",
            "related_entity_id": None, "is_read": False, "created_at": NOW}


def device():
    return {"id": 1, "device_label": None, "is_active": True, "created_at": NOW}


def photo(id=1):
    return {"id": id, "service_id": 100, "image_url": "/uploads/a.jpg",
            "caption": None, "display_order": 0}


def review(id=1):
    return {"id": id, "service_id": 100, "rating": 5, "comment": None,
            "created_at": NOW, "updated_at": NOW, "reviewer": user_public(1)}


def full_user(id=1):
    return {"id": id, "email": f"u{id}@example.com", "role": "user", "is_provider": False,
            "is_active": True, "created_at": NOW, "profile": None}


def admin_service_row(id=1, status="active"):
    return {"id": id, "title": "T", "display_title": "Plumbing", "price": "10.00", "status": status,
            "provider_id": 2, "category_id": 1, "created_at": NOW}


# --------------------------------------------------------------- the table
# (method, path, json body, module, function, value returned, expected status)
PUBLIC = [
    ("GET", "/api/v1/services", None, service_service, "list_active_services", [service_item()], 200),
    ("GET", "/api/v1/services/100", None, service_service, "get_service_by_id", service_full(), 200),
    ("GET", "/api/v1/services/provider/2", None, service_service, "list_services_by_provider", [service_item()], 200),
    ("GET", "/api/v1/services/100/portfolio", None, portfolio_service, "list_portfolio_items", [photo()], 200),
    ("GET", "/api/v1/services/100/reviews", None, review_service, "list_reviews_for_service", [review()], 200),
    ("GET", "/api/v1/services/100/reviews/summary", None, review_service, "get_rating_summary",
     {"service_id": 100, "average_rating": 4.5, "review_count": 2}, 200),
    ("GET", "/api/v1/providers/2/availability", None, availability_service, "list_availability", [window()], 200),
    ("GET", "/api/v1/users/2", None, user_service, "get_user_by_id", user_public(2, True), 200),
    ("GET", "/api/v1/categories/1", None, category_service, "get_category_by_id", category(), 200),
    # Paginated: the router calls the *_page functions, which hand back
    # (rows, has_next). See test_pagination_exchange.py.
    ("GET", "/api/v1/exchange-requests", None, exchange_service, "list_open_requests_page",
     ([exchange_request()], False), 200),
    ("GET", "/api/v1/exchange-requests/search?q=%D8%A8%D8%B1%D9%85%D8%AC%D8%A9", None, exchange_service,
     "search_requests_page", ([ranked_request(relevance=0.8)], False), 200),
]

AUTHENTICATED = [
    # appointments
    # Paginated: the service hands the router (rows, has_next).
    ("GET", "/api/v1/appointments/me", None, appointment_service, "list_my_appointments", ([appointment()], False), 200),
    ("GET", "/api/v1/appointments/5", None, appointment_service, "get_appointment_for_user", appointment(), 200),
    ("POST", "/api/v1/appointments", {"service_id": 100, "start_time": "2026-10-05T10:00:00", "end_time": "2026-10-05T11:00:00"},
     appointment_service, "create_appointment", appointment(), 201),
    ("POST", "/api/v1/appointments/5/accept", None, appointment_service, "accept_appointment", appointment(), 200),
    ("POST", "/api/v1/appointments/5/reject", {"cancellation_reason": "full"}, appointment_service, "reject_appointment", appointment(), 200),
    ("POST", "/api/v1/appointments/5/cancel", {}, appointment_service, "cancel_appointment", appointment(), 200),
    ("POST", "/api/v1/appointments/5/complete", None, appointment_service, "mark_appointment_completed", appointment(), 200),
    # availability
    ("POST", "/api/v1/providers/1/availability", {"day_of_week": 0, "start_time": "09:00:00", "end_time": "17:00:00"},
     availability_service, "create_availability_window", window(), 201),
    ("DELETE", "/api/v1/providers/1/availability/3", None, availability_service, "deactivate_availability_window", None, 204),
    # barter preferences
    ("GET", "/api/v1/barter-preferences/me", None, barter_preference_service, "list_my_preferences", [preference()], 200),
    ("POST", "/api/v1/barter-preferences", {"offered_category_id": 1, "needed_category_id": 2},
     barter_preference_service, "create_preference", preference(), 201),
    ("DELETE", "/api/v1/barter-preferences/1", None, barter_preference_service, "deactivate_preference", None, 204),
    # exchange
    ("POST", "/api/v1/exchange-requests", {"offered_service_id": 100, "wanted_category_id": 2},
     exchange_service, "create_request", exchange_request(), 201),
    ("GET", "/api/v1/exchange-requests/me", None, exchange_service, "list_my_requests_page",
     ([exchange_request()], False), 200),
    ("GET", "/api/v1/exchange-requests/interests", None, exchange_service, "list_interests_page",
     ([ranked_request()], False), 200),
    ("GET", "/api/v1/exchange-requests/7/matches", None, exchange_service, "find_matches_for_request", [exchange_request(8)], 200),
    ("DELETE", "/api/v1/exchange-requests/7", None, exchange_service, "close_request", None, 204),
    ("POST", "/api/v1/exchange-requests/7/proposals", {"proposed_service_id": 55},
     exchange_service, "create_proposal", proposal(), 201),
    ("GET", "/api/v1/exchange-proposals/me", None, exchange_service, "list_my_proposals_page",
     ([proposal()], False), 200),
    ("POST", "/api/v1/exchange-proposals/3/accept", None, exchange_service, "respond_to_proposal", proposal(), 200),
    ("POST", "/api/v1/exchange-proposals/3/reject", None, exchange_service, "respond_to_proposal", proposal(), 200),
    # notifications
    # Paginated: the service hands the router (rows, has_next). See test_pagination_endpoints.py.
    ("GET", "/api/v1/notifications", None, notification_service, "list_my_notifications", ([notification()], False), 200),
    ("GET", "/api/v1/notifications/unread-count", None, notification_service, "get_unread_count", 4, 200),
    ("POST", "/api/v1/notifications/1/read", None, notification_service, "mark_notification_read", notification(), 200),
    ("POST", "/api/v1/notifications/read-all", None, notification_service, "mark_all_notifications_read", 3, 200),
    ("POST", "/api/v1/notifications/devices", {"fcm_token": "a-valid-fcm-token"}, notification_service, "register_push_device", device(), 201),
    ("DELETE", "/api/v1/notifications/devices/1", None, notification_service, "unregister_push_device", None, 204),
    ("POST", "/api/v1/notifications/test", None, notification_service, "send_test_notification", notification(), 201),
    # portfolio
    ("POST", "/api/v1/services/100/portfolio", {"image_url": "/uploads/a.jpg"}, portfolio_service, "add_portfolio_item", photo(), 201),
    ("PATCH", "/api/v1/services/100/portfolio/1", {"caption": "after"}, portfolio_service, "update_portfolio_item", photo(), 200),
    ("DELETE", "/api/v1/services/100/portfolio/1", None, portfolio_service, "delete_portfolio_item", None, 204),
    # reviews
    ("POST", "/api/v1/services/100/reviews", {"rating": 5}, review_service, "create_or_update_review", review(), 201),
    ("PATCH", "/api/v1/services/100/reviews/1", {"comment": "ok"}, review_service, "update_review", review(), 200),
    ("DELETE", "/api/v1/services/100/reviews/1", None, review_service, "delete_review", None, 204),
    # services
    ("POST", "/api/v1/services", {"category_id": 1, "title": "Fix pipes", "description": "I fix all kinds of pipes", "price": "25.50"},
     service_service, "create_service", service_full(), 201),
    ("PATCH", "/api/v1/services/100", {"title": "New title"}, service_service, "update_service", service_full(), 200),
    ("DELETE", "/api/v1/services/100", None, service_service, "delete_service", None, 204),
    # users
    ("PATCH", "/api/v1/users/me", {"bio": "hello"}, user_service, "update_profile", full_user(), 200),
    ("PUT", "/api/v1/users/me/location", {"latitude": 33.5, "longitude": 36.3}, user_service, "update_location", full_user(), 200),
    ("PUT", "/api/v1/users/me/provider-status", {"is_provider": True}, user_service, "set_provider_status", full_user(), 200),
]

ADMIN_ONLY = [
    ("GET", "/api/v1/admin/users/5", None, admin_service, "get_user_by_id", full_user(5), 200),
    ("PUT", "/api/v1/admin/users/5/active-status", {"is_active": False}, admin_service, "set_user_active_status", full_user(5), 200),
    ("PUT", "/api/v1/admin/users/5/role", {"role": "admin"}, admin_service, "set_user_role", full_user(5), 200),
    ("GET", "/api/v1/admin/services", None, admin_service, "list_services_for_moderation", ([admin_service_row()], False), 200),
    ("PUT", "/api/v1/admin/services/1/status", {"status": "suspended"}, admin_service, "set_service_status", admin_service_row(status="suspended"), 200),
    ("POST", "/api/v1/categories", {"name": "Plumbing"}, category_service, "create_category", category(), 201),
    ("PATCH", "/api/v1/categories/1", {"name": "Plumbers"}, category_service, "update_category", category(), 200),
]


def _stub(monkeypatch, module, function, value):
    calls = []

    def fake(*args, **kwargs):
        calls.append((args, kwargs))
        return value

    monkeypatch.setattr(module, function, fake)
    return calls


def _case_id(case):
    return f"{case[0]} {case[1]}"


# ------------------------------------------------------------------ tests
@pytest.mark.parametrize("case", PUBLIC, ids=_case_id)
def test_public_endpoints_work_without_a_token(client, monkeypatch, case):
    method, path, body, module, function, value, status = case
    calls = _stub(monkeypatch, module, function, value)

    response = client.request(method, path, json=body)

    assert response.status_code == status, response.text
    assert len(calls) == 1


@pytest.mark.parametrize("case", AUTHENTICATED, ids=_case_id)
def test_authenticated_endpoints_reject_anonymous_callers(client, monkeypatch, case):
    method, path, body, module, function, value, _ = case
    calls = _stub(monkeypatch, module, function, value)

    response = client.request(method, path, json=body)

    assert response.status_code == 401
    assert calls == []          # the service was never reached


@pytest.mark.parametrize("case", AUTHENTICATED, ids=_case_id)
def test_authenticated_endpoints_succeed_for_a_logged_in_user(client, fake_db, monkeypatch, case):
    method, path, body, module, function, value, status = case
    calls = _stub(monkeypatch, module, function, value)

    response = client.request(method, path, json=body, headers=login_as(fake_db))

    assert response.status_code == status, response.text
    assert len(calls) == 1
    if status == 204:
        assert response.content == b""


@pytest.mark.parametrize("case", ADMIN_ONLY, ids=_case_id)
def test_admin_endpoints_forbid_regular_users(client, fake_db, monkeypatch, case):
    method, path, body, module, function, value, _ = case
    calls = _stub(monkeypatch, module, function, value)

    assert client.request(method, path, json=body).status_code == 401
    assert client.request(method, path, json=body, headers=login_as(fake_db)).status_code == 403
    assert calls == []


@pytest.mark.parametrize("case", ADMIN_ONLY, ids=_case_id)
def test_admin_endpoints_succeed_for_admins(client, fake_db, monkeypatch, case):
    method, path, body, module, function, value, status = case
    calls = _stub(monkeypatch, module, function, value)

    response = client.request(method, path, json=body, headers=login_as(fake_db, role=UserRole.ADMIN))

    assert response.status_code == status, response.text
    assert len(calls) == 1


# ------------------------------------------------- arguments reach the services
def test_appointment_list_passes_the_provider_flag(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, appointment_service, "list_my_appointments", ([], False))
    headers = login_as(fake_db)

    first = client.get("/api/v1/appointments/me", headers=headers)
    second = client.get("/api/v1/appointments/me?as_provider=true", headers=headers)

    # Asserted so a 500 cannot hide behind a forwarded argument.
    assert (first.status_code, second.status_code) == (200, 200), first.text
    assert [c[1]["as_provider"] for c in calls] == [False, True]


def test_reject_and_cancel_forward_the_reason(client, fake_db, monkeypatch):
    reject = _stub(monkeypatch, appointment_service, "reject_appointment", appointment())
    cancel = _stub(monkeypatch, appointment_service, "cancel_appointment", appointment())
    headers = login_as(fake_db)

    client.post("/api/v1/appointments/5/reject", json={"cancellation_reason": "full"}, headers=headers)
    client.post("/api/v1/appointments/5/cancel", json={}, headers=headers)

    assert reject[0][0][1] == 5 and reject[0][0][3] == "full"
    assert cancel[0][0][3] is None


def test_proposal_list_defaults_to_sent_and_can_be_flipped(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, exchange_service, "list_my_proposals_page", ([], False))
    headers = login_as(fake_db)

    client.get("/api/v1/exchange-proposals/me", headers=headers)
    client.get("/api/v1/exchange-proposals/me?sent=false", headers=headers)

    assert [c[1]["sent"] for c in calls] == [True, False]


def test_accept_and_reject_proposal_use_the_same_service_with_a_flag(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, exchange_service, "respond_to_proposal", proposal())
    headers = login_as(fake_db)

    client.post("/api/v1/exchange-proposals/3/accept", headers=headers)
    client.post("/api/v1/exchange-proposals/3/reject", headers=headers)

    assert [c[1]["accept"] for c in calls] == [True, False]


def test_exchange_matches_are_wrapped_as_direct_matches(client, fake_db, monkeypatch):
    _stub(monkeypatch, exchange_service, "find_matches_for_request", [exchange_request(8)])
    body = client.get("/api/v1/exchange-requests/7/matches", headers=login_as(fake_db)).json()

    assert body[0]["match_type"] == "direct"
    assert body[0]["other_request"]["id"] == 8


def test_service_list_filters_are_passed_through(client, monkeypatch):
    calls = _stub(monkeypatch, service_service, "list_active_services", [])
    client.get("/api/v1/services?category_id=3&city=Damascus")
    assert calls[0][1] == {"category_id": 3, "city": "Damascus"}


def test_notification_list_unread_flag(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, notification_service, "list_my_notifications", ([], False))
    headers = login_as(fake_db)

    first = client.get("/api/v1/notifications", headers=headers)
    second = client.get("/api/v1/notifications?unread_only=true", headers=headers)

    # Asserted so a 500 cannot hide behind a forwarded argument.
    assert (first.status_code, second.status_code) == (200, 200), first.text
    assert [c[1]["unread_only"] for c in calls] == [False, True]


def test_notification_counters_have_their_own_shapes(client, fake_db, monkeypatch):
    headers = login_as(fake_db)
    _stub(monkeypatch, notification_service, "get_unread_count", 4)
    _stub(monkeypatch, notification_service, "mark_all_notifications_read", 3)

    assert client.get("/api/v1/notifications/unread-count", headers=headers).json() == {"unread_count": 4}
    assert client.post("/api/v1/notifications/read-all", headers=headers).json() == {"updated_count": 3}


def test_provider_status_flag_is_forwarded(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, user_service, "set_provider_status", full_user())
    client.put("/api/v1/users/me/provider-status", json={"is_provider": True}, headers=login_as(fake_db))
    assert calls[0][0][2] is True


def test_admin_service_list_accepts_the_status_alias(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, admin_service, "list_services_for_moderation", ([], False))
    response = client.get(
        "/api/v1/admin/services?status=suspended", headers=login_as(fake_db, role=UserRole.ADMIN)
    )
    assert response.status_code == 200, response.text
    assert calls[0][1]["status_filter"].value == "suspended"


# -------------------------------------------------------------- validation
@pytest.mark.parametrize(
    "method, path, body",
    [
        ("POST", "/api/v1/services/100/reviews", {"rating": 6}),
        ("POST", "/api/v1/services/100/reviews", {"rating": 0}),
        ("POST", "/api/v1/barter-preferences", {"offered_category_id": 1, "needed_category_id": 1}),
        ("POST", "/api/v1/notifications/devices", {"fcm_token": "short"}),
        ("POST", "/api/v1/services/100/portfolio", {"image_url": ""}),
        ("PUT", "/api/v1/users/me/location", {"latitude": 91, "longitude": 0}),
        ("POST", "/api/v1/providers/1/availability", {"day_of_week": 0, "start_time": "17:00:00", "end_time": "09:00:00"}),
        ("POST", "/api/v1/services", {"category_id": 1, "title": "x", "description": "short", "price": "-1"}),
    ],
)
def test_invalid_bodies_are_rejected_before_reaching_the_service(client, fake_db, method, path, body):
    response = client.request(method, path, json=body, headers=login_as(fake_db))
    assert response.status_code == 422


def test_a_provider_can_only_manage_their_own_availability(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, availability_service, "create_availability_window", window())
    body = {"day_of_week": 0, "start_time": "09:00:00", "end_time": "17:00:00"}

    response = client.post("/api/v1/providers/99/availability", json=body, headers=login_as(fake_db, id=1))

    assert response.status_code == 403
    assert calls == []


def test_cities_endpoint_is_public_and_lists_cities(client):
    response = client.get("/api/v1/cities")
    assert response.status_code == 200
    assert "دمشق" in response.json()


# ------------------------------------------------------------------ search
def _found_service(distance_source=1.234):
    return SimpleNamespace(
        id=100, title="Fix pipes", display_title="Plumbing", price=Decimal("25.50"), price_unit="fixed",
        status="active", cover_image_url="/uploads/cover.jpg", is_remote=True,
        custom_category_label=None, category=category(), provider=user_public(2, True),
    )


def test_nearby_search_rounds_the_distance_and_is_public(client, monkeypatch):
    calls = _stub(monkeypatch, search_service, "search_services", [(_found_service(), 1.2399)])

    response = client.get("/api/v1/search/services?latitude=33.5&longitude=36.3&radius_km=10")

    assert response.status_code == 200
    assert response.json()[0]["distance_km"] == 1.24
    assert calls[0][1]["exclude_provider_id"] is None


def test_search_results_carry_the_same_card_fields_as_every_other_list(client, monkeypatch):
    """The app draws the cover photo on search cards; the contract test caught it missing."""
    _stub(monkeypatch, search_service, "search_services", [(_found_service(), 1.0)])
    _stub(monkeypatch, semantic_search_service, "search_services_semantic", [(_found_service(), 0.8, (4.5, 3))])

    nearby = client.get("/api/v1/search/services?latitude=33.5&longitude=36.3").json()[0]
    semantic = client.get("/api/v1/search/semantic?q=ac").json()[0]

    for result in (nearby, semantic):
        assert result["cover_image_url"] == "/uploads/cover.jpg"
        assert result["is_remote"] is True
        assert result["status"] == "active"


def test_nearby_search_hides_the_callers_own_listings(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, search_service, "search_services", [])

    client.get("/api/v1/search/services?latitude=33.5&longitude=36.3", headers=login_as(fake_db, id=7))

    assert calls[0][1]["exclude_provider_id"] == 7


@pytest.mark.parametrize(
    "query",
    ["longitude=36.3", "latitude=95&longitude=36.3", "latitude=33&longitude=36&radius_km=201",
     "latitude=33&longitude=36&radius_km=0", "latitude=33&longitude=36&max_results=101"],
)
def test_nearby_search_validates_its_parameters(client, query):
    assert client.get(f"/api/v1/search/services?{query}").status_code == 422


def test_semantic_search_returns_scores_and_ratings(client, monkeypatch):
    calls = _stub(monkeypatch, semantic_search_service, "search_services_semantic", [(_found_service(), 0.82, (4.5, 3))])

    response = client.get("/api/v1/search/semantic?q=fix my AC&limit=5")

    body = response.json()[0]
    assert response.status_code == 200
    assert (body["similarity_score"], body["average_rating"], body["total_reviews"]) == (0.82, 4.5, 3)
    assert calls[0][0][1].q == "fix my AC" and calls[0][0][1].limit == 5


def test_semantic_search_reports_when_it_is_disabled(client, monkeypatch):
    def disabled(db, params):
        raise ServiceUnavailableError("Semantic search is disabled")

    monkeypatch.setattr(semantic_search_service, "search_services_semantic", disabled)
    assert client.get("/api/v1/search/semantic?q=ac").status_code == 503


def test_smart_search_without_the_model_is_a_503_the_app_can_show(client, monkeypatch):
    """It ranks by meaning alone, so there is nothing to fall back to; the
    app prints the server's message (errorText), so it must be Arabic."""
    monkeypatch.setattr(semantic_search_service.settings, "SEMANTIC_SEARCH_ENABLED", False)

    response = client.get("/api/v1/search/smart?q=جوال")

    assert response.status_code == 503
    assert "البحث الذكي غير مفعّل" in response.text


@pytest.mark.parametrize("query", ["", "q=", "q=ac&threshold=2", "q=ac&limit=0"])
def test_semantic_search_validates_its_parameters(client, query):
    assert client.get(f"/api/v1/search/semantic?{query}").status_code == 422


# ----------------------------------------------------------- barter matches
def _barter_match(user_ids=(1, 2), viewed=False):
    participants = [
        SimpleNamespace(
            user_id=uid, sequence_order=i, is_viewed=viewed, user=user_public(uid),
            preference=SimpleNamespace(offered_category=category(1), needed_category=category(2, "Electrical")),
        )
        for i, uid in enumerate(user_ids)
    ]
    return SimpleNamespace(id=9, match_type="direct", cycle_length=len(user_ids),
                           created_at=NOW, participants=participants)


def test_my_barter_matches(client, fake_db):
    headers = login_as(fake_db, id=1)
    fake_db.execute.return_value.scalars.return_value.unique.return_value.all.return_value = [_barter_match()]

    response = client.get("/api/v1/barter-matches/me", headers=headers)

    body = response.json()[0]
    assert response.status_code == 200
    assert body["match_type"] == "direct" and body["cycle_length"] == 2
    assert [p["sequence_order"] for p in body["participants"]] == [0, 1]
    assert body["participants"][0]["offered_category"]["name"] == "Plumbing"


def test_marking_a_match_as_viewed_only_flips_my_own_flag(client, fake_db):
    headers = login_as(fake_db, id=1)
    match = _barter_match(user_ids=(1, 2))
    fake_db.execute.return_value.scalar_one_or_none.return_value = match

    response = client.post("/api/v1/barter-matches/9/view", headers=headers)

    assert response.status_code == 200
    assert [p.is_viewed for p in match.participants] == [True, False]
    fake_db.commit.assert_called_once()


def test_marking_an_already_viewed_match_changes_nothing_extra(client, fake_db):
    """
    Viewing twice is idempotent from the caller's side: the flag is set to
    True again (the assignment is unconditional today) and the single
    commit still happens, but no other participant is touched.
    """
    headers = login_as(fake_db, id=1)
    match = _barter_match(user_ids=(1, 2), viewed=True)
    fake_db.execute.return_value.scalar_one_or_none.return_value = match

    response = client.post("/api/v1/barter-matches/9/view", headers=headers)

    assert response.status_code == 200
    assert [p.is_viewed for p in match.participants] == [True, True]
    fake_db.commit.assert_called_once()


def test_the_view_response_carries_the_matchs_loaded_relationships(client, fake_db):
    """
    The response is assembled from participant.user and
    participant.preference.{offered,needed}_category, so those have to
    still be reachable on the instance the flow hands back.
    """
    headers = login_as(fake_db, id=1)
    fake_db.execute.return_value.scalar_one_or_none.return_value = _barter_match(user_ids=(1, 2))

    body = client.post("/api/v1/barter-matches/9/view", headers=headers).json()

    assert body["id"] == 9
    assert body["match_type"] == "direct"
    assert body["cycle_length"] == 2
    assert [p["sequence_order"] for p in body["participants"]] == [0, 1]
    assert [p["user"]["id"] for p in body["participants"]] == [1, 2]
    assert body["participants"][0]["offered_category"]["name"] == "Plumbing"
    assert body["participants"][0]["needed_category"]["name"] == "Electrical"
    assert [p["is_viewed"] for p in body["participants"]] == [True, False]


def test_viewing_an_unknown_match_is_404(client, fake_db):
    headers = login_as(fake_db)
    fake_db.execute.return_value.scalar_one_or_none.return_value = None
    assert client.post("/api/v1/barter-matches/9/view", headers=headers).status_code == 404


def test_viewing_someone_elses_match_is_403(client, fake_db):
    headers = login_as(fake_db, id=1)
    fake_db.execute.return_value.scalar_one_or_none.return_value = _barter_match(user_ids=(5, 6))

    response = client.post("/api/v1/barter-matches/9/view", headers=headers)

    assert response.status_code == 403
    fake_db.commit.assert_not_called()


def test_barter_match_routes_need_login(client):
    assert client.get("/api/v1/barter-matches/me").status_code == 401
    assert client.post("/api/v1/barter-matches/9/view").status_code == 401


def test_rescan_is_admin_only_and_reports_the_count(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, barter_matching_service, "run_matching", [object(), object()])

    assert client.post("/api/v1/barter-matches/rescan").status_code == 401
    assert client.post("/api/v1/barter-matches/rescan", headers=login_as(fake_db)).status_code == 403
    assert calls == []

    response = client.post("/api/v1/barter-matches/rescan", headers=login_as(fake_db, role=UserRole.ADMIN))
    assert response.json() == {"new_matches_found": 2}


# ------------------------------------------------------------------ uploads
@pytest.fixture
def upload_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(uploads, "UPLOAD_DIR", tmp_path)
    return tmp_path


def _post_file(client, headers, name="photo.png", content=b"\x89PNG-bytes", content_type="image/png"):
    return client.post("/api/v1/uploads/image", files={"file": (name, content, content_type)}, headers=headers)


def test_upload_saves_the_file_and_returns_its_url(client, fake_db, upload_dir):
    response = _post_file(client, login_as(fake_db), content=b"hello-image")

    assert response.status_code == 200
    url = response.json()["url"]
    assert url.startswith("/uploads/") and url.endswith(".png")
    assert (upload_dir / url.split("/")[-1]).read_bytes() == b"hello-image"


def test_upload_names_are_unique(client, fake_db, upload_dir):
    headers = login_as(fake_db)
    first = _post_file(client, headers).json()["url"]
    second = _post_file(client, headers).json()["url"]
    assert first != second


def test_extension_is_lowercased_and_defaults_to_jpg(client, fake_db, upload_dir):
    headers = login_as(fake_db)
    assert _post_file(client, headers, name="Photo.JPG", content_type="image/jpeg").json()["url"].endswith(".jpg")
    assert _post_file(client, headers, name="blob", content_type="image/webp").json()["url"].endswith(".jpg")


@pytest.mark.parametrize("content_type", ["image/jpeg", "image/png", "image/webp", "image/gif"])
def test_allowed_image_types(client, fake_db, upload_dir, content_type):
    assert _post_file(client, login_as(fake_db), content_type=content_type).status_code == 200


@pytest.mark.parametrize("content_type", ["text/plain", "application/pdf", "image/svg+xml", "application/x-msdownload"])
def test_other_file_types_are_rejected(client, fake_db, upload_dir, content_type):
    response = _post_file(client, login_as(fake_db), name="x.bin", content_type=content_type)

    assert response.status_code == 422
    assert "JPEG" in response.json()["detail"]
    assert list(upload_dir.iterdir()) == []


def test_oversized_files_are_rejected(client, fake_db, upload_dir, monkeypatch):
    monkeypatch.setattr(uploads, "MAX_FILE_SIZE_BYTES", 10)

    response = _post_file(client, login_as(fake_db), content=b"x" * 11)

    assert response.status_code == 422
    assert "8 ميغابايت" in response.json()["detail"]
    assert list(upload_dir.iterdir()) == []


def test_a_file_exactly_at_the_limit_is_accepted(client, fake_db, upload_dir, monkeypatch):
    monkeypatch.setattr(uploads, "MAX_FILE_SIZE_BYTES", 10)
    assert _post_file(client, login_as(fake_db), content=b"x" * 10).status_code == 200


def test_upload_requires_login_and_a_file(client, fake_db, upload_dir):
    assert _post_file(client, headers={}).status_code == 401
    assert client.post("/api/v1/uploads/image", headers=login_as(fake_db)).status_code == 422


# ------------------------------------------- exchange discovery (interests / search)
def test_interests_are_computed_for_the_logged_in_user(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, exchange_service, "list_interests_page", ([
        ranked_request(8, rating=4.9, count=12), ranked_request(9, rating=None, count=0),
    ], False))

    body = client.get("/api/v1/exchange-requests/interests", headers=login_as(fake_db)).json()

    (db, user, query), _ = calls[0]
    assert user.id == 1 and query is None
    assert [r["id"] for r in body] == [8, 9]                 # service order is kept
    assert body[0]["offered_service_rating"] == 4.9
    assert body[0]["offered_service_review_count"] == 12
    assert body[1]["offered_service_rating"] is None         # unrated stays null, not 0
    assert body[0]["relevance_score"] is None
    assert body[0]["wanted_category"]["name"] == "Electrical"   # full request shape


def test_interests_pass_the_search_text_through(client, fake_db, monkeypatch):
    calls = _stub(monkeypatch, exchange_service, "list_interests_page", ([], False))
    client.get("/api/v1/exchange-requests/interests?q=سباك", headers=login_as(fake_db))
    assert calls[0][0][2] == "سباك"


def test_exchange_search_is_public_and_excludes_the_callers_own_requests(
    client, fake_db, monkeypatch
):
    calls = _stub(monkeypatch, exchange_service, "search_requests_page",
                  ([ranked_request(relevance=0.7)], False))

    anonymous = client.get("/api/v1/exchange-requests/search?q=برمجة")
    logged_in = client.get("/api/v1/exchange-requests/search?q=برمجة", headers=login_as(fake_db))

    assert anonymous.status_code == logged_in.status_code == 200
    assert calls[0][0][1] == "برمجة"
    # The exclusion still comes from the token, and the page parameters
    # ride alongside it (unrequested here, so the answer is a bare list).
    assert calls[0][1]["exclude_user_id"] is None
    assert calls[1][1]["exclude_user_id"] == 1
    assert calls[0][1]["params"].requested is False
    assert set(calls[0][1]) == {"exclude_user_id", "params"}
    assert anonymous.json()[0]["relevance_score"] == 0.7


@pytest.mark.parametrize("query", ["", "?q=", "?q=" + "ا" * 201])
def test_exchange_search_validates_the_query(client, monkeypatch, query):
    calls = _stub(monkeypatch, exchange_service, "search_requests_page", ([], False))
    assert client.get("/api/v1/exchange-requests/search" + query).status_code == 422
    assert calls == []
