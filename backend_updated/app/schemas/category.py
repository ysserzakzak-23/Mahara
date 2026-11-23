"""
Pydantic schemas for ServiceCategory.
"""
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class ServiceCategoryCreateRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    description: Optional[str] = Field(default=None, max_length=500)
    icon_name: Optional[str] = Field(default=None, max_length=100)
    is_other: bool = False


class ServiceCategoryUpdateRequest(BaseModel):
    name: Optional[str] = Field(default=None, min_length=2, max_length=100)
    description: Optional[str] = Field(default=None, max_length=500)
    icon_name: Optional[str] = Field(default=None, max_length=100)
    is_active: Optional[bool] = None
    is_other: Optional[bool] = None


class ServiceCategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    description: Optional[str] = None
    icon_name: Optional[str] = None
    is_active: bool
    is_other: bool
