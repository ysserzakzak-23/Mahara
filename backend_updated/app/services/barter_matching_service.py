"""
Barter matching service — bridges the pure graph algorithm in
app/algorithms/barter_matching.py to the database.

Responsibilities:
  1. Load all active BarterPreference rows as PreferenceEdge objects.
  2. Run find_direct_matches and find_cyclic_matches.
  3. Persist any NEWLY found matches as BarterMatch + BarterParticipant rows
     (skipping matches already recorded, so re-running detection after
     every new preference doesn't create duplicate match records for
     pairs/cycles that were already found before).
  4. Notify every participant in each newly created match.

run_matching_for_new_preference() is the function barter_preference_service
calls right after successfully creating a preference (per the product
decision: matching runs automatically on every new preference).
"""
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.algorithms.barter_matching import (
    MatchResult,
    PreferenceEdge,
    find_cyclic_matches,
    find_direct_matches,
)
from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.barter import BarterMatch, BarterMatchType, BarterParticipant, BarterPreference
from app.models.notification import NotificationType
from app.models.user import User
from app.services import notification_service

logger = logging.getLogger(__name__)

MAX_CYCLE_LENGTH = 3  # product decision: cap cyclic search at 3 participants


# --------------------------------------------------- reading recorded matches
#
# The two functions below back GET /barter-matches/me and
# POST /barter-matches/{id}/view. They used to sit in the router, which
# made it the only router in the project running its own query, ownership
# check, mutation and commit.


def _match_query_with_relations():
    """
    A match with the relationships the response needs: each participant's
    user and preference. Loaded up front so serialising a list of matches
    does not issue a query per participant.
    """
    return select(BarterMatch).options(
        selectinload(BarterMatch.participants).selectinload(BarterParticipant.user),
        selectinload(BarterMatch.participants).selectinload(BarterParticipant.preference),
    )


def list_my_matches(db: Session, user: User) -> list[BarterMatch]:
    """
    Every match this user is a participant in, newest first.

    The join is what scopes the list to the user; `unique()` collapses the
    duplicate match rows it produces when a match has several
    participants.
    """
    stmt = (
        _match_query_with_relations()
        .join(BarterParticipant, BarterParticipant.match_id == BarterMatch.id)
        .where(BarterParticipant.user_id == user.id)
        .order_by(BarterMatch.created_at.desc())
    )
    return list(db.execute(stmt).scalars().unique().all())


def mark_match_viewed(db: Session, match_id: int, user: User) -> BarterMatch:
    """
    Marks this user's own participation in `match_id` as viewed, and
    returns the match.

    Only a participant may do this, and only their own row is touched —
    the other participants' flags are each theirs to set. A match that
    does not exist is a 404; one the caller is not part of is a 403, and
    nothing is written in either case.

    The flag is assigned unconditionally, so viewing an already-viewed
    match is harmless: SQLAlchemy emits no UPDATE when the value has not
    changed. The refresh afterwards is what the caller serialises.
    """
    stmt = _match_query_with_relations().where(BarterMatch.id == match_id)
    barter_match = db.execute(stmt).scalar_one_or_none()
    if barter_match is None:
        raise NotFoundError("مطابقة المقايضة غير موجودة")

    my_participation = next(
        (p for p in barter_match.participants if p.user_id == user.id), None
    )
    if my_participation is None:
        raise PermissionDeniedError("أنت لست طرفاً في مطابقة المقايضة هذه")

    my_participation.is_viewed = True
    db.commit()
    db.refresh(barter_match)

    return barter_match


def _load_active_preference_edges(db: Session) -> list[PreferenceEdge]:
    stmt = select(BarterPreference).where(BarterPreference.is_active.is_(True))
    preferences = db.execute(stmt).scalars().all()
    return [
        PreferenceEdge(
            preference_id=p.id,
            user_id=p.user_id,
            offered_category_id=p.offered_category_id,
            needed_category_id=p.needed_category_id,
        )
        for p in preferences
    ]


def _match_already_recorded(db: Session, match: MatchResult) -> bool:
    """
    Checks whether a BarterMatch already exists for this exact set of
    preference_ids, so re-running detection doesn't create duplicate
    BarterMatch rows for a pair/cycle that was already found and notified
    about previously.

    Implemented by checking, for the FIRST preference_id in the match,
    whether any existing BarterParticipant row using that preference_id
    belongs to a match whose participant set is identical to this one.
    This is a simple correctness-first approach appropriate for the small
    candidate set sizes this algorithm operates on (capped at 3
    participants per match, and only run against the active-preferences
    subset) — not optimized for huge match volumes.
    """
    target_preference_ids = {edge.preference_id for edge in match.edges}

    stmt = (
        select(BarterParticipant.match_id)
        .where(BarterParticipant.preference_id.in_(target_preference_ids))
    )
    candidate_match_ids = {row[0] for row in db.execute(stmt).all()}

    for match_id in candidate_match_ids:
        existing_preference_ids = set(
            db.execute(
                select(BarterParticipant.preference_id).where(BarterParticipant.match_id == match_id)
            )
            .scalars()
            .all()
        )
        if existing_preference_ids == target_preference_ids:
            return True

    return False


def _persist_match(db: Session, match: MatchResult, match_type: BarterMatchType) -> BarterMatch:
    barter_match = BarterMatch(match_type=match_type, cycle_length=match.length)
    db.add(barter_match)
    db.flush()  # assigns barter_match.id without committing yet

    for order, edge in enumerate(match.edges):
        db.add(
            BarterParticipant(
                match_id=barter_match.id,
                user_id=edge.user_id,
                preference_id=edge.preference_id,
                sequence_order=order,
            )
        )

    db.commit()
    db.refresh(barter_match)
    return barter_match


def _notify_participants(db: Session, barter_match: BarterMatch) -> None:
    stmt = (
        select(BarterParticipant)
        .options(
            selectinload(BarterParticipant.user),
            selectinload(BarterParticipant.preference),
        )
        .where(BarterParticipant.match_id == barter_match.id)
    )
    participants = db.execute(stmt).scalars().all()

    match_label = "مطابقة مقايضة مباشرة" if barter_match.match_type == BarterMatchType.DIRECT else (
        f"دورة مقايضة بين {barter_match.cycle_length} أطراف"
    )

    for participant in participants:
        notification_service.notify_user(
            db,
            user_id=participant.user_id,
            notification_type=NotificationType.BARTER_MATCH,
            title="تم العثور على مطابقة مقايضة!",
            message=f"وجدنا {match_label} تناسب تفضيلات المقايضة الخاصة بك. تفقّدها الآن!",
            related_entity_id=barter_match.id,
        )


def run_matching(db: Session) -> list[BarterMatch]:
    """
    Runs the full direct + cyclic matching pass against all currently
    active preferences, persists any matches not already recorded, and
    notifies their participants.

    Returns the list of NEWLY created BarterMatch rows from this run
    (an empty list if nothing new was found, which is the common case).
    """
    edges = _load_active_preference_edges(db)

    direct_results = find_direct_matches(edges)
    cyclic_results = find_cyclic_matches(edges, max_length=MAX_CYCLE_LENGTH)

    newly_created: list[BarterMatch] = []

    for result in direct_results:
        if not _match_already_recorded(db, result):
            barter_match = _persist_match(db, result, BarterMatchType.DIRECT)
            _notify_participants(db, barter_match)
            newly_created.append(barter_match)

    for result in cyclic_results:
        if not _match_already_recorded(db, result):
            barter_match = _persist_match(db, result, BarterMatchType.CYCLIC)
            _notify_participants(db, barter_match)
            newly_created.append(barter_match)

    if newly_created:
        logger.info("Barter matching run found %d new match(es)", len(newly_created))

    return newly_created


def run_matching_for_new_preference(db: Session) -> list[BarterMatch]:
    """
    Entry point called by barter_preference_service right after a new
    BarterPreference is successfully created (per the product decision:
    matching runs automatically on every new preference).

    Currently re-scans ALL active preferences rather than only checking
    matches involving the newly created one — simpler to reason about
    and correct, and cheap enough given the small expected scale of a
    graduation-project marketplace. If preference volume grows large
    enough for this to matter, this is the function to optimize first
    (e.g. by only searching chains that include the new preference).
    """
    return run_matching(db)
