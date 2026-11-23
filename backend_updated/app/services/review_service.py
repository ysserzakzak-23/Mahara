"""
Review service layer.

`create_or_update_review` is intentionally upsert-style: since a reviewer
can only have one review per service (enforced by a DB unique constraint),
calling "create" again when a review already exists updates it instead of
raising a conflict. This matches how review UIs typically work — the
reviewer sees their existing review pre-filled and edits it, they don't
get an error telling them to go find a separate "edit" button.
"""
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.appointment import Appointment, AppointmentStatus
from app.models.review import Review
from app.models.user import User, UserRole
from app.schemas.review import ReviewCreateRequest, ReviewUpdateRequest, ServiceRatingSummaryResponse
from app.services.service_service import get_service_by_id


def _query_with_relations():
    return select(Review).options(selectinload(Review.reviewer).selectinload(User.profile))


def list_reviews_for_service(db: Session, service_id: int) -> list[Review]:
    get_service_by_id(db, service_id)  # 404s if the service doesn't exist
    stmt = (
        _query_with_relations()
        .where(Review.service_id == service_id)
        .order_by(Review.created_at.desc())
    )
    return list(db.execute(stmt).scalars().all())


def get_rating_summary(db: Session, service_id: int) -> ServiceRatingSummaryResponse:
    """
    Computes average rating and review count in a single SQL aggregate
    query, rather than loading every Review row into Python and averaging
    there — this stays cheap even for a service with thousands of reviews.
    """
    stmt = select(func.avg(Review.rating), func.count(Review.id)).where(
        Review.service_id == service_id
    )
    avg_rating, count = db.execute(stmt).one()

    return ServiceRatingSummaryResponse(
        service_id=service_id,
        average_rating=round(float(avg_rating), 2) if avg_rating is not None else 0.0,
        review_count=count,
    )


def create_or_update_review(
    db: Session, service_id: int, reviewer: User, payload: ReviewCreateRequest
) -> Review:
    """
    Creates a review, or updates the reviewer's existing one for this service.

    Known limitation: this uses a SELECT-then-INSERT/UPDATE pattern rather
    than a DB-level upsert (INSERT ... ON CONFLICT). Two truly concurrent
    requests from the same user for the same service could both pass the
    "not found" check and then race on the INSERT, with the loser hitting
    the uq_review_reviewer_service constraint and raising an IntegrityError
    instead of gracefully updating. This is an accepted trade-off here —
    a user double-submitting their own review within milliseconds is a
    very low-stakes edge case — but if this pattern is reused somewhere
    with higher concurrency stakes, prefer a real upsert.
    """
    service = get_service_by_id(db, service_id)  # 404s if the service doesn't exist

    existing = db.execute(
        select(Review).where(Review.service_id == service_id, Review.reviewer_id == reviewer.id)
    ).scalar_one_or_none()

    # Only the person who actually requested/booked the service may rate
    # it — a provider cannot review their own listing, and a stranger who
    # never booked it cannot leave a "drive-by" rating. Further, the
    # booking must be COMPLETED specifically: the provider marks it done
    # (POST /appointments/{id}/complete) once the session actually
    # happened, which is what unlocks reviewing — a merely CONFIRMED
    # (upcoming/in-progress) or CANCELLED booking isn't enough. Skipped
    # when the reviewer already has an existing review (they passed this
    # check the first time; editing their own words shouldn't retroactively
    # depend on appointment state changing later).
    if existing is None:
        if reviewer.id == service.provider_id:
            raise PermissionDeniedError("لا يمكنك تقييم خدمتك الخاصة")

        has_completed_booking = db.execute(
            select(Appointment.id).where(
                Appointment.service_id == service_id,
                Appointment.customer_id == reviewer.id,
                Appointment.status == AppointmentStatus.COMPLETED,
            )
        ).first()
        if has_completed_booking is None:
            raise PermissionDeniedError(
                "يمكنك تقييم هذه الخدمة بعد أن يحدد مزوّد الخدمة موعدك كمكتمل"
            )

    if existing is not None:
        existing.rating = payload.rating
        existing.comment = payload.comment
        db.commit()
        db.refresh(existing)
        review = existing
    else:
        review = Review(
            service_id=service_id,
            reviewer_id=reviewer.id,
            rating=payload.rating,
            comment=payload.comment,
        )
        db.add(review)
        db.commit()
        db.refresh(review)

    stmt = _query_with_relations().where(Review.id == review.id)
    return db.execute(stmt).scalar_one()


def _assert_can_modify(review: Review, user: User) -> None:
    if review.reviewer_id != user.id and user.role != UserRole.ADMIN:
        raise PermissionDeniedError("ليس لديك صلاحية لتعديل هذا التقييم")


def update_review(db: Session, review_id: int, user: User, payload: ReviewUpdateRequest) -> Review:
    review = db.get(Review, review_id)
    if review is None:
        raise NotFoundError("التقييم غير موجود")
    _assert_can_modify(review, user)

    update_data = payload.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(review, field, value)

    db.commit()
    db.refresh(review)

    stmt = _query_with_relations().where(Review.id == review.id)
    return db.execute(stmt).scalar_one()


def delete_review(db: Session, review_id: int, user: User) -> None:
    review = db.get(Review, review_id)
    if review is None:
        raise NotFoundError("التقييم غير موجود")
    _assert_can_modify(review, user)

    db.delete(review)
    db.commit()
