"""
Admin service layer: user/service moderation and platform-wide stats.

Every function here assumes the caller has already been verified as an
admin by the require_admin dependency at the router level — this layer
focuses on the moderation logic itself, not re-checking permissions.
"""
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.exceptions import NotFoundError, ValidationError
from app.models.appointment import Appointment, AppointmentStatus
from app.models.review import Review
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole
from app.core.pagination import fetch_page
from app.schemas.pagination import PageParams
from app.schemas.admin import PlatformStatsResponse


def _users_query(role: UserRole | None, is_active: bool | None):
    """
    Newest first, with the id breaking `created_at` ties.

    Two accounts created in the same second would otherwise sit in an order
    the database is free to change between calls, and a page boundary
    falling between them would repeat or skip one.
    """
    stmt = select(User).options(selectinload(User.profile))
    stmt = stmt.order_by(User.created_at.desc(), User.id.desc())
    if role is not None:
        stmt = stmt.where(User.role == role)
    if is_active is not None:
        stmt = stmt.where(User.is_active == is_active)
    return stmt


def list_users(
    db: Session,
    role: UserRole | None = None,
    is_active: bool | None = None,
    params: PageParams | None = None,
) -> tuple[list[User], bool]:
    """Returns (users, has_next); without pagination, every user and False."""
    return fetch_page(db, _users_query(role, is_active), params or PageParams())


def get_user_by_id(db: Session, user_id: int) -> User:
    stmt = select(User).options(selectinload(User.profile)).where(User.id == user_id)
    user = db.execute(stmt).scalar_one_or_none()
    if user is None:
        raise NotFoundError("المستخدم غير موجود")
    return user


def set_user_active_status(db: Session, user_id: int, is_active: bool, acting_admin: User) -> User:
    user = get_user_by_id(db, user_id)

    if user.id == acting_admin.id and not is_active:
        raise ValidationError("لا يمكنك تعطيل حسابك كمشرف")

    user.is_active = is_active
    db.commit()
    db.refresh(user)
    return user


def set_user_role(db: Session, user_id: int, role: UserRole, acting_admin: User) -> User:
    user = get_user_by_id(db, user_id)

    if user.id == acting_admin.id and role != UserRole.ADMIN:
        raise ValidationError("لا يمكنك إزالة صلاحية المشرف عن حسابك")

    user.role = role
    db.commit()
    db.refresh(user)
    return user


def _moderation_query(status_filter: ServiceStatus | None):
    """Newest first, with the id breaking `created_at` ties (see _users_query)."""
    # The category is loaded up front: each row's display_title is its category.
    stmt = select(Service).options(selectinload(Service.category))
    stmt = stmt.order_by(Service.created_at.desc(), Service.id.desc())
    if status_filter is not None:
        stmt = stmt.where(Service.status == status_filter)
    return stmt


def list_services_for_moderation(
    db: Session,
    status_filter: ServiceStatus | None = None,
    params: PageParams | None = None,
) -> tuple[list[Service], bool]:
    """Returns (services, has_next); without pagination, every service and False."""
    return fetch_page(db, _moderation_query(status_filter), params or PageParams())


def set_service_status(db: Session, service_id: int, new_status: ServiceStatus) -> Service:
    service = db.get(Service, service_id)
    if service is None:
        raise NotFoundError("الخدمة غير موجودة")

    service.status = new_status
    db.commit()
    db.refresh(service)
    return service


def get_platform_stats(db: Session) -> PlatformStatsResponse:
    """
    Computes platform-wide stats using SQL aggregates rather than loading
    every row of every table into Python — this is the only sane approach
    once the platform has any meaningful amount of data.
    """
    total_users = db.execute(select(func.count(User.id))).scalar_one()
    total_providers = db.execute(
        select(func.count(User.id)).where(User.is_provider.is_(True))
    ).scalar_one()
    active_services = db.execute(
        select(func.count(Service.id)).where(Service.status == ServiceStatus.ACTIVE)
    ).scalar_one()
    total_appointments = db.execute(select(func.count(Appointment.id))).scalar_one()
    completed_appointments = db.execute(
        select(func.count(Appointment.id)).where(Appointment.status == AppointmentStatus.COMPLETED)
    ).scalar_one()
    total_reviews = db.execute(select(func.count(Review.id))).scalar_one()
    avg_rating = db.execute(select(func.avg(Review.rating))).scalar_one()

    return PlatformStatsResponse(
        total_users=total_users,
        total_providers=total_providers,
        active_services=active_services,
        total_appointments=total_appointments,
        completed_appointments=completed_appointments,
        total_reviews=total_reviews,
        average_platform_rating=round(float(avg_rating), 2) if avg_rating is not None else 0.0,
    )
