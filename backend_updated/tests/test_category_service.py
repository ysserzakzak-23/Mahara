from types import SimpleNamespace

import pytest

from app.core.exceptions import ConflictError, NotFoundError
from app.models.category import ServiceCategory
from app.schemas.category import ServiceCategoryCreateRequest, ServiceCategoryUpdateRequest
from app.services import category_service as svc
from tests.helpers import make_result, where_clause


def test_list_hides_inactive_categories_by_default(db):
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: []))

    svc.list_categories(db)
    assert "is_active" in where_clause(db.execute.call_args.args[0])

    svc.list_categories(db, include_inactive=True)
    assert "is_active" not in where_clause(db.execute.call_args.args[0])


def test_get_category_404s_when_missing(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.get_category_by_id(db, 1)


def test_get_category_returns_it(db):
    db.get.return_value = "cat"
    assert svc.get_category_by_id(db, 1) == "cat"


# --------------------------------------------------------------------- create

def test_duplicate_category_name_is_a_conflict(db):
    db.execute.return_value = make_result(scalar_one_or_none=object())
    with pytest.raises(ConflictError, match="Plumbing"):
        svc.create_category(db, ServiceCategoryCreateRequest(name="Plumbing"))
    db.add.assert_not_called()


def test_create_normal_category(db):
    db.execute.return_value = make_result(scalar_one_or_none=None)
    created = svc.create_category(
        db, ServiceCategoryCreateRequest(name="Plumbing", description="pipes")
    )

    assert isinstance(created, ServiceCategory)
    assert created.name == "Plumbing" and created.is_other is False
    db.add.assert_called_once_with(created)
    db.commit.assert_called_once()
    assert db.execute.call_count == 1       # no "clear other flag" query


def test_creating_a_new_others_category_demotes_the_old_one(db):
    previous = SimpleNamespace(is_other=True)
    db.execute.side_effect = [
        make_result(scalar_one_or_none=None),
        make_result(scalars=SimpleNamespace(all=lambda: [previous])),
    ]
    created = svc.create_category(db, ServiceCategoryCreateRequest(name="Misc", is_other=True))

    assert previous.is_other is False
    assert created.is_other is True


# --------------------------------------------------------------------- update

def test_update_applies_only_provided_fields(db):
    category = SimpleNamespace(name="Old", description="keep me", is_active=True, is_other=False)
    db.get.return_value = category

    svc.update_category(db, 1, ServiceCategoryUpdateRequest(name="New", is_active=False))

    assert category.name == "New"
    assert category.is_active is False
    assert category.description == "keep me"
    db.commit.assert_called_once()
    db.execute.assert_not_called()


def test_marking_a_category_as_others_demotes_the_previous_one(db):
    category = SimpleNamespace(is_other=False)
    previous = SimpleNamespace(is_other=True)
    db.get.return_value = category
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: [previous]))

    svc.update_category(db, 5, ServiceCategoryUpdateRequest(is_other=True))

    assert category.is_other is True
    assert previous.is_other is False


def test_update_missing_category_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.update_category(db, 1, ServiceCategoryUpdateRequest(name="X1"))
