from datetime import time
from types import SimpleNamespace

import pytest
from pydantic import ValidationError as PydanticValidationError

from app.core.exceptions import NotFoundError, PermissionDeniedError, ValidationError
from app.models.availability import ProviderAvailability
from app.models.portfolio import PortfolioItem
from app.models.service import ServiceStatus
from app.models.user import UserRole
from app.schemas.availability import ProviderAvailabilityCreateRequest
from app.schemas.portfolio import PortfolioItemCreateRequest, PortfolioItemUpdateRequest
from app.services import admin_service as admin
from app.services import availability_service as availability
from app.services import portfolio_service as portfolio
from tests.helpers import make_result, where_clause


def person(id, role=UserRole.USER):
    return SimpleNamespace(id=id, role=role)


OWNER, STRANGER = person(4), person(99)
ADMIN = person(1, UserRole.ADMIN)


# ================================================================ availability

def test_availability_schema_rules():
    ProviderAvailabilityCreateRequest(day_of_week=0, start_time=time(9), end_time=time(17))
    for bad in [
        dict(day_of_week=7, start_time=time(9), end_time=time(17)),
        dict(day_of_week=-1, start_time=time(9), end_time=time(17)),
        dict(day_of_week=0, start_time=time(17), end_time=time(9)),
        dict(day_of_week=0, start_time=time(9), end_time=time(9)),
    ]:
        with pytest.raises(PydanticValidationError):
            ProviderAvailabilityCreateRequest(**bad)


def test_listing_hides_deactivated_windows_unless_asked(db):
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: []))

    availability.list_availability(db, 4)
    assert "is_active" in where_clause(db.execute.call_args.args[0])
    availability.list_availability(db, 4, active_only=False)
    assert "is_active" not in where_clause(db.execute.call_args.args[0])


def test_create_window_belongs_to_the_provider(db):
    payload = ProviderAvailabilityCreateRequest(day_of_week=2, start_time=time(8), end_time=time(12))
    availability.create_availability_window(db, OWNER, payload)

    created = db.add.call_args.args[0]
    assert isinstance(created, ProviderAvailability)
    assert (created.provider_id, created.day_of_week) == (4, 2)
    assert (created.start_time, created.end_time) == (time(8), time(12))


def test_owner_deactivates_window_without_deleting_it(db):
    window = SimpleNamespace(provider_id=4, is_active=True)
    db.get.return_value = window
    availability.deactivate_availability_window(db, 1, OWNER)
    assert window.is_active is False
    db.delete.assert_not_called()


def test_admin_can_deactivate_any_window(db):
    window = SimpleNamespace(provider_id=4, is_active=True)
    db.get.return_value = window
    availability.deactivate_availability_window(db, 1, ADMIN)
    assert window.is_active is False


def test_stranger_cannot_deactivate_window(db):
    window = SimpleNamespace(provider_id=4, is_active=True)
    db.get.return_value = window
    with pytest.raises(PermissionDeniedError):
        availability.deactivate_availability_window(db, 1, STRANGER)
    assert window.is_active is True


def test_deactivating_missing_window_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        availability.deactivate_availability_window(db, 1, OWNER)


# ================================================================= portfolio

@pytest.fixture
def a_service(monkeypatch):
    monkeypatch.setattr(
        portfolio, "get_service_by_id", lambda db, sid: SimpleNamespace(id=sid, provider_id=4)
    )


def test_portfolio_schema_rules():
    PortfolioItemCreateRequest(image_url="/uploads/a.jpg")
    with pytest.raises(PydanticValidationError):
        PortfolioItemCreateRequest(image_url="")
    with pytest.raises(PydanticValidationError):
        PortfolioItemCreateRequest(image_url="/a.jpg", display_order=-1)


def test_owner_adds_gallery_item(db, a_service):
    payload = PortfolioItemCreateRequest(image_url="/uploads/a.jpg", caption="Before", display_order=2)
    portfolio.add_portfolio_item(db, 100, OWNER, payload)

    created = db.add.call_args.args[0]
    assert isinstance(created, PortfolioItem)
    assert (created.service_id, created.image_url, created.caption, created.display_order) == (
        100, "/uploads/a.jpg", "Before", 2,
    )


def test_stranger_cannot_add_gallery_item(db, a_service):
    with pytest.raises(PermissionDeniedError):
        portfolio.add_portfolio_item(db, 100, STRANGER, PortfolioItemCreateRequest(image_url="/a.jpg"))
    db.add.assert_not_called()


def test_admin_can_add_gallery_item(db, a_service):
    portfolio.add_portfolio_item(db, 100, ADMIN, PortfolioItemCreateRequest(image_url="/a.jpg"))
    db.add.assert_called_once()


def test_update_gallery_item_changes_only_given_fields(db, a_service):
    item = SimpleNamespace(service_id=100, caption="old", display_order=1)
    db.get.return_value = item
    portfolio.update_portfolio_item(db, 1, OWNER, PortfolioItemUpdateRequest(caption="new"))
    assert (item.caption, item.display_order) == ("new", 1)


def test_update_and_delete_missing_item_are_404(db, a_service):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        portfolio.update_portfolio_item(db, 1, OWNER, PortfolioItemUpdateRequest(caption="x"))
    with pytest.raises(NotFoundError):
        portfolio.delete_portfolio_item(db, 1, OWNER)


def test_stranger_cannot_update_or_delete_gallery_item(db, a_service):
    item = SimpleNamespace(service_id=100, caption="old", display_order=1)
    db.get.return_value = item
    with pytest.raises(PermissionDeniedError):
        portfolio.update_portfolio_item(db, 1, STRANGER, PortfolioItemUpdateRequest(caption="x"))
    with pytest.raises(PermissionDeniedError):
        portfolio.delete_portfolio_item(db, 1, STRANGER)
    db.delete.assert_not_called()


def test_owner_deletes_gallery_item(db, a_service):
    item = SimpleNamespace(service_id=100)
    db.get.return_value = item
    portfolio.delete_portfolio_item(db, 1, OWNER)
    db.delete.assert_called_once_with(item)


# ===================================================================== admin

@pytest.fixture
def admin_target(monkeypatch):
    def install(user):
        monkeypatch.setattr(admin, "get_user_by_id", lambda db, uid: user)
        return user

    return install


def test_admin_deactivates_another_user(db, admin_target):
    target = admin_target(SimpleNamespace(id=5, is_active=True))
    admin.set_user_active_status(db, 5, False, ADMIN)
    assert target.is_active is False


def test_admin_cannot_deactivate_themselves(db, admin_target):
    me = admin_target(SimpleNamespace(id=ADMIN.id, is_active=True))
    with pytest.raises(ValidationError, match="حسابك كمشرف"):
        admin.set_user_active_status(db, ADMIN.id, False, ADMIN)
    assert me.is_active is True


def test_admin_can_reactivate_themselves(db, admin_target):
    admin_target(SimpleNamespace(id=ADMIN.id, is_active=False))
    admin.set_user_active_status(db, ADMIN.id, True, ADMIN)


def test_admin_promotes_a_user(db, admin_target):
    target = admin_target(SimpleNamespace(id=5, role=UserRole.USER))
    admin.set_user_role(db, 5, UserRole.ADMIN, ADMIN)
    assert target.role == UserRole.ADMIN


def test_admin_cannot_remove_their_own_admin_role(db, admin_target):
    me = admin_target(SimpleNamespace(id=ADMIN.id, role=UserRole.ADMIN))
    with pytest.raises(ValidationError, match="صلاحية المشرف"):
        admin.set_user_role(db, ADMIN.id, UserRole.USER, ADMIN)
    assert me.role == UserRole.ADMIN


def test_unknown_user_is_404(db):
    db.execute.return_value = make_result(scalar_one_or_none=None)
    with pytest.raises(NotFoundError):
        admin.get_user_by_id(db, 123)


def test_user_list_filters_are_applied_only_when_given(db):
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: []))

    admin.list_users(db)
    plain = where_clause(db.execute.call_args.args[0])
    admin.list_users(db, role=UserRole.ADMIN, is_active=False)
    filtered = where_clause(db.execute.call_args.args[0])

    assert "role" not in plain and "role" in filtered
    assert "is_active" not in plain and "is_active" in filtered


def test_moderation_can_suspend_a_service(db):
    service = SimpleNamespace(status=ServiceStatus.ACTIVE)
    db.get.return_value = service
    admin.set_service_status(db, 1, ServiceStatus.SUSPENDED)
    assert service.status == ServiceStatus.SUSPENDED


def test_moderating_unknown_service_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        admin.set_service_status(db, 1, ServiceStatus.SUSPENDED)


def test_platform_stats_collects_every_counter(db):
    db.execute.side_effect = [
        make_result(scalar_one=v) for v in (100, 30, 55, 400, 250, 120, 4.2567)
    ]
    stats = admin.get_platform_stats(db)

    assert (stats.total_users, stats.total_providers, stats.active_services) == (100, 30, 55)
    assert (stats.total_appointments, stats.completed_appointments, stats.total_reviews) == (400, 250, 120)
    assert stats.average_platform_rating == 4.26


def test_platform_stats_without_reviews_has_zero_rating(db):
    db.execute.side_effect = [make_result(scalar_one=v) for v in (1, 0, 0, 0, 0, 0, None)]
    assert admin.get_platform_stats(db).average_platform_rating == 0.0
