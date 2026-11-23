"""
Barter preference service layer — CRUD for "I offer X, I need Y" declarations.

Kept separate from the barter MATCHING service (app/services/
barter_matching_service.py), which contains the graph algorithms
(direct-pair and cycle detection) that operate on the data this file
manages. Splitting them keeps each file focused: this one is plain CRUD,
the matching service is algorithmic.

Per the product decision, matching runs automatically every time a new
preference is created — see the call to
barter_matching_service.run_matching_for_new_preference() in
create_preference() below.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.exceptions import ConflictError, NotFoundError, PermissionDeniedError
from app.models.barter import BarterPreference
from app.models.user import User
from app.schemas.barter import BarterPreferenceCreateRequest
from app.services import barter_matching_service
from app.services.category_service import get_category_by_id


def _query_with_relations():
    return select(BarterPreference).options(
        selectinload(BarterPreference.offered_category),
        selectinload(BarterPreference.needed_category),
    )


def list_my_preferences(db: Session, user: User) -> list[BarterPreference]:
    stmt = _query_with_relations().where(BarterPreference.user_id == user.id)
    return list(db.execute(stmt).scalars().all())


def create_preference(
    db: Session, user: User, payload: BarterPreferenceCreateRequest
) -> BarterPreference:
    get_category_by_id(db, payload.offered_category_id)
    get_category_by_id(db, payload.needed_category_id)

    existing = db.execute(
        select(BarterPreference).where(
            BarterPreference.user_id == user.id,
            BarterPreference.offered_category_id == payload.offered_category_id,
            BarterPreference.needed_category_id == payload.needed_category_id,
        )
    ).scalar_one_or_none()
    if existing is not None:
        raise ConflictError("لديك هذا التفضيل للمقايضة مسبقاً")

    preference = BarterPreference(user_id=user.id, **payload.model_dump())
    db.add(preference)
    db.commit()
    db.refresh(preference)

    # Per the product decision: matching runs automatically on every new
    # preference. Run AFTER the commit above so the new preference is
    # already durably saved and visible to the matching query regardless
    # of what happens next.
    barter_matching_service.run_matching_for_new_preference(db)

    stmt = _query_with_relations().where(BarterPreference.id == preference.id)
    return db.execute(stmt).scalar_one()


def deactivate_preference(db: Session, preference_id: int, user: User) -> None:
    preference = db.get(BarterPreference, preference_id)
    if preference is None:
        raise NotFoundError("تفضيل المقايضة غير موجود")
    if preference.user_id != user.id:
        raise PermissionDeniedError("ليس لديك صلاحية لتعديل هذا التفضيل")

    preference.is_active = False
    db.commit()
