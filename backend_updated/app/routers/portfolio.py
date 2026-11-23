"""
Portfolio (gallery) routes, nested under a specific service.

Nesting under /services/{service_id}/portfolio makes the ownership
relationship explicit in the URL and avoids needing a separate top-level
resource ID namespace just to look up "which service does this image belong to".
"""
from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.portfolio import (
    PortfolioItemCreateRequest,
    PortfolioItemResponse,
    PortfolioItemUpdateRequest,
)
from app.services import portfolio_service

router = APIRouter(prefix="/api/v1/services/{service_id}/portfolio", tags=["Portfolio"])


@router.get("", response_model=list[PortfolioItemResponse])
def list_portfolio_items(
    service_id: int, db: Session = Depends(get_db)
) -> list[PortfolioItemResponse]:
    """Lists gallery images for a service, ordered for display. Public endpoint."""
    items = portfolio_service.list_portfolio_items(db, service_id)
    return [PortfolioItemResponse.model_validate(i) for i in items]


@router.post("", response_model=PortfolioItemResponse, status_code=status.HTTP_201_CREATED)
def add_portfolio_item(
    service_id: int,
    payload: PortfolioItemCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> PortfolioItemResponse:
    """Adds a gallery image to a service. Only the owning provider or an admin may do this."""
    item = portfolio_service.add_portfolio_item(db, service_id, current_user, payload)
    return PortfolioItemResponse.model_validate(item)


@router.patch("/{item_id}", response_model=PortfolioItemResponse)
def update_portfolio_item(
    service_id: int,
    item_id: int,
    payload: PortfolioItemUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> PortfolioItemResponse:
    """Updates a gallery image's caption or display order."""
    item = portfolio_service.update_portfolio_item(db, item_id, current_user, payload)
    return PortfolioItemResponse.model_validate(item)


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_portfolio_item(
    service_id: int,
    item_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Removes a gallery image."""
    portfolio_service.delete_portfolio_item(db, item_id, current_user)
