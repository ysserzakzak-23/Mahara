"""
Service (listing) routes.

Plain listing/filtering by category lives here. Geo-aware "find providers
near me" search is a separate router (app/routers/search.py, Phase 4) to
keep this file focused on straightforward CRUD.
"""
from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.service import (
    ServiceCreateRequest,
    ServiceListItemResponse,
    ServiceResponse,
    ServiceUpdateRequest,
)
from app.services import service_service

router = APIRouter(prefix="/api/v1/services", tags=["Services"])


@router.get("", response_model=list[ServiceListItemResponse])
def list_services(
    category_id: int | None = Query(default=None),
    city: str | None = Query(default=None),
    db: Session = Depends(get_db),
) -> list[ServiceListItemResponse]:
    """Lists all active services, optionally filtered by category and/or the provider's city. Public endpoint."""
    services = service_service.list_active_services(db, category_id=category_id, city=city)
    return [ServiceListItemResponse.model_validate(s) for s in services]


@router.get("/{service_id}", response_model=ServiceResponse)
def get_service(service_id: int, db: Session = Depends(get_db)) -> ServiceResponse:
    """Retrieves full details for a single service. Public endpoint."""
    service = service_service.get_service_by_id(db, service_id)
    return ServiceResponse.model_validate(service)


@router.get("/provider/{provider_id}", response_model=list[ServiceListItemResponse])
def list_services_by_provider(
    provider_id: int, db: Session = Depends(get_db)
) -> list[ServiceListItemResponse]:
    """Lists every service a specific provider offers. Public endpoint (provider profile page)."""
    services = service_service.list_services_by_provider(db, provider_id)
    return [ServiceListItemResponse.model_validate(s) for s in services]


@router.post("", response_model=ServiceResponse, status_code=status.HTTP_201_CREATED)
def create_service(
    payload: ServiceCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ServiceResponse:
    """
    Creates a new service listing for the authenticated user.

    Automatically marks the user as a provider (is_provider=True) if this
    is their first listing.
    """
    service = service_service.create_service(db, current_user, payload)
    return ServiceResponse.model_validate(service)


@router.patch("/{service_id}", response_model=ServiceResponse)
def update_service(
    service_id: int,
    payload: ServiceUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ServiceResponse:
    """Updates a service. Only the owning provider or an admin may do this."""
    service = service_service.update_service(db, service_id, current_user, payload)
    return ServiceResponse.model_validate(service)


@router.delete("/{service_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_service(
    service_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Deletes a service. Only the owning provider or an admin may do this."""
    service_service.delete_service(db, service_id, current_user)
