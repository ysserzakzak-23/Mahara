"""
Notification service layer.

`notify_user()` is the single entry point every other part of the app
should call to notify a user of something — it always writes the in-app
Notification row (the source of truth for "what happened, has it been
read"), then best-effort fans out an FCM push to every active PushDevice
the user has registered. A push failure never affects whether the
in-app notification was created.
"""
import logging

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.core.pagination import fetch_page
from app.models.notification import Notification, NotificationType, PushDevice
from app.models.user import User
from app.schemas.pagination import PageParams
from app.schemas.notification import PushDeviceRegisterRequest
from app.utils.fcm_client import is_invalid_token_error, send_push_notification

logger = logging.getLogger(__name__)


def notify_user(
    db: Session,
    user_id: int,
    notification_type: NotificationType,
    title: str,
    message: str,
    related_entity_id: int | None = None,
) -> Notification:
    """
    Creates an in-app notification for `user_id` and best-effort pushes it
    to all of their active registered devices.

    This function commits its own transaction. It's called as a
    side-effect from within other services (e.g. appointment_service
    after a successful booking) — kept as a separate commit rather than
    folded into the caller's transaction so that a notification failure
    can never roll back the primary action (e.g. the appointment itself)
    that triggered it.
    """
    notification = Notification(
        user_id=user_id,
        type=notification_type,
        title=title,
        message=message,
        related_entity_id=related_entity_id,
    )
    db.add(notification)
    db.commit()
    db.refresh(notification)

    _dispatch_push_to_all_devices(db, user_id, title, message, notification_type, related_entity_id)

    return notification


def _dispatch_push_to_all_devices(
    db: Session,
    user_id: int,
    title: str,
    message: str,
    notification_type: NotificationType,
    related_entity_id: int | None,
) -> None:
    stmt = select(PushDevice).where(PushDevice.user_id == user_id, PushDevice.is_active.is_(True))
    devices = list(db.execute(stmt).scalars().all())

    push_data = {"type": notification_type.value}
    if related_entity_id is not None:
        push_data["related_entity_id"] = related_entity_id

    deactivated_any = False
    for device in devices:
        success, error = send_push_notification(device.fcm_token, title, message, data=push_data)
        if not success and error is not None and is_invalid_token_error(error):
            logger.info("Deactivating dead push token for user_id=%s", user_id)
            device.is_active = False
            deactivated_any = True

    if deactivated_any:
        db.commit()


def _notifications_query(user: User, unread_only: bool):
    """
    One user's notifications, newest first.

    The id breaks ties: two notifications can share a `created_at` (they are
    written in the same transaction), and a page boundary that falls between
    them would otherwise repeat or skip one.
    """
    stmt = select(Notification).where(Notification.user_id == user.id)
    if unread_only:
        stmt = stmt.where(Notification.is_read.is_(False))
    return stmt.order_by(Notification.created_at.desc(), Notification.id.desc())


def list_my_notifications(
    db: Session,
    user: User,
    unread_only: bool = False,
    params: PageParams | None = None,
) -> tuple[list[Notification], bool]:
    """
    Returns (notifications, has_next).

    Without pagination (the default) that is every notification and False —
    the behaviour this endpoint has always had. Reading a page never changes
    a notification: `is_read` is only set by the mark-read endpoints.
    """
    return fetch_page(db, _notifications_query(user, unread_only), params or PageParams())


def get_unread_count(db: Session, user: User) -> int:
    stmt = select(func.count(Notification.id)).where(
        Notification.user_id == user.id, Notification.is_read.is_(False)
    )
    return db.execute(stmt).scalar_one()


def mark_notification_read(db: Session, notification_id: int, user: User) -> Notification:
    notification = db.get(Notification, notification_id)
    if notification is None:
        raise NotFoundError("الإشعار غير موجود")
    if notification.user_id != user.id:
        raise PermissionDeniedError("ليس لديك صلاحية للوصول إلى هذا الإشعار")

    notification.is_read = True
    db.commit()
    db.refresh(notification)
    return notification


def mark_all_notifications_read(db: Session, user: User) -> int:
    """Marks every unread notification for the user as read. Returns the count updated."""
    stmt = select(Notification).where(Notification.user_id == user.id, Notification.is_read.is_(False))
    unread = list(db.execute(stmt).scalars().all())
    for notification in unread:
        notification.is_read = True
    db.commit()
    return len(unread)


def register_push_device(db: Session, user: User, payload: PushDeviceRegisterRequest) -> PushDevice:
    """
    Registers an FCM token for the user, or reactivates/updates an existing
    registration if this exact token is already on file.

    This upsert-on-token logic exists because PushDevice.fcm_token has a
    DB-level UNIQUE constraint (a given FCM token can only ever belong to
    one device registration), and the same token legitimately gets
    re-sent by the Flutter app every time it starts up — a plain INSERT
    would fail with an IntegrityError on the second app launch.
    """
    existing = db.execute(
        select(PushDevice).where(PushDevice.fcm_token == payload.fcm_token)
    ).scalar_one_or_none()

    if existing is not None:
        existing.user_id = user.id
        existing.device_label = payload.device_label
        existing.is_active = True
        db.commit()
        db.refresh(existing)
        return existing

    device = PushDevice(
        user_id=user.id,
        fcm_token=payload.fcm_token,
        device_label=payload.device_label,
    )
    db.add(device)
    db.commit()
    db.refresh(device)
    return device


def unregister_push_device(db: Session, device_id: int, user: User) -> None:
    device = db.get(PushDevice, device_id)
    if device is None:
        raise NotFoundError("الجهاز غير موجود")
    if device.user_id != user.id:
        raise PermissionDeniedError("ليس لديك صلاحية لإزالة هذا الجهاز")

    db.delete(device)
    db.commit()
def send_test_notification(db: Session, user: User) -> Notification:
    """
    Sends a one-off test notification (in-app + push to every active
    device) to `user`, for manually verifying push delivery — see the
    docstring on the /notifications/test route for how to use this.
    """
    return notify_user(
        db,
        user_id=user.id,
        notification_type=NotificationType.SYSTEM,
        title="إشعار تجريبي",
        message="إذا ظهر لك هذا الإشعار على هاتفك فالإشعارات تعمل بشكل صحيح \U0001F389",
    )