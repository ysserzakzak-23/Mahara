from decimal import Decimal
from types import SimpleNamespace

import pytest

from app.core.exceptions import PermissionDeniedError, ValidationError
from app.models.service import Service
from app.models.user import UserRole
from app.schemas.service import ServiceCreateRequest, ServiceUpdateRequest
from app.services import service_service as svc

NORMAL = SimpleNamespace(id=1, is_other=False)
OTHERS = SimpleNamespace(id=9, is_other=True)


# ------------------------------------------------ custom category label rules

@pytest.mark.parametrize("label", [None, "", "  ", "whatever"])
def test_label_is_cleared_for_normal_categories(label):
    assert svc._resolve_custom_category_label(NORMAL, label) is None


def test_label_is_trimmed_for_the_others_category():
    assert svc._resolve_custom_category_label(OTHERS, "  سباك ") == "سباك"


@pytest.mark.parametrize("label", [None, "", "   "])
def test_others_category_requires_a_real_label(label):
    with pytest.raises(ValidationError, match="أخرى"):
        svc._resolve_custom_category_label(OTHERS, label)


# --------------------------------------------------------------------- create

def create_payload(**kw):
    data = dict(
        category_id=1, title="Fix pipes",
        description="I fix all kinds of pipes", price=Decimal("25.50"),
    )
    data.update(kw)
    return ServiceCreateRequest(**data)


@pytest.fixture
def create_env(monkeypatch):
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: "reloaded")

    def install(category):
        monkeypatch.setattr(svc, "get_category_by_id", lambda db, cid: category)

    install(NORMAL)
    return install


def test_create_service_builds_the_listing(db, create_env):
    provider = SimpleNamespace(id=4, is_provider=True)
    result = svc.create_service(db, provider, create_payload(is_remote=True))

    created = db.add.call_args.args[0]
    assert isinstance(created, Service)
    assert created.provider_id == 4
    assert created.title == "Fix pipes"
    assert created.price == Decimal("25.50")
    assert created.price_unit == "fixed"
    assert created.is_remote is True
    db.commit.assert_called_once()
    assert result == "reloaded"


def test_first_listing_promotes_the_user_to_provider(db, create_env):
    provider = SimpleNamespace(id=4, is_provider=False)
    svc.create_service(db, provider, create_payload())
    assert provider.is_provider is True


def test_stray_label_is_dropped_for_normal_categories(db, create_env):
    svc.create_service(
        db, SimpleNamespace(id=4, is_provider=True), create_payload(custom_category_label="x")
    )
    assert db.add.call_args.args[0].custom_category_label is None


def test_others_category_stores_the_trimmed_label(db, create_env):
    create_env(OTHERS)
    svc.create_service(
        db, SimpleNamespace(id=4, is_provider=True), create_payload(custom_category_label=" سباك ")
    )
    assert db.add.call_args.args[0].custom_category_label == "سباك"


def test_others_category_without_label_is_rejected_and_nothing_saved(db, create_env):
    create_env(OTHERS)
    with pytest.raises(ValidationError):
        svc.create_service(db, SimpleNamespace(id=4, is_provider=False), create_payload())
    db.add.assert_not_called()
    db.commit.assert_not_called()


# --------------------------------------------------------------------- update

def stored_service(provider_id=4, category=NORMAL, label=None):
    return SimpleNamespace(
        id=1, provider_id=provider_id, category=category,
        custom_category_label=label, title="Old title", price=Decimal("10"),
    )


@pytest.fixture
def update_env(monkeypatch):
    def install(service, new_category=None):
        monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: service)
        if new_category is not None:
            monkeypatch.setattr(svc, "get_category_by_id", lambda db, cid: new_category)
        return service

    return install


def owner(id=4, role=UserRole.USER):
    return SimpleNamespace(id=id, role=role)


def test_owner_updates_only_the_given_fields(db, update_env):
    service = update_env(stored_service())
    svc.update_service(db, 1, owner(), ServiceUpdateRequest(title="New title"))

    assert service.title == "New title"
    assert service.price == Decimal("10")
    db.commit.assert_called_once()


def test_stranger_cannot_update(db, update_env):
    service = update_env(stored_service())
    with pytest.raises(PermissionDeniedError):
        svc.update_service(db, 1, owner(id=99), ServiceUpdateRequest(title="Hacked"))
    assert service.title == "Old title"


def test_admin_can_update_anyones_service(db, update_env):
    service = update_env(stored_service())
    svc.update_service(db, 1, owner(id=99, role=UserRole.ADMIN), ServiceUpdateRequest(title="Moderated"))
    assert service.title == "Moderated"


def test_unrelated_patch_keeps_the_label_of_an_others_service(db, update_env):
    service = update_env(stored_service(category=OTHERS, label="سباك"))
    svc.update_service(db, 1, owner(), ServiceUpdateRequest(title="New title"))
    assert service.custom_category_label == "سباك"


def test_switching_away_from_others_clears_the_label(db, update_env):
    service = update_env(stored_service(category=OTHERS, label="سباك"), new_category=NORMAL)
    svc.update_service(db, 1, owner(), ServiceUpdateRequest(category_id=1))
    assert service.custom_category_label is None


def test_switching_to_others_requires_a_label(db, update_env):
    update_env(stored_service(), new_category=OTHERS)
    with pytest.raises(ValidationError):
        svc.update_service(db, 1, owner(), ServiceUpdateRequest(category_id=9))
    db.commit.assert_not_called()


def test_switching_to_others_with_a_label_works(db, update_env):
    service = update_env(stored_service(), new_category=OTHERS)
    svc.update_service(
        db, 1, owner(), ServiceUpdateRequest(category_id=9, custom_category_label="نجار")
    )
    assert service.custom_category_label == "نجار"
    assert service.category_id == 9


# --------------------------------------------------------------------- delete

def test_owner_deletes_service(db, update_env):
    service = update_env(stored_service())
    svc.delete_service(db, 1, owner())
    db.delete.assert_called_once_with(service)
    db.commit.assert_called_once()


def test_stranger_cannot_delete_service(db, update_env):
    update_env(stored_service())
    with pytest.raises(PermissionDeniedError):
        svc.delete_service(db, 1, owner(id=99))
    db.delete.assert_not_called()


# ----------------------------------------------------------- list query shape

def _sql(db):
    return str(db.execute.call_args.args[0])


def test_listing_only_joins_profiles_when_filtering_by_city(db):
    db.execute.return_value.scalars.return_value.all.return_value = []

    svc.list_active_services(db)
    assert "JOIN" not in _sql(db)

    svc.list_active_services(db, city="دمشق")
    assert "JOIN" in _sql(db)


def test_listing_filters_by_category(db):
    db.execute.return_value.scalars.return_value.all.return_value = []
    svc.list_active_services(db)
    assert ":category_id_1" not in _sql(db)

    svc.list_active_services(db, category_id=3)
    assert ":category_id_1" in _sql(db)


# -------------------------------------------- working hours before an on-site listing

def test_an_on_site_service_needs_working_hours_first(db, create_env):
    db.execute.return_value.first.return_value = None
    provider = SimpleNamespace(id=4, is_provider=True)

    with pytest.raises(ValidationError, match="دوامك قبل نشر خدمة غير عن بعد"):
        svc.create_service(db, provider, create_payload(is_remote=False))

    db.add.assert_not_called()
    db.commit.assert_not_called()


def test_an_on_site_service_is_published_once_hours_exist(db, create_env):
    db.execute.return_value.first.return_value = (1,)
    provider = SimpleNamespace(id=4, is_provider=True)

    svc.create_service(db, provider, create_payload(is_remote=False))

    db.add.assert_called_once()


def test_a_remote_service_needs_no_working_hours(db, create_env):
    provider = SimpleNamespace(id=4, is_provider=True)

    svc.create_service(db, provider, create_payload(is_remote=True))

    db.add.assert_called_once()
    db.execute.assert_not_called()      # the hours are not even looked up


def test_the_hours_are_asked_only_for_the_first_listing(db, create_env):
    db.execute.return_value.first.return_value = (1,)
    provider = SimpleNamespace(id=4, is_provider=True)

    svc.create_service(db, provider, create_payload(is_remote=False))
    svc.create_service(db, provider, create_payload(is_remote=False, title="Second listing"))

    assert db.add.call_count == 2


def test_turning_a_remote_service_on_site_needs_working_hours(db, update_env):
    service = update_env(stored_service())
    service.is_remote = True
    db.execute.return_value.first.return_value = None

    with pytest.raises(ValidationError, match="دوامك"):
        svc.update_service(db, 1, owner(), ServiceUpdateRequest(is_remote=False))

    assert service.is_remote is True
    db.commit.assert_not_called()


def test_turning_a_remote_service_on_site_works_with_hours(db, update_env):
    service = update_env(stored_service())
    service.is_remote = True
    db.execute.return_value.first.return_value = (1,)

    svc.update_service(db, 1, owner(), ServiceUpdateRequest(is_remote=False))

    assert service.is_remote is False


def test_editing_an_on_site_service_does_not_ask_for_hours_again(db, update_env):
    service = update_env(stored_service())
    service.is_remote = False
    db.execute.return_value.first.return_value = None     # hours were later removed

    svc.update_service(db, 1, owner(), ServiceUpdateRequest(title="New title"))

    assert service.title == "New title"
