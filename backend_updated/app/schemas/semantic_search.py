"""
Pydantic schemas for AI-powered semantic search.
See app/services/semantic_search_service.py.
"""
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.service import ServiceListItemResponse


class SemanticSearchParams(BaseModel):
    """
    Query parameters for GET /search/semantic.

    `q` is free text in the user's own words — Arabic or English — e.g.
    "بدي حدا يصلح التكييف" or "someone to fix my AC". Matched against each
    service's title/description/category by embedding similarity rather
    than exact keywords, so wording doesn't have to match the listing.
    """
    q: str = Field(min_length=1, max_length=300)
    category_id: Optional[int] = None
    # Cosine similarity cutoff (0-1). Raise it for stricter/more relevant
    # results, lower it to widen the net.
    threshold: float = Field(default=0.35, ge=0.0, le=1.0)
    limit: int = Field(default=10, ge=1, le=50)


class SemanticSearchResultResponse(ServiceListItemResponse):
    """
    A list item (same fields as every other service list, including the cover
    photo the app shows on the card) annotated with its semantic similarity
    score and rating.
    """

    similarity_score: float
    average_rating: float
    total_reviews: int


class SmartSearchParams(BaseModel):
    """
    Query parameters for GET /search/smart — the app's main search.

    `q` is free Arabic text in the user's own words, e.g. "بدي أصلح حنفية".
    `city` and `category_id` narrow the candidates before ranking.
    """
    q: str = Field(min_length=1, max_length=200)
    category_id: Optional[int] = None
    city: Optional[str] = None
    limit: int = Field(default=30, ge=1, le=50)
