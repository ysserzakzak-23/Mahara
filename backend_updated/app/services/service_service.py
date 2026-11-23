"""
Service (listing) service layer.

Handles creation/update/deletion of marketplace listings, ownership
enforcement, and the side-effect of flipping User.is_provider to True
the first time someone lists a service.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.exceptions import NotFoundError, PermissionDeniedError, ValidationError
from app.models.availability import ProviderAvailability
from app.models.profile import UserProfile
from app.models.service import Service, ServiceStatus
from app.models.user import User, UserRole
from app.schemas.service import ServiceCreateRequest, ServiceUpdateRequest
from app.services.category_service import get_category_by_id


def _service_query_with_relations():
    """Shared eager-loading so list/detail responses never trigger N+1 queries."""
    return select(Service).options(
        selectinload(Service.category),
        selectinload(Service.provider).selectinload(User.profile),
    )


def get_service_by_id(db: Session, service_id: int) -> Service:
    stmt = _service_query_with_relations().where(Service.id == service_id)
    service = db.execute(stmt).scalar_one_or_none()
    if service is None:
        raise NotFoundError("الخدمة غير موجودة")
    return service


def list_services_by_provider(db: Session, provider_id: int) -> list[Service]:
    stmt = _service_query_with_relations().where(Service.provider_id == provider_id)
    return list(db.execute(stmt).scalars().all())


def list_active_services(
    db: Session, category_id: int | None = None, city: str | None = None
) -> list[Service]:
    """
    Plain (non-geo) listing of active services, optionally filtered by
    category and/or the provider's city. Geo-aware search lives in
    app/services/search_service.py (Phase 4); city filtering is the
    simpler alternative that doesn't require the client to have obtained
    a device location first.
    """
    stmt = _service_query_with_relations().where(Service.status == ServiceStatus.ACTIVE)
    if category_id is not None:
        stmt = stmt.where(Service.category_id == category_id)
    if city is not None:
        stmt = stmt.join(User, Service.provider_id == User.id).join(
            UserProfile, UserProfile.user_id == User.id
        ).where(UserProfile.city == city)
    return list(db.execute(stmt).scalars().all())


# Service fields a PATCH may set back to NULL by sending an explicit null.
CLEARABLE_SERVICE_FIELDS = frozenset({
    "price", "title", "latitude", "longitude", "cover_image_url", "custom_category_label",
})

WORKING_HOURS_REQUIRED_MESSAGE ="يجب تحديد أيام وساعات دوامك قبل نشر خدمة غير عن بعد"


def provider_has_working_hours(db: Session, provider_id: int) -> bool:
    """True once the provider has at least one active working-hours window."""
    found = db.execute(
        select(ProviderAvailability.id)
        .where(ProviderAvailability.provider_id == provider_id, ProviderAvailability.is_active.is_(True))
        .limit(1)
    ).first()
    return found is not None


def create_service(db: Session, provider: User, payload: ServiceCreateRequest) -> Service:
    """
    Creates a new service listing and auto-flips the provider's is_provider flag.

    A service that is NOT remote needs working hours (customers must pick a
    day and hour), so the provider has to set them first. That is asked once:
    later listings reuse the same hours.
    """
    category = get_category_by_id(db, payload.category_id)  # raises NotFoundError if invalid
    if not payload.is_remote and not provider_has_working_hours(db, provider.id):
        raise ValidationError(WORKING_HOURS_REQUIRED_MESSAGE)
    custom_category_label = _resolve_custom_category_label(category, payload.custom_category_label)

    service = Service(
        provider_id=provider.id,
        category_id=payload.category_id,
        title=(payload.title or "").strip() or None,
        description=payload.description,
        price=payload.price,
        price_unit=payload.price_unit,
        custom_category_label=custom_category_label,
        latitude=payload.latitude,
        longitude=payload.longitude,
        cover_image_url=payload.cover_image_url,
        is_remote=payload.is_remote,
    )
    db.add(service)

    if not provider.is_provider:
        provider.is_provider = True

    db.commit()
    db.refresh(service)
    return get_service_by_id(db, service.id)  # reload with eager-loaded relations


def _resolve_custom_category_label(category, raw_label: str | None) -> str | None:
    """
    Normalizes `custom_category_label` against the category it's paired
    with: required (and trimmed) when the category is the "Others"
    bucket, since "Others" alone tells a browsing customer nothing about
    what the provider actually does; cleared for every other category, so
    a stray label left over from switching category_id away from
    "Others" doesn't linger and show up somewhere by mistake.
    """
    label = (raw_label or "").strip() or None
    if category.is_other and label is None:
        raise ValidationError(
            "عند اختيار تصنيف «أخرى» يجب كتابة نوع الخدمة أو المهنة، مثل: سباك"
        )
    return label if category.is_other else None


def _assert_can_modify(service: Service, user: User) -> None:
    if service.provider_id != user.id and user.role != UserRole.ADMIN:
        raise PermissionDeniedError("ليس لديك صلاحية لتعديل هذه الخدمة")


def update_service(
    db: Session, service_id: int, user: User, payload: ServiceUpdateRequest
) -> Service:
    service = get_service_by_id(db, service_id)
    _assert_can_modify(service, user)

    update_data = payload.model_dump(exclude_unset=True)
    # An explicit null CLEARS a field (e.g. removing the price), but only
    # fields that may be empty can be cleared; a null for a required one
    # (description, category, ...) is treated as "not sent".
    update_data = {
        field: value
        for field, value in update_data.items()
        if value is not None or field in CLEARABLE_SERVICE_FIELDS
    }

    # Resolve which category will be in effect after this update, so a
    # PATCH that only changes custom_category_label (category_id
    # untouched) is still validated against the service's current
    # category, and a PATCH that changes category_id is validated
    # against the new one.
    category = (
        get_category_by_id(db, update_data["category_id"])
        if "category_id" in update_data
        else service.category
    )
    raw_label = update_data.get("custom_category_label", service.custom_category_label)
    update_data["custom_category_label"] = _resolve_custom_category_label(category, raw_label)

    # Turning a remote service into an on-site one needs working hours too.
    if update_data.get("is_remote") is False and service.is_remote:
        if not provider_has_working_hours(db, service.provider_id):
            raise ValidationError(WORKING_HOURS_REQUIRED_MESSAGE)

    for field, value in update_data.items():
        setattr(service, field, value)

    db.commit()
    db.refresh(service)
    return get_service_by_id(db, service.id)


def delete_service(db: Session, service_id: int, user: User) -> None:
    service = get_service_by_id(db, service_id)
    _assert_can_modify(service, user)

    db.delete(service)
    db.commit()
