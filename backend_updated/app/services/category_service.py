"""
Category service layer.

Categories are admin-managed lookup data (see app/routers/categories.py
for the public read endpoints and the admin-guarded write endpoints).
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError, NotFoundError
from app.models.category import ServiceCategory
from app.schemas.category import ServiceCategoryCreateRequest, ServiceCategoryUpdateRequest


def list_categories(db: Session, include_inactive: bool = False) -> list[ServiceCategory]:
    stmt = select(ServiceCategory).order_by(ServiceCategory.name)
    if not include_inactive:
        stmt = stmt.where(ServiceCategory.is_active.is_(True))
    return list(db.execute(stmt).scalars().all())


def get_category_by_id(db: Session, category_id: int) -> ServiceCategory:
    category = db.get(ServiceCategory, category_id)
    if category is None:
        raise NotFoundError("تصنيف الخدمة غير موجود")
    return category


def create_category(db: Session, payload: ServiceCategoryCreateRequest) -> ServiceCategory:
    existing = db.execute(
        select(ServiceCategory).where(ServiceCategory.name == payload.name)
    ).scalar_one_or_none()
    if existing is not None:
        raise ConflictError(f"يوجد تصنيف بالاسم '{payload.name}' مسبقاً")

    if payload.is_other:
        _clear_other_flag(db)

    category = ServiceCategory(**payload.model_dump())
    db.add(category)
    db.commit()
    db.refresh(category)
    return category


def update_category(
    db: Session, category_id: int, payload: ServiceCategoryUpdateRequest
) -> ServiceCategory:
    category = get_category_by_id(db, category_id)
    update_data = payload.model_dump(exclude_unset=True)

    if update_data.get("is_other") is True:
        _clear_other_flag(db, exclude_id=category_id)

    for field, value in update_data.items():
        setattr(category, field, value)

    db.commit()
    db.refresh(category)
    return category


def _clear_other_flag(db: Session, exclude_id: int | None = None) -> None:
    """
    Keeps 'at most one category is the Others bucket' true whenever a
    category is being marked as it — unsets is_other on whichever
    category held it before, rather than requiring the admin to remember
    to do that themselves in a separate request.
    """
    stmt = select(ServiceCategory).where(ServiceCategory.is_other.is_(True))
    if exclude_id is not None:
        stmt = stmt.where(ServiceCategory.id != exclude_id)
    for other_category in db.execute(stmt).scalars().all():
        other_category.is_other = False
