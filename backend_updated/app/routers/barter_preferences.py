"""
Barter preference routes — declaring "I offer X, I need Y in return".

This is input data only. Match detection (direct pairs and cycles) is
built in Phase 9 and exposed under app/routers/barter_matches.py.
"""
from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.barter import BarterPreferenceCreateRequest, BarterPreferenceResponse
from app.services import barter_preference_service

router = APIRouter(prefix="/api/v1/barter-preferences", tags=["Barter Preferences"])


@router.get("/me", response_model=list[BarterPreferenceResponse])
def list_my_preferences(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[BarterPreferenceResponse]:
    """Lists the authenticated user's declared barter preferences."""
    preferences = barter_preference_service.list_my_preferences(db, current_user)
    return [BarterPreferenceResponse.model_validate(p) for p in preferences]


@router.post("", response_model=BarterPreferenceResponse, status_code=status.HTTP_201_CREATED)
def create_preference(
    payload: BarterPreferenceCreateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BarterPreferenceResponse:
    """
    Declares a new barter preference: 'I offer category A, I need category B'.

    Example: offered_category_id=Electrical Work, needed_category_id=Phone Repair.
    """
    preference = barter_preference_service.create_preference(db, current_user, payload)
    return BarterPreferenceResponse.model_validate(preference)


@router.delete("/{preference_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_preference(
    preference_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """
    Deactivates a barter preference (soft delete — preserves history for
    any past matches that referenced it).
    """
    barter_preference_service.deactivate_preference(db, preference_id, current_user)
