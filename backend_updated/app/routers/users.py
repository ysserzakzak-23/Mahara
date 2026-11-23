"""
Routes for the currently authenticated user: profile, location, provider toggle.

Public-facing "browse other users/providers" endpoints live in the
services/search routers added in later phases, since they need joins
against services and geo data that don't exist yet.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.user import (
    ProviderToggleRequest,
    UserLocationUpdateRequest,
    UserProfileUpdateRequest,
    UserPublicResponse,
    UserResponse,
)
from app.services import user_service

router = APIRouter(prefix="/api/v1/users", tags=["Users"])


@router.get("/me", response_model=UserResponse)
def get_my_profile(current_user: User = Depends(get_current_user)) -> UserResponse:
    """Returns the authenticated user's full profile."""
    return UserResponse.model_validate(current_user)


@router.get("/{user_id}", response_model=UserPublicResponse)
def get_public_profile(user_id: int, db: Session = Depends(get_db)) -> UserPublicResponse:
    """
    Public profile view of any user — used for the "visit provider's
    profile" screen a customer reaches from a service listing (name, bio,
    city, avatar). Deliberately the same slim UserPublicResponse used
    elsewhere (services/reviews/search) so it never leaks email or role.
    Placed after /me so the literal "me" path always wins over this
    int-typed path parameter.
    """
    user = user_service.get_user_by_id(db, user_id)
    return UserPublicResponse.model_validate(user)


@router.patch("/me", response_model=UserResponse)
def update_my_profile(
    payload: UserProfileUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserResponse:
    """Partially updates the authenticated user's profile fields."""
    updated_user = user_service.update_profile(db, current_user, payload)
    return UserResponse.model_validate(updated_user)


@router.put("/me/location", response_model=UserResponse)
def update_my_location(
    payload: UserLocationUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserResponse:
    """
    Sets the authenticated user's latitude/longitude.

    Called by the Flutter app after obtaining device location permission,
    so the user can appear in / perform geo-based provider search.
    """
    updated_user = user_service.update_location(db, current_user, payload)
    return UserResponse.model_validate(updated_user)


@router.put("/me/provider-status", response_model=UserResponse)
def set_provider_status(
    payload: ProviderToggleRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UserResponse:
    """
    Manually opts the user in/out of being a service provider.

    Note: creating a service (Phase 3) will also auto-set is_provider=True,
    so this endpoint mainly matters for opting OUT, or opting in ahead of
    listing a first service.
    """
    updated_user = user_service.set_provider_status(db, current_user, payload.is_provider)
    return UserResponse.model_validate(updated_user)
