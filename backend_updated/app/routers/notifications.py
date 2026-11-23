"""
Notification and push-device routes.
"""
from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.dependencies import get_current_user
from app.models.user import User
from app.schemas.pagination import Page, PageParams, page_or_list, page_params
from app.schemas.notification import (
    NotificationResponse,
    PushDeviceRegisterRequest,
    PushDeviceResponse,
    UnreadCountResponse,
)
from app.services import notification_service

router = APIRouter(prefix="/api/v1/notifications", tags=["Notifications"])


@router.get("", response_model=list[NotificationResponse] | Page[NotificationResponse])
def list_my_notifications(
    unread_only: bool = Query(default=False),
    params: PageParams = Depends(page_params()),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[NotificationResponse] | Page[NotificationResponse]:
    """
    Lists the authenticated user's notifications, newest first.

    Pagination is opt-in: without `page`/`page_size` this returns every
    notification as a plain array, exactly as it always has. With either of
    them it returns one page in the shared envelope.

    Reading notifications never marks them read — only
    POST /notifications/{id}/read and /read-all do that.
    """
    notifications, has_next = notification_service.list_my_notifications(
        db, current_user, unread_only=unread_only, params=params
    )
    items = [NotificationResponse.model_validate(n) for n in notifications]
    return page_or_list(items, params, has_next)


@router.get("/unread-count", response_model=UnreadCountResponse)
def get_unread_count(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> UnreadCountResponse:
    """Returns the count of unread notifications, for a badge/bell icon."""
    count = notification_service.get_unread_count(db, current_user)
    return UnreadCountResponse(unread_count=count)


@router.post("/{notification_id}/read", response_model=NotificationResponse)
def mark_notification_read(
    notification_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> NotificationResponse:
    """Marks a single notification as read."""
    notification = notification_service.mark_notification_read(db, notification_id, current_user)
    return NotificationResponse.model_validate(notification)


@router.post("/read-all", status_code=status.HTTP_200_OK)
def mark_all_notifications_read(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Marks every unread notification as read. Returns how many were updated."""
    updated_count = notification_service.mark_all_notifications_read(db, current_user)
    return {"updated_count": updated_count}


@router.post(
    "/devices", response_model=PushDeviceResponse, status_code=status.HTTP_201_CREATED
)
def register_push_device(
    payload: PushDeviceRegisterRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> PushDeviceResponse:
    """
    Registers (or reactivates) an FCM device token for push notifications.

    Called by the Flutter app on startup / after login, each time it
    obtains its FCM token from the firebase_messaging plugin.
    """
    device = notification_service.register_push_device(db, current_user, payload)
    return PushDeviceResponse.model_validate(device)


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
def unregister_push_device(
    device_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    """Removes a device registration, e.g. on logout."""
    notification_service.unregister_push_device(db, device_id, current_user)
@router.post("/test", response_model=NotificationResponse, status_code=status.HTTP_201_CREATED)
def send_test_notification(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> NotificationResponse:
    """
    Sends a test push (+ in-app notification) to every active device the
    current user has registered.
    """
    notification = notification_service.send_test_notification(db, current_user)
    return NotificationResponse.model_validate(notification)