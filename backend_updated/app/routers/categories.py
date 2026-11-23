"""
Service category routes.

Read endpoints are public (anyone browsing the marketplace needs to see
category options, including unauthenticated visitors). Write endpoints
are admin-only, since an uncontrolled taxonomy would fragment search and
break exact-match barter detection (Phase 9).
"""
from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import require_admin
from app.models.user import User
from app.schemas.category import (
    ServiceCategoryCreateRequest,
    ServiceCategoryResponse,
    ServiceCategoryUpdateRequest,
)
from app.services import category_service

router = APIRouter(prefix="/api/v1/categories", tags=["Categories"])


@router.get("", response_model=list[ServiceCategoryResponse])
def list_categories(db: Session = Depends(get_db)) -> list[ServiceCategoryResponse]:
    """Lists all active service categories. Public endpoint."""
    categories = category_service.list_categories(db, include_inactive=False)
    return [ServiceCategoryResponse.model_validate(c) for c in categories]


@router.get("/{category_id}", response_model=ServiceCategoryResponse)
def get_category(category_id: int, db: Session = Depends(get_db)) -> ServiceCategoryResponse:
    category = category_service.get_category_by_id(db, category_id)
    return ServiceCategoryResponse.model_validate(category)


@router.post(
    "", response_model=ServiceCategoryResponse, status_code=status.HTTP_201_CREATED
)
def create_category(
    payload: ServiceCategoryCreateRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_admin),
) -> ServiceCategoryResponse:
    """Creates a new service category. Admin only."""
    category = category_service.create_category(db, payload)
    return ServiceCategoryResponse.model_validate(category)


@router.patch("/{category_id}", response_model=ServiceCategoryResponse)
def update_category(
    category_id: int,
    payload: ServiceCategoryUpdateRequest,
    db: Session = Depends(get_db),
    _admin: User = Depends(require_admin),
) -> ServiceCategoryResponse:
    """Updates a service category, e.g. renaming it or toggling is_active. Admin only."""
    category = category_service.update_category(db, category_id, payload)
    return ServiceCategoryResponse.model_validate(category)
