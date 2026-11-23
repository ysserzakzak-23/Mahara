"""
Admin dashboard routes.

Every endpoint here is guarded by require_admin (see app/core/dependencies.py) —
FastAPI's dependency injection means this guard runs BEFORE the route body
executes, so there's no risk of a route accidentally running privileged
logic before checking permissions.
"""
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import require_admin
from app.models.service import ServiceStatus
from app.models.user import User, UserRole
from app.schemas.pagination import Page, PageParams, page_or_list, page_params
from app.schemas.admin import (
    AdminServiceResponse,
    AdminSetServiceStatusRequest,
    AdminSetUserActiveRequest,
    AdminSetUserRoleRequest,
    AdminUserResponse,
    PlatformStatsResponse,
)
from app.services import admin_service

router = APIRouter(prefix="/api/v1/admin", tags=["Admin"], dependencies=[Depends(require_admin)])


@router.get("/stats", response_model=PlatformStatsResponse)
def get_platform_stats(db: Session = Depends(get_db)) -> PlatformStatsResponse:
    """Returns platform-wide aggregate stats for the admin dashboard."""
    return admin_service.get_platform_stats(db)


@router.get("/users", response_model=list[AdminUserResponse] | Page[AdminUserResponse])
def list_users(
    role: UserRole | None = Query(default=None),
    is_active: bool | None = Query(default=None),
    params: PageParams = Depends(page_params()),
    db: Session = Depends(get_db),
) -> list[AdminUserResponse] | Page[AdminUserResponse]:
    """
    Lists all users, optionally filtered by role and/or active status.

    Pagination is opt-in: without `page`/`page_size` this returns every
    matching user as a plain array, as it always has.

    No `total`: the dashboard shows no count, and `has_next` already tells
    the app whether to keep asking. Counting the matching rows on every
    page would be a second full scan nothing displays.
    """
    users, has_next = admin_service.list_users(db, role=role, is_active=is_active, params=params)
    items = [AdminUserResponse.model_validate(u) for u in users]
    return page_or_list(items, params, has_next)


@router.get("/users/{user_id}", response_model=AdminUserResponse)
def get_user(user_id: int, db: Session = Depends(get_db)) -> AdminUserResponse:
    """Retrieves full details for a single user."""
    user = admin_service.get_user_by_id(db, user_id)
    return AdminUserResponse.model_validate(user)


@router.put("/users/{user_id}/active-status", response_model=AdminUserResponse)
def set_user_active_status(
    user_id: int,
    payload: AdminSetUserActiveRequest,
    db: Session = Depends(get_db),
    acting_admin: User = Depends(require_admin),
) -> AdminUserResponse:
    """
    Activates or deactivates a user account. A deactivated user cannot log
    in (see get_current_user / authenticate_user, which both check is_active).
    """
    user = admin_service.set_user_active_status(db, user_id, payload.is_active, acting_admin)
    return AdminUserResponse.model_validate(user)


@router.put("/users/{user_id}/role", response_model=AdminUserResponse)
def set_user_role(
    user_id: int,
    payload: AdminSetUserRoleRequest,
    db: Session = Depends(get_db),
    acting_admin: User = Depends(require_admin),
) -> AdminUserResponse:
    """Promotes a user to admin, or demotes an admin back to a regular user."""
    user = admin_service.set_user_role(db, user_id, payload.role, acting_admin)
    return AdminUserResponse.model_validate(user)


@router.get(
    "/services", response_model=list[AdminServiceResponse] | Page[AdminServiceResponse]
)
def list_services_for_moderation(
    status_filter: ServiceStatus | None = Query(default=None, alias="status"),
    params: PageParams = Depends(page_params()),
    db: Session = Depends(get_db),
) -> list[AdminServiceResponse] | Page[AdminServiceResponse]:
    """
    Lists all services for moderation review, optionally filtered by status.

    Opt-in pagination, and no `total` — see list_users.
    """
    services, has_next = admin_service.list_services_for_moderation(
        db, status_filter=status_filter, params=params
    )
    items = [AdminServiceResponse.model_validate(s) for s in services]
    return page_or_list(items, params, has_next)


@router.put("/services/{service_id}/status", response_model=AdminServiceResponse)
def set_service_status(
    service_id: int,
    payload: AdminSetServiceStatusRequest,
    db: Session = Depends(get_db),
) -> AdminServiceResponse:
    """
    Sets a service's moderation status — typically used to SUSPEND a
    service that violates platform rules, or to reinstate it back to
    ACTIVE afterward.
    """
    service = admin_service.set_service_status(db, service_id, payload.status)
    return AdminServiceResponse.model_validate(service)
