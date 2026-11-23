"""
Pydantic schemas for BarterPreference (input) and BarterMatch (output).
"""
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.barter import BarterMatchType
from app.schemas.category import ServiceCategoryResponse
from app.schemas.user import UserPublicResponse


class BarterPreferenceCreateRequest(BaseModel):
    offered_category_id: int
    needed_category_id: int

    @model_validator(mode="after")
    def offered_and_needed_must_differ(self) -> "BarterPreferenceCreateRequest":
        if self.offered_category_id == self.needed_category_id:
            raise ValueError("يجب أن يكون التصنيف المعروض مختلفاً عن التصنيف المطلوب")
        return self


class BarterPreferenceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    is_active: bool
    offered_category: ServiceCategoryResponse
    needed_category: ServiceCategoryResponse


class BarterMatchParticipantResponse(BaseModel):
    """
    One participant's view within a match: who they are, what they
    offer/need (via their preference), and their position in the cycle.

    NOTE: offered_category/needed_category are NOT direct attributes on
    the BarterParticipant ORM model — they live on
    BarterParticipant.preference.offered_category / .needed_category.
    Because of this indirection, instances of this schema are built
    explicitly in app/services/barter_matching_service.py rather than via
    a plain BarterMatchParticipantResponse.model_validate(participant)
    call, which would fail to find these fields via flat attribute lookup.
    """
    model_config = ConfigDict(from_attributes=True)

    sequence_order: int
    is_viewed: bool
    user: UserPublicResponse
    offered_category: ServiceCategoryResponse
    needed_category: ServiceCategoryResponse


class BarterMatchResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    match_type: BarterMatchType
    cycle_length: int
    created_at: datetime
    participants: list[BarterMatchParticipantResponse]
