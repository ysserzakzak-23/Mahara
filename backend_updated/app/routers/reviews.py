"""
Review routes, nested under a specific service — consistent with the
portfolio router's URL pattern (Phase 3).

POST is upsert-style: posting again when the user already has a review
for this service updates it rather than erroring (see
app/services/review_service.create_or_update_review).
"""
from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.review import (
    ReviewCreateRequest,
    ReviewResponse,
    ReviewUpdateRequest,
    ServiceRatingSummaryResponse,
)
from app.services import review_service

router = APIRouter(prefix="/api/v1/services/{service_id}/reviews", tags=["Reviews"])


@router.get("", response_model=list[ReviewResponse])
def list_reviews(service_id: int, db: Session = Depends(get_db)) -> list[ReviewResponse]:
    """Lists all reviews for a service, newest first. Public endpoint."""
    reviews = review_service.list_reviews_for_service(db, service_id)
    return [ReviewResponse.model_validate(r) for r in reviews]


@router.get("/summary", response_model=ServiceRatingSummaryResponse)
def get_rating_summary(service_id: int, db: Session = Depends(get_db)) -> ServiceRatingSummaryResponse:
    """Returns the average rating and review count for a service. Public endpoint."""
    return review_service.get_rating_summary(db, service_id)


@router.post("", response_model=ReviewResponse, status_code=status.HTTP_201_CREATED)
def create_or_update_review(
    service_id: int,
    payload: ReviewCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReviewResponse:
    """
    Creates a review for a service, or updates the authenticated user's
    existing review for it if one already exists (one review per user
    per service).
    """
    review = review_service.create_or_update_review(db, service_id, current_user, payload)
    return ReviewResponse.model_validate(review)


@router.patch("/{review_id}", response_model=ReviewResponse)
def update_review(
    service_id: int,
    review_id: int,
    payload: ReviewUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReviewResponse:
    """Updates a specific review. Only the original reviewer or an admin may do this."""
    review = review_service.update_review(db, review_id, current_user, payload)
    return ReviewResponse.model_validate(review)


@router.delete("/{review_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_review(
    service_id: int,
    review_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Deletes a review. Only the original reviewer or an admin may do this."""
    review_service.delete_review(db, review_id, current_user)
