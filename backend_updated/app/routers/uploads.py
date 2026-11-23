"""
Generic image upload route.

Used by three different Flutter screens — profile avatar, service cover
photo, and per-service portfolio ("previous work") gallery — which is why
this lives as one small, content-agnostic endpoint rather than three
near-identical ones. The caller decides what to do with the returned URL
(save it as UserProfile.avatar_url, Service.cover_image_url, or a new
PortfolioItem.image_url) via the existing PATCH/POST endpoints for those
resources.

Files are stored on local disk under `uploads/` and served back by the
StaticFiles mount configured in app/main.py. For a real production
deployment this would instead upload to S3/GCS/Cloud Storage and return
a CDN URL, but local disk keeps the graduation-project setup dependency-free.
"""
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.core.exceptions import ValidationError
from app.models.user import User
from app.schemas.upload import ImageUploadResponse

router = APIRouter(prefix="/api/v1/uploads", tags=["Uploads"])

UPLOAD_DIR = Path(__file__).resolve().parent.parent.parent / "uploads"
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
MAX_FILE_SIZE_BYTES = 8 * 1024 * 1024  # 8 MB


@router.post("/image", response_model=ImageUploadResponse)
async def upload_image(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ImageUploadResponse:
    """
    Accepts a single image file and returns a public URL for it.

    Requires authentication only to keep uploads attributable/rate-limited
    to a real account — any authenticated user can call this, since the
    permission check for *where* the URL gets attached (own profile, own
    service) already happens in the respective PATCH/POST endpoints.
    """
    if file.content_type not in ALLOWED_CONTENT_TYPES:
        raise ValidationError("يُسمح بصور JPEG أو PNG أو WEBP أو GIF فقط")

    contents = await file.read()
    if len(contents) > MAX_FILE_SIZE_BYTES:
        raise ValidationError("يجب أن يكون حجم الصورة أقل من 8 ميغابايت")

    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

    extension = Path(file.filename or "").suffix.lower() or ".jpg"
    filename = f"{uuid.uuid4().hex}{extension}"
    destination = UPLOAD_DIR / filename
    destination.write_bytes(contents)

    return ImageUploadResponse(url=f"/uploads/{filename}")
