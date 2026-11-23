"""
Pydantic schemas for PortfolioItem (the provider's gallery for a service).
"""
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class PortfolioItemCreateRequest(BaseModel):
    image_url: str = Field(min_length=1, max_length=500)
    caption: Optional[str] = Field(default=None, max_length=255)
    display_order: int = Field(default=0, ge=0)


class PortfolioItemUpdateRequest(BaseModel):
    caption: Optional[str] = Field(default=None, max_length=255)
    display_order: Optional[int] = Field(default=None, ge=0)


class PortfolioItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    service_id: int
    image_url: str
    caption: Optional[str] = None
    display_order: int
