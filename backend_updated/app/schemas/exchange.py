"""Pydantic schemas for ExchangeRequest and ExchangeProposal."""
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.models.exchange import ExchangeProposalStatus, ExchangeRequestStatus
from app.schemas.category import ServiceCategoryResponse
from app.schemas.service import ServiceListItemResponse
from app.schemas.user import UserPublicResponse


class ExchangeRequestCreateRequest(BaseModel):
    # Must be one of the current user's own services.
    offered_service_id: int
    wanted_category_id: int
    wanted_custom_category_label: Optional[str] = Field(default=None, max_length=100)

class ExchangeRequestResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    status: ExchangeRequestStatus
    user: UserPublicResponse
    offered_service: ServiceListItemResponse
    offered_category: ServiceCategoryResponse
    wanted_category: ServiceCategoryResponse
    wanted_custom_category_label: Optional[str] = None

class ExchangeRequestRankedResponse(ExchangeRequestResponse):
    """
    An exchange request as returned by «اهتماماتي» (My Interests) and the
    exchange smart search: the same request fields, plus the rating of the
    OFFERED SERVICE itself (not the owner's profile) and, for searches, the
    relevance score.
    """
    # Average of the offered service's reviews; None when it has none yet.
    offered_service_rating: Optional[float] = None
    offered_service_review_count: int = 0
    # 0-1 relevance from the Arabic smart search; None when there was no
    # search text.
    relevance_score: Optional[float] = None


class DirectMatchResponse(BaseModel):
    """One detected direct match between the current request and another open one."""
    match_type: str
    other_request: ExchangeRequestResponse


class ExchangeProposalCreateRequest(BaseModel):
    # Must be one of the proposer's own services — what they're offering
    # in return for the request owner's offered_service.
    proposed_service_id: int
    message: Optional[str] = Field(default=None, max_length=1000)


class ExchangeProposalResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    status: ExchangeProposalStatus
    message: Optional[str] = None
    proposer: UserPublicResponse
    proposed_service: ServiceListItemResponse
    request: ExchangeRequestResponse
