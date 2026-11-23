from types import SimpleNamespace

import pytest

from app.core.exceptions import NotFoundError, PermissionDeniedError
from app.models.notification import Notification, NotificationType, PushDevice
from app.schemas.notification import PushDeviceRegisterRequest
from app.services import notification_service as svc
from tests.helpers import make_result

USER = SimpleNamespace(id=5)
OTHER = SimpleNamespace(id=6)


def devices_result(*devices):
    return make_result(scalars=SimpleNamespace(all=lambda: list(devices)))


def device(token="tok", active=True):
    return SimpleNamespace(fcm_token=token, is_active=active)


@pytest.fixture
def pushes(monkeypatch):
    """Records pushes; the next result of each push is taken from `outcomes`."""
    class Pushes(list):
        pass

    sent, outcomes = Pushes(), []

    def fake_push(token, title, body, data=None):
        sent.append({"token": token, "title": title, "body": body, "data": data})
        return outcomes.pop(0) if outcomes else (True, None)

    monkeypatch.setattr(svc, "send_push_notification", fake_push)
    monkeypatch.setattr(svc, "is_invalid_token_error", lambda err: err == "dead-token")
    sent.outcomes = outcomes
    return sent


# ================================================================== notify_user

def test_notify_user_saves_the_in_app_notification(db, pushes):
    db.execute.return_value = devices_result()
    svc.notify_user(
        db, user_id=5, notification_type=NotificationType.NEW_REVIEW,
        title="T", message="M", related_entity_id=9,
    )

    saved = db.add.call_args.args[0]
    assert isinstance(saved, Notification)
    assert (saved.user_id, saved.type, saved.title, saved.message, saved.related_entity_id) == (
        5, NotificationType.NEW_REVIEW, "T", "M", 9,
    )
    db.commit.assert_called_once()


def test_push_goes_to_every_active_device_with_type_and_entity_id(db, pushes):
    db.execute.return_value = devices_result(device("a"), device("b"))
    svc.notify_user(
        db, 5, NotificationType.APPOINTMENT_BOOKED, "Title", "Body", related_entity_id=42
    )

    assert [p["token"] for p in pushes] == ["a", "b"]
    assert pushes[0]["data"] == {"type": "appointment_booked", "related_entity_id": 42}
    assert (pushes[0]["title"], pushes[0]["body"]) == ("Title", "Body")


def test_push_data_omits_entity_id_when_there_is_none(db, pushes):
    db.execute.return_value = devices_result(device())
    svc.notify_user(db, 5, NotificationType.SYSTEM, "T", "M")
    assert pushes[0]["data"] == {"type": "system"}


def test_dead_token_deactivates_the_device(db, pushes):
    dead = device("dead")
    db.execute.return_value = devices_result(dead)
    pushes.outcomes.append((False, "dead-token"))

    svc.notify_user(db, 5, NotificationType.SYSTEM, "T", "M")

    assert dead.is_active is False
    assert db.commit.call_count == 2          # notification + deactivation


def test_transient_push_failure_keeps_the_device_active(db, pushes):
    flaky = device("flaky")
    db.execute.return_value = devices_result(flaky)
    pushes.outcomes.append((False, "network-timeout"))

    svc.notify_user(db, 5, NotificationType.SYSTEM, "T", "M")

    assert flaky.is_active is True
    assert db.commit.call_count == 1


def test_successful_push_needs_no_extra_commit(db, pushes):
    db.execute.return_value = devices_result(device())
    svc.notify_user(db, 5, NotificationType.SYSTEM, "T", "M")
    assert db.commit.call_count == 1


def test_one_dead_device_does_not_stop_the_others(db, pushes):
    dead, alive = device("dead"), device("alive")
    db.execute.return_value = devices_result(dead, alive)
    pushes.outcomes.extend([(False, "dead-token"), (True, None)])

    svc.notify_user(db, 5, NotificationType.SYSTEM, "T", "M")

    assert [p["token"] for p in pushes] == ["dead", "alive"]
    assert dead.is_active is False and alive.is_active is True


# ============================================================ reading / marking

def test_unread_filter_changes_the_query(db):
    db.execute.return_value = devices_result()

    svc.list_my_notifications(db, USER)
    all_sql = str(db.execute.call_args.args[0])
    svc.list_my_notifications(db, USER, unread_only=True)
    unread_sql = str(db.execute.call_args.args[0])

    assert unread_sql != all_sql and "is_read" in unread_sql


def test_unread_count(db):
    db.execute.return_value = make_result(scalar_one=4)
    assert svc.get_unread_count(db, USER) == 4


def test_mark_read_success(db):
    n = SimpleNamespace(user_id=5, is_read=False)
    db.get.return_value = n
    svc.mark_notification_read(db, 1, USER)
    assert n.is_read is True


def test_mark_read_missing_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.mark_notification_read(db, 1, USER)


def test_cannot_mark_someone_elses_notification(db):
    n = SimpleNamespace(user_id=5, is_read=False)
    db.get.return_value = n
    with pytest.raises(PermissionDeniedError):
        svc.mark_notification_read(db, 1, OTHER)
    assert n.is_read is False


def test_mark_all_read_returns_how_many_changed(db):
    items = [SimpleNamespace(is_read=False) for _ in range(3)]
    db.execute.return_value = devices_result(*items)

    assert svc.mark_all_notifications_read(db, USER) == 3
    assert all(i.is_read for i in items)
    db.commit.assert_called_once()


def test_mark_all_read_with_nothing_unread(db):
    db.execute.return_value = devices_result()
    assert svc.mark_all_notifications_read(db, USER) == 0


# ============================================================== push devices

def register_payload(label=None):
    return PushDeviceRegisterRequest(fcm_token="a-valid-fcm-token", device_label=label)


def test_new_token_creates_a_device(db):
    db.execute.return_value = make_result(scalar_one_or_none=None)
    svc.register_push_device(db, USER, register_payload("Pixel"))

    created = db.add.call_args.args[0]
    assert isinstance(created, PushDevice)
    assert (created.user_id, created.fcm_token, created.device_label) == (5, "a-valid-fcm-token", "Pixel")


def test_known_token_is_reused_and_reactivated_for_the_new_user(db):
    existing = SimpleNamespace(user_id=99, device_label="old", is_active=False)
    db.execute.return_value = make_result(scalar_one_or_none=existing)

    result = svc.register_push_device(db, USER, register_payload("New phone"))

    assert result is existing
    assert (existing.user_id, existing.device_label, existing.is_active) == (5, "New phone", True)
    db.add.assert_not_called()


def test_unregister_device(db):
    d = SimpleNamespace(user_id=5)
    db.get.return_value = d
    svc.unregister_push_device(db, 1, USER)
    db.delete.assert_called_once_with(d)


def test_unregister_missing_device_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        svc.unregister_push_device(db, 1, USER)


def test_cannot_unregister_someone_elses_device(db):
    db.get.return_value = SimpleNamespace(user_id=5)
    with pytest.raises(PermissionDeniedError):
        svc.unregister_push_device(db, 1, OTHER)
    db.delete.assert_not_called()


def test_test_notification_is_a_system_notification_for_the_user(db, monkeypatch):
    captured = {}
    monkeypatch.setattr(svc, "notify_user", lambda db, **kw: captured.update(kw) or "sent")

    assert svc.send_test_notification(db, USER) == "sent"
    assert captured["user_id"] == 5
    assert captured["notification_type"] == NotificationType.SYSTEM
