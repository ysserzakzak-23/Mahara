"""Pydantic schema for the generic image upload endpoint."""
from pydantic import BaseModel


class ImageUploadResponse(BaseModel):
    # Relative path (e.g. "/uploads/ab12cd34.jpg"); the Flutter app joins
    # this with ApiConfig.baseUrl to build a full displayable URL, the same
    # way it already does for API endpoint paths.
    url: str
