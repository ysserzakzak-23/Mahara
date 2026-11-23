"""
Barter match routes — viewing detected matches and marking them viewed.

A manual re-scan endpoint is also exposed (admin-only) for demo/debug
purposes — matching normally runs automatically on every new preference
(see barter_preference_service.create_preference), but being able to
force a fresh scan is useful when demonstrating the feature without
needing to create a brand-new preference each time.
"""
from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user, require_admin
from app.models.barter import BarterMatch
from app.models.user import User
from app.schemas.barter import BarterMatchParticipantResponse, BarterMatchResponse
from app.services import barter_matching_service

router = APIRouter(prefix="/api/v1/barter-matches", tags=["Barter Matches"])


def _to_match_response(barter_match: BarterMatch) -> BarterMatchResponse:
    """
    Builds a BarterMatchResponse explicitly rather than via a single
    model_validate(barter_match) call, because offered_category/
    needed_category live on participant.preference, not directly on
    participant — see the NOTE in app/schemas/barter.py.
    """
    return BarterMatchResponse(
        id=barter_match.id,
        match_type=barter_match.match_type,
        cycle_length=barter_match.cycle_length,
        created_at=barter_match.created_at,
        participants=[
            BarterMatchParticipantResponse(
                sequence_order=p.sequence_order,
                is_viewed=p.is_viewed,
                user=p.user,
                offered_category=p.preference.offered_category,
                needed_category=p.preference.needed_category,
            )
            for p in barter_match.participants
        ],
    )


@router.get("/me", response_model=list[BarterMatchResponse])
def list_my_matches(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[BarterMatchResponse]:
    """Lists all barter matches the authenticated user is a participant in."""
    matches = barter_matching_service.list_my_matches(db, current_user)
    return [_to_match_response(m) for m in matches]


@router.post("/{match_id}/view", response_model=BarterMatchResponse)
def mark_match_viewed(
    match_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> BarterMatchResponse:
    """Marks the authenticated user's participation in this match as viewed."""
    barter_match = barter_matching_service.mark_match_viewed(db, match_id, current_user)
    return _to_match_response(barter_match)


@router.post("/rescan", status_code=status.HTTP_200_OK)
def rescan_for_matches(
    db: Session = Depends(get_db),
    _admin: User = Depends(require_admin),
) -> dict:
    """
    Manually re-runs the full direct + cyclic matching scan against all
    active preferences. Admin-only. Useful for demos and debugging —
    matching normally runs automatically whenever a new preference is
    created.
    """
    new_matches = barter_matching_service.run_matching(db)
    return {"new_matches_found": len(new_matches)}
