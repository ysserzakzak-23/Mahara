"""
Pydantic schemas for the Service domain.
"""
from datetime import datetime
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from app.models.service import ServiceStatus
from app.schemas.category import ServiceCategoryResponse
from app.schemas.user import UserPublicResponse


class ServiceCreateRequest(BaseModel):
    category_id: int
    # Optional and no longer sent by the app: a service is identified by its
    # category (Service.display_title). Accepted for older clients.
    title: Optional[str] = Field(default=None, min_length=3, max_length=150)
    description: str = Field(min_length=10, max_length=5000)
    # Optional: omitted / null means "no price given" and is stored as NULL,
    # never as 0. When present it must be positive.
    price: Optional[Decimal] = Field(default=None, gt=0, decimal_places=2)
    price_unit: str = Field(default="fixed", max_length=30)

    # Required when category_id points at the "Others" category (see
    # ServiceCategory.is_other) — the actual trade, e.g. "سباك". Ignored
    # for any other category. Validated in service_service.create_service,
    # since it depends on the category being fetched from the DB first.
    custom_category_label: Optional[str] = Field(default=None, max_length=100)

    # Optional: only needed if the service is offered from a location
    # different from the provider's profile location (e.g. a shop address).
    latitude: Optional[float] = Field(default=None, ge=-90, le=90)
    longitude: Optional[float] = Field(default=None, ge=-180, le=180)

    # The main/cover photo for the listing (returned by POST /api/v1/uploads/image).
    cover_image_url: Optional[str] = Field(default=None, max_length=500)

    # True if this service is delivered online/remotely rather than in person.
    is_remote: bool = False


class ServiceUpdateRequest(BaseModel):
    """
    PATCH-style partial update. All fields optional; a field that is not
    sent is left unchanged. `price` may be sent as null to REMOVE the price
    (and `title` as null to drop a legacy name).
    """
    category_id: Optional[int] = None
    title: Optional[str] = Field(default=None, min_length=3, max_length=150)
    description: Optional[str] = Field(default=None, min_length=10, max_length=5000)
    price: Optional[Decimal] = Field(default=None, gt=0, decimal_places=2)
    price_unit: Optional[str] = Field(default=None, max_length=30)
    status: Optional[ServiceStatus] = None
    custom_category_label: Optional[str] = Field(default=None, max_length=100)
    latitude: Optional[float] = Field(default=None, ge=-90, le=90)
    longitude: Optional[float] = Field(default=None, ge=-180, le=180)
    cover_image_url: Optional[str] = Field(default=None, max_length=500)
    is_remote: Optional[bool] = None


class ServiceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    # Legacy free-text name (null for services published without one).
    title: Optional[str] = None
    # What to show as the service's name: its category (see
    # Service.display_title). Always present.
    display_title: str
    description: str
    # null = no price given (shown as «السعر غير محدد»).
    price: Optional[Decimal] = None
    price_unit: str
    status: ServiceStatus
    custom_category_label: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    cover_image_url: Optional[str] = None
    is_remote: bool
    created_at: datetime

    category: ServiceCategoryResponse
    provider: UserPublicResponse


class ServiceListItemResponse(BaseModel):
    """
    Slimmer shape for list/search endpoints — avoids serializing full
    descriptions and provider profiles for every row in a results page.
    """
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: Optional[str] = None
    display_title: str
    price: Optional[Decimal] = None
    price_unit: str
    status: ServiceStatus
    cover_image_url: Optional[str] = None
    is_remote: bool
    custom_category_label: Optional[str] = None
    category: ServiceCategoryResponse
    provider: UserPublicResponse
