from types import SimpleNamespace

import pytest

from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.review import Review
from app.models.user import UserRole
from app.schemas.review import ReviewCreateRequest, ReviewUpdateRequest
from app.services import review_service as svc
from tests.helpers import make_result

PROVIDER, CUSTOMER, STRANGER = 2, 1, 3


@pytest.fixture(autouse=True)
def a_service(monkeypatch):
    service = SimpleNamespace(id=100, provider_id=PROVIDER)
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: service)
    return service


def user(id, role=UserRole.USER):
    return SimpleNamespace(id=id, role=role)


# ============================================================ rating summary

def test_summary_rounds_the_average_to_two_decimals(db):
    db.execute.return_value = make_result(one=(4.6666, 3))
    summary = svc.get_rating_summary(db, 100)
    assert (summary.service_id, summary.average_rating, summary.review_count) == (100, 4.67, 3)


def test_summary_for_a_service_without_reviews_is_zero(db):
    db.execute.return_value = make_result(one=(None, 0))
    summary = svc.get_rating_summary(db, 100)
    assert summary.average_rating == 0.0 and summary.review_count == 0


def test_listing_reviews_404s_for_unknown_service(db, monkeypatch):
    def missing(db, sid):
        raise NotFoundError("Service not found")

    monkeypatch.setattr(svc, "get_service_by_id", missing)
    with pytest.raises(NotFoundError):
        svc.list_reviews_for_service(db, 999)


# ====================================================== create_or_update_review

def payload(rating=5, comment="great"):
    return ReviewCreateRequest(rating=rating, comment=comment)


def test_provider_cannot_review_their_own_service(db):
    db.execute.return_value = make_result(scalar_one_or_none=None)
    with pytest.raises(PermissionDeniedError, match="خدمتك الخاصة"):
        svc.create_or_update_review(db, 100, user(PROVIDER), payload())
    db.add.assert_not_called()


def test_stranger_without_a_completed_booking_cannot_review(db):
    db.execute.side_effect = [
        make_result(scalar_one_or_none=None),   # no existing review
        make_result(first=None),                # no COMPLETED appointment
    ]
    with pytest.raises(PermissionDeniedError, match="موعدك كمكتمل"):
        svc.create_or_update_review(db, 100, user(STRANGER), payload())
    db.add.assert_not_called()


def test_customer_with_completed_booking_creates_a_review(db):
    db.execute.side_effect = [
        make_result(scalar_one_or_none=None),
        make_result(first=(55,)),               # has a completed appointment
        make_result(scalar_one="reloaded"),
    ]
    result = svc.create_or_update_review(db, 100, user(CUSTOMER), payload(4, "good"))

    created = db.add.call_args.args[0]
    assert isinstance(created, Review)
    assert (created.service_id, created.reviewer_id, created.rating, created.comment) == (
        100, CUSTOMER, 4, "good",
    )
    db.commit.assert_called_once()
    assert result == "reloaded"


def test_existing_review_is_updated_instead_of_duplicated(db):
    existing = SimpleNamespace(id=9, rating=2, comment="meh")
    db.execute.side_effect = [
        make_result(scalar_one_or_none=existing),
        make_result(scalar_one="reloaded"),     # no booking check in between
    ]
    result = svc.create_or_update_review(db, 100, user(CUSTOMER), payload(5, "much better"))

    assert (existing.rating, existing.comment) == (5, "much better")
    db.add.assert_not_called()
    assert db.execute.call_count == 2
    assert result == "reloaded"


# ===================================================== update / delete a review

def stored_review(reviewer_id=CUSTOMER):
    return SimpleNamespace(id=9, reviewer_id=reviewer_id, rating=3, comment="old")


def test_update_missing_review_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.update_review(db, 9, user(CUSTOMER), ReviewUpdateRequest(rating=5))


def test_only_the_author_or_admin_can_edit(db):
    db.get.return_value = stored_review()
    with pytest.raises(PermissionDeniedError):
        svc.update_review(db, 9, user(STRANGER), ReviewUpdateRequest(rating=5))


def test_update_changes_only_the_provided_fields(db):
    review = stored_review()
    db.get.return_value = review
    db.execute.return_value = make_result(scalar_one="reloaded")

    result = svc.update_review(db, 9, user(CUSTOMER), ReviewUpdateRequest(rating=5))

    assert review.rating == 5
    assert review.comment == "old"
    assert result == "reloaded"


def test_admin_can_edit_any_review(db):
    review = stored_review()
    db.get.return_value = review
    db.execute.return_value = make_result(scalar_one="reloaded")
    svc.update_review(db, 9, user(STRANGER, UserRole.ADMIN), ReviewUpdateRequest(comment="edited"))
    assert review.comment == "edited"


def test_author_deletes_review(db):
    review = stored_review()
    db.get.return_value = review
    svc.delete_review(db, 9, user(CUSTOMER))
    db.delete.assert_called_once_with(review)
    db.commit.assert_called_once()


def test_stranger_cannot_delete_review(db):
    db.get.return_value = stored_review()
    with pytest.raises(PermissionDeniedError):
        svc.delete_review(db, 9, user(STRANGER))
    db.delete.assert_not_called()


def test_delete_missing_review_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.delete_review(db, 9, user(CUSTOMER))
