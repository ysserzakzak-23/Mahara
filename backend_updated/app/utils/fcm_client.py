"""
Firebase Cloud Messaging client wrapper.

Isolates the firebase-admin SDK behind a small, simple function so the
rest of the app never imports `firebase_admin` directly — if push
providers ever change, only this file needs to change.

Honors settings.FCM_ENABLED: when False (the .env.example default), every
call here is a safe no-op that logs instead of sending, so the entire
backend can be developed and demoed without a real Firebase project
configured. Flip FCM_ENABLED=true and point FIREBASE_CREDENTIALS_PATH at
a real service account JSON to enable actual pushes.
"""
import logging
from typing import Optional

from app.core.config import settings

logger = logging.getLogger(__name__)

_firebase_app = None  # lazily initialized, module-level singleton


def _get_firebase_app():
    """
    Lazily initializes and caches the firebase_admin App instance.

    Lazy initialization matters here: importing firebase_admin and
    pointing it at a credentials file happens only on the FIRST actual
    send attempt, not at module import time. This means the app can start
    up and serve every other route fine even if FIREBASE_CREDENTIALS_PATH
    doesn't exist yet, as long as FCM_ENABLED stays False (or no push is
    ever triggered) — useful during initial setup/grading before a real
    Firebase project is wired up.
    """
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app

    import firebase_admin
    from firebase_admin import credentials

    cred = credentials.Certificate(settings.FIREBASE_CREDENTIALS_PATH)
    _firebase_app = firebase_admin.initialize_app(cred)
    return _firebase_app


def send_push_notification(
    fcm_token: str, title: str, body: str, data: Optional[dict] = None
) -> tuple[bool, Optional[Exception]]:
    """
    Sends a single push notification to one device token.

    Returns a (success, error) tuple:
      - (True, None) on success.
      - (False, None) if FCM is disabled (settings.FCM_ENABLED=False).
      - (False, exception) on any send failure, with the original
        exception returned (not raised) so the caller can inspect it —
        e.g. notification_service uses is_invalid_token_error(exc) on it
        to decide whether to deactivate a dead PushDevice.

    Never RAISES — a push failure should never break the request that
    triggered it (e.g. booking an appointment must succeed even if the
    provider's push token has expired).

    `data` is an optional dict of string key-value pairs delivered
    alongside the notification, used by the Flutter app for deep-linking
    (e.g. {"type": "appointment_booked", "appointment_id": "42"}).
    """
    if not settings.FCM_ENABLED:
        logger.info("FCM disabled (settings.FCM_ENABLED=False); skipping push to %s", fcm_token[:12])
        return False, None

    try:
        from firebase_admin import messaging

        _get_firebase_app()

        message = messaging.Message(
            token=fcm_token,
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
        )
        messaging.send(message)
        return True, None
    except Exception as exc:
        # Broad except is deliberate: ANY failure here (bad credentials,
        # expired/invalid token, network issue, FCM outage) must degrade
        # to "push didn't go out" rather than bubble up and fail the
        # request that triggered the notification. The exception is
        # returned (not swallowed) so the caller can still distinguish
        # "token is dead" from "transient failure" via is_invalid_token_error.
        logger.exception("Failed to send FCM push notification")
        return False, exc


def is_invalid_token_error(exc: Exception) -> bool:
    """
    Best-effort check for whether a caught exception indicates the FCM
    token itself is invalid/unregistered (vs. a transient failure).

    Used by notification_service to decide whether to mark a PushDevice
    inactive after a failed send. Conservative by design: returns False
    (i.e. "don't deactivate") unless firebase_admin's specific
    UnregisteredError is detected, since misclassifying a transient
    network error as a dead token would wrongly stop future pushes to a
    perfectly good device.
    """
    try:
        from firebase_admin import messaging
        return isinstance(exc, messaging.UnregisteredError)
    except ImportError:
        return False
