"""
Geo search routes.

Public endpoint — no authentication required to search, since browsing
the marketplace shouldn't be gated behind login (only booking/messaging
should be).
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user_optional
from app.models.user import User
from app.schemas.category import ServiceCategoryResponse
from app.schemas.search import ServiceSearchParams, ServiceSearchResultResponse
from app.schemas.semantic_search import (
    SemanticSearchParams,
    SemanticSearchResultResponse,
    SmartSearchParams,
)
from app.schemas.user import UserPublicResponse
from app.services import search_service, semantic_search_service, smart_search_service

router = APIRouter(prefix="/api/v1/search", tags=["Search"])


@router.get("/services", response_model=list[ServiceSearchResultResponse])
def search_services(
    params: Annotated[ServiceSearchParams, Query()],
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_current_user_optional),
) -> list[ServiceSearchResultResponse]:
    """
    Finds active services within `radius_km` of (latitude, longitude),
    optionally filtered by category, sorted nearest first.

    Still public (no login required), but if the caller sends a valid
    bearer token, their own listings are left out of the results — no
    point showing a provider their own service in "services near me".

    Example: GET /api/v1/search/services?latitude=30.04&longitude=31.24&radius_km=15&category_id=2
    """
    search_service.validate_search_params(params)
    exclude_provider_id = current_user.id if current_user else None
    results = search_service.search_services(db, params, exclude_provider_id=exclude_provider_id)

    return [
        ServiceSearchResultResponse(
            id=service.id,
            title=service.title,
            display_title=service.display_title,
            price=service.price,
            price_unit=service.price_unit,
            status=service.status,
            cover_image_url=service.cover_image_url,
            is_remote=service.is_remote,
            custom_category_label=service.custom_category_label,
            category=ServiceCategoryResponse.model_validate(service.category),
            provider=UserPublicResponse.model_validate(service.provider),
            distance_km=round(distance_km, 2),
        )
        for service, distance_km in results
    ]


@router.get("/semantic", response_model=list[SemanticSearchResultResponse])
def search_services_semantic(
    params: Annotated[SemanticSearchParams, Query()],
    db: Session = Depends(get_db),
) -> list[SemanticSearchResultResponse]:
    """
    AI-powered free-text search: ranks active services by embedding
    similarity to `q` instead of exact keyword matches, so a query in the
    user's own words (Arabic or English) can still surface a relevant
    listing even if the wording doesn't match the title.

    Disabled by default — returns 503 unless SEMANTIC_SEARCH_ENABLED=true
    and the `sentence-transformers` package is installed. See
    SEMANTIC_SEARCH_SETUP.md.

    Example: GET /api/v1/search/semantic?q=someone to fix my AC&limit=10
    """
    results = semantic_search_service.search_services_semantic(db, params)

    return [
        SemanticSearchResultResponse(
            id=service.id,
            title=service.title,
            display_title=service.display_title,
            price=service.price,
            price_unit=service.price_unit,
            status=service.status,
            cover_image_url=service.cover_image_url,
            is_remote=service.is_remote,
            custom_category_label=service.custom_category_label,
            category=ServiceCategoryResponse.model_validate(service.category),
            provider=UserPublicResponse.model_validate(service.provider),
            similarity_score=similarity_score,
            average_rating=rating[0],
            total_reviews=rating[1],
        )
        for service, similarity_score, rating in results
    ]


@router.get("/smart", response_model=list[SemanticSearchResultResponse])
def search_services_smart(
    params: Annotated[SmartSearchParams, Query()],
    db: Session = Depends(get_db),
) -> list[SemanticSearchResultResponse]:
    """
    The app's main search: ranks by meaning alone. The embedding model
    compares the query — with the everyday words of the trade it names, so
    "جوال" is understood as a phone — with every listing.

    Needs the model: returns 503 when SEMANTIC_SEARCH_ENABLED is off or the
    model failed to load. Optional `city` and `category_id` narrow the
    candidates. Public endpoint.

    Example: GET /api/v1/search/smart?q=بدي أصلح حنفية&city=دمشق
    """
    results = smart_search_service.search_services_smart(db, params)

    return [
        SemanticSearchResultResponse(
            id=service.id,
            title=service.title,
            display_title=service.display_title,
            price=service.price,
            price_unit=service.price_unit,
            status=service.status,
            cover_image_url=service.cover_image_url,
            is_remote=service.is_remote,
            custom_category_label=service.custom_category_label,
            category=ServiceCategoryResponse.model_validate(service.category),
            provider=UserPublicResponse.model_validate(service.provider),
            similarity_score=score,
            average_rating=rating[0],
            total_reviews=rating[1],
        )
        for service, score, rating in results
    ]
