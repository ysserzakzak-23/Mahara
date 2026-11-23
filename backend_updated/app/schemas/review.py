"""
Pydantic schemas for the Review domain.
"""
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.user import UserPublicResponse


class ReviewCreateRequest(BaseModel):
    rating: int = Field(ge=1, le=5)
    comment: Optional[str] = Field(default=None, max_length=2000)


class ReviewUpdateRequest(BaseModel):
    """Used when a reviewer edits their existing review for a service."""
    rating: Optional[int] = Field(default=None, ge=1, le=5)
    comment: Optional[str] = Field(default=None, max_length=2000)


class ReviewResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    service_id: int
    rating: int
    comment: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    reviewer: UserPublicResponse


class ServiceRatingSummaryResponse(BaseModel):
    """Aggregate rating info for a service, e.g. '4.6 ★ (23 reviews)'."""
    service_id: int
    average_rating: float
    review_count: int
