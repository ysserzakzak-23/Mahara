"""
Portfolio (gallery) service layer.

Every operation is scoped to a specific Service and enforces that only
the owning provider (or an admin) can manage that service's gallery.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.portfolio import PortfolioItem
from app.models.user import User, UserRole
from app.schemas.portfolio import PortfolioItemCreateRequest, PortfolioItemUpdateRequest
from app.services.service_service import get_service_by_id


def list_portfolio_items(db: Session, service_id: int) -> list[PortfolioItem]:
    get_service_by_id(db, service_id)  # 404 if the service doesn't exist
    stmt = (
        select(PortfolioItem)
        .where(PortfolioItem.service_id == service_id)
        .order_by(PortfolioItem.display_order)
    )
    return list(db.execute(stmt).scalars().all())


def _assert_can_modify_service(service_provider_id: int, user: User) -> None:
    if service_provider_id != user.id and user.role != UserRole.ADMIN:
        raise PermissionDeniedError("ليس لديك صلاحية لتعديل معرض صور هذه الخدمة")


def add_portfolio_item(
    db: Session, service_id: int, user: User, payload: PortfolioItemCreateRequest
) -> PortfolioItem:
    service = get_service_by_id(db, service_id)
    _assert_can_modify_service(service.provider_id, user)

    item = PortfolioItem(service_id=service_id, **payload.model_dump())
    db.add(item)
    db.commit()
    db.refresh(item)
    return item


def update_portfolio_item(
    db: Session, item_id: int, user: User, payload: PortfolioItemUpdateRequest
) -> PortfolioItem:
    item = db.get(PortfolioItem, item_id)
    if item is None:
        raise NotFoundError("عنصر المعرض غير موجود")

    service = get_service_by_id(db, item.service_id)
    _assert_can_modify_service(service.provider_id, user)

    update_data = payload.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(item, field, value)

    db.commit()
    db.refresh(item)
    return item


def delete_portfolio_item(db: Session, item_id: int, user: User) -> None:
    item = db.get(PortfolioItem, item_id)
    if item is None:
        raise NotFoundError("عنصر المعرض غير موجود")

    service = get_service_by_id(db, item.service_id)
    _assert_can_modify_service(service.provider_id, user)

    db.delete(item)
    db.commit()
