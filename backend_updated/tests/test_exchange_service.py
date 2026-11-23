from types import SimpleNamespace

import pytest

from app.core.exceptions import NotFoundError, PermissionDeniedError, ValidationError
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)
from app.models.notification import NotificationType
from app.schemas.exchange import ExchangeProposalCreateRequest, ExchangeRequestCreateRequest
from app.services import exchange_service as svc

OWNER, OTHER = 10, 20


OTHER_CATEGORY = 99   # the «أخرى» bucket in these tests


def req(
    id, user_id, offered, wanted, status=ExchangeRequestStatus.OPEN, proposals=(),
    offered_label=None, wanted_label=None,
):
    return SimpleNamespace(
        id=id,
        user_id=user_id,
        offered_category_id=offered,
        wanted_category_id=wanted,
        offered_service_id=id * 100,
        status=status,
        proposals=list(proposals),
        offered_service=SimpleNamespace(
            title="Plumbing", display_title="Plumbing", custom_category_label=offered_label,
        ),
        offered_category=SimpleNamespace(id=offered, is_other=offered == OTHER_CATEGORY),
        wanted_category=SimpleNamespace(id=wanted, is_other=wanted == OTHER_CATEGORY),
        wanted_custom_category_label=wanted_label,
    )


# ================================================================ create_request

@pytest.fixture
def creation_env(monkeypatch):
    service = SimpleNamespace(
        id=1, provider_id=OWNER, category_id=5, display_title="برمجة"
    )
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: service)
    monkeypatch.setattr(svc, "get_category_by_id", lambda db, cid: SimpleNamespace(is_other=False))
    monkeypatch.setattr(svc, "_resolve_custom_category_label", lambda cat, label: "resolved")
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: "reloaded")
    return service


def test_cannot_offer_a_service_you_do_not_own(db, creation_env, notifications):
    payload = ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2)
    with pytest.raises(PermissionDeniedError):
        svc.create_request(db, SimpleNamespace(id=OTHER), payload)
    db.add.assert_not_called()


def test_create_request_stores_offer_and_notifies_matches(
    db, creation_env, notifications, monkeypatch
):
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [
            SimpleNamespace(user_id=20, id=201, offered_service=SimpleNamespace(display_title="حلاقة")),
            SimpleNamespace(user_id=30, id=301, offered_service=SimpleNamespace(display_title="نجارة")),
        ],
    )
    payload = ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2)

    result = svc.create_request(db, SimpleNamespace(id=OWNER), payload)

    created = db.add.call_args.args[0]
    assert isinstance(created, ExchangeRequest)
    assert created.user_id == OWNER
    assert created.offered_service_id == 1
    assert created.offered_category_id == 5           # taken from the service
    assert created.wanted_category_id == 2
    assert created.wanted_custom_category_label == "resolved"
    db.commit.assert_called_once()

    # Both sides of each match hear about it: the owner of the request that
    # was already open, and the person who just published.
    assert [n["user_id"] for n in notifications] == [20, OWNER, 30, OWNER]
    assert all(n["notification_type"] == NotificationType.EXCHANGE_MATCH_FOUND for n in notifications)
    assert result == "reloaded"


def test_create_request_without_matches_sends_no_notifications(
    db, creation_env, notifications, monkeypatch
):
    monkeypatch.setattr(svc, "find_matches_for_request", lambda *a, **k: [])
    payload = ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2)
    svc.create_request(db, SimpleNamespace(id=OWNER), payload)
    assert notifications == []


# ================================================================= close_request

def test_owner_closes_request(db, monkeypatch):
    request = req(1, OWNER, 1, 2)
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: request)

    svc.close_request(db, 1, SimpleNamespace(id=OWNER))

    assert request.status == ExchangeRequestStatus.CLOSED
    db.commit.assert_called_once()


def test_non_owner_cannot_close_request(db, monkeypatch):
    request = req(1, OWNER, 1, 2)
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: request)

    with pytest.raises(PermissionDeniedError):
        svc.close_request(db, 1, SimpleNamespace(id=OTHER))
    assert request.status == ExchangeRequestStatus.OPEN


# ========================================================= find_matches_for_request

def _matching_env(monkeypatch, target, open_requests):
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: target)
    monkeypatch.setattr(svc, "list_open_requests", lambda db, exclude_user_id=None: list(open_requests))


def test_finds_the_counterpart_request(db, monkeypatch):
    target = req(1, OWNER, offered=1, wanted=2)
    partner = req(2, OTHER, offered=2, wanted=1)
    _matching_env(monkeypatch, target, [partner])

    matches = svc.find_matches_for_request(db, 1, requesting_user=SimpleNamespace(id=OWNER))

    assert matches == [partner]
    # The open list is already loaded with its relations: no second query.
    db.execute.assert_not_called()


def test_no_counterpart_means_no_database_query(db, monkeypatch):
    target = req(1, OWNER, offered=1, wanted=2)
    unrelated = req(2, OTHER, offered=3, wanted=4)
    _matching_env(monkeypatch, target, [unrelated])

    assert svc.find_matches_for_request(db, 1) == []
    db.execute.assert_not_called()


def test_a_closed_target_is_not_matched(db, monkeypatch):
    target = req(1, OWNER, 1, 2, status=ExchangeRequestStatus.CLOSED)
    partner = req(2, OTHER, 2, 1)
    _matching_env(monkeypatch, target, [partner])

    assert svc.find_matches_for_request(db, 1) == []


def test_matches_are_only_visible_to_the_requests_owner(db, monkeypatch):
    target = req(1, OWNER, 1, 2)
    _matching_env(monkeypatch, target, [])

    with pytest.raises(PermissionDeniedError):
        svc.find_matches_for_request(db, 1, requesting_user=SimpleNamespace(id=OTHER))


def test_target_already_in_open_list_is_not_duplicated(db, monkeypatch):
    target = req(1, OWNER, 1, 2)
    partner = req(2, OTHER, 2, 1)
    _matching_env(monkeypatch, target, [target, partner])

    assert svc.find_matches_for_request(db, 1) == [partner]


# ================================================================ create_proposal

@pytest.fixture
def proposal_env(monkeypatch):
    request = req(7, OWNER, 1, 2)
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: request)
    monkeypatch.setattr(
        svc, "get_service_by_id",
        lambda db, sid: SimpleNamespace(id=sid, provider_id=OTHER, title="Painting", display_title="Painting"),
    )
    monkeypatch.setattr(svc, "get_proposal_by_id", lambda db, pid: "reloaded")
    return request


def proposal_payload(**kw):
    return ExchangeProposalCreateRequest(proposed_service_id=55, **kw)


def test_proposal_requires_an_open_request(db, proposal_env, notifications):
    proposal_env.status = ExchangeRequestStatus.MATCHED
    with pytest.raises(ValidationError, match="لم يعد مفتوحاً"):
        svc.create_proposal(db, 7, SimpleNamespace(id=OTHER), proposal_payload())


def test_cannot_propose_to_your_own_request(db, proposal_env, notifications):
    with pytest.raises(ValidationError, match="طلبك الخاص"):
        svc.create_proposal(db, 7, SimpleNamespace(id=OWNER), proposal_payload())


def test_can_only_propose_a_service_you_own(db, proposal_env, notifications):
    with pytest.raises(PermissionDeniedError):
        svc.create_proposal(db, 7, SimpleNamespace(id=999), proposal_payload())
    db.add.assert_not_called()


def test_successful_proposal_notifies_the_request_owner(db, proposal_env, notifications):
    result = svc.create_proposal(
        db, 7, SimpleNamespace(id=OTHER), proposal_payload(message="deal?")
    )

    created = db.add.call_args.args[0]
    assert isinstance(created, ExchangeProposal)
    assert (created.request_id, created.proposer_id, created.proposed_service_id) == (7, OTHER, 55)
    assert created.message == "deal?"

    assert notifications[0]["user_id"] == OWNER
    assert notifications[0]["notification_type"] == NotificationType.EXCHANGE_PROPOSAL_RECEIVED
    assert "Painting" in notifications[0]["message"] and "Plumbing" in notifications[0]["message"]
    assert result == "reloaded"


# ============================================================ respond_to_proposal

def proposal(id=1, status=ExchangeProposalStatus.PENDING, request=None):
    return SimpleNamespace(
        id=id, status=status, proposer_id=OTHER,
        request=request or req(7, OWNER, 1, 2),
    )


@pytest.fixture
def respond_env(monkeypatch, db):
    """
    Installs the proposal under test, and makes the fake session answer each
    locked re-read with whatever the request THAT statement names currently
    says (which is what PostgreSQL returns once it has granted the row
    lock). An acceptance locks two rows when the sender has a request of
    their own, so the answer is keyed by id and not shared.

    By default the sender has none: `_reciprocal_requests` is patched to
    an empty list, and the tests that do give them one pass them in, oldest
    first — the order the real lookup returns.
    """
    rows: dict[int, object] = {}

    def answer_the_locked_read():
        statement = db.execute.call_args.args[0]
        request_id = next(iter(statement.compile().params.values()))
        row = rows.get(request_id)
        return None if row is None else row.status

    def install(p, *counterparts):
        monkeypatch.setattr(svc, "get_proposal_by_id", lambda db, pid: p)
        monkeypatch.setattr(
            svc, "_reciprocal_requests", lambda db, proposal: list(counterparts)
        )
        rows.clear()
        rows[p.request.id] = p.request
        for counterpart in counterparts:
            rows[counterpart.id] = counterpart
        db.execute.return_value.scalar_one_or_none.side_effect = answer_the_locked_read
        return p
    return install


def test_only_the_request_owner_can_respond(db, respond_env, notifications):
    p = respond_env(proposal())
    with pytest.raises(PermissionDeniedError):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OTHER), accept=True)
    assert p.status == ExchangeProposalStatus.PENDING


def test_a_proposal_can_only_be_answered_once(db, respond_env, notifications):
    respond_env(proposal(status=ExchangeProposalStatus.ACCEPTED))
    with pytest.raises(ValidationError, match="تم الرد على هذا العرض"):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=False)


def test_accepting_matches_the_request_and_rejects_other_pending_proposals(
    db, respond_env, notifications
):
    other_pending = proposal(id=2)
    other_done = proposal(id=3, status=ExchangeProposalStatus.REJECTED)
    request = req(7, OWNER, 1, 2)
    accepted = proposal(id=1, request=request)
    request.proposals = [accepted, other_pending, other_done]
    respond_env(accepted)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert accepted.status == ExchangeProposalStatus.ACCEPTED
    assert request.status == ExchangeRequestStatus.MATCHED
    assert other_pending.status == ExchangeProposalStatus.REJECTED
    assert other_done.status == ExchangeProposalStatus.REJECTED   # untouched
    assert notifications[0]["user_id"] == OTHER
    assert notifications[0]["notification_type"] == NotificationType.EXCHANGE_PROPOSAL_ACCEPTED


def test_rejecting_keeps_the_request_open(db, respond_env, notifications):
    p = respond_env(proposal())
    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=False)

    assert p.status == ExchangeProposalStatus.REJECTED
    assert p.request.status == ExchangeRequestStatus.OPEN
    assert notifications[0]["notification_type"] == NotificationType.EXCHANGE_PROPOSAL_REJECTED


# ============================== both sides of a two-way match (notifications)
#
# A two-way match is news for two people, and create_request used to tell
# only one of them: the owner of the request that was already open. The
# person who had just published heard nothing until they went looking under
# GET /exchange-requests/{id}/matches.


def _match(id, user_id, offered_title):
    """A matching request as find_matches_for_request returns it."""
    return SimpleNamespace(
        id=id,
        user_id=user_id,
        offered_service=SimpleNamespace(display_title=offered_title),
    )


def test_both_participants_are_notified_about_the_same_match(
    db, creation_env, notifications, monkeypatch
):
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [_match(201, OTHER, "حلاقة")],
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )

    assert len(notifications) == 2
    assert {n["user_id"] for n in notifications} == {OWNER, OTHER}
    assert all(
        n["notification_type"] == NotificationType.EXCHANGE_MATCH_FOUND
        for n in notifications
    )


def test_each_participant_is_told_about_the_other_one(
    db, creation_env, notifications, monkeypatch
):
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [_match(201, OTHER, "حلاقة")],
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )

    by_user = {n["user_id"]: n for n in notifications}

    # The owner of the request that was already open: unchanged wording,
    # pointed at the request that has just appeared.
    assert by_user[OTHER]["message"] == "هناك من يريد ما تعرضه، ويعرض ما تحتاجه."
    assert by_user[OTHER]["title"] == "تم العثور على مطابقة تبادل جديدة"

    # The one who just published: told what the other side offers, and that
    # they want the service just offered. Pointed at the other request.
    assert "حلاقة" in by_user[OWNER]["message"]      # what the other side offers
    assert "برمجة" in by_user[OWNER]["message"]      # what I offered
    assert by_user[OWNER]["related_entity_id"] == 201
    # unchanged: the other side is still pointed at the request just created
    assert by_user[OTHER]["related_entity_id"] == db.add.call_args.args[0].id


def test_nobody_is_notified_about_their_own_request(
    db, creation_env, notifications, monkeypatch
):
    """
    find_matches_for_request never returns the owner's own requests, so the
    two recipients are always different people.
    """
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [_match(201, OTHER, "حلاقة")],
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )

    senders = [n["user_id"] for n in notifications]
    assert senders.count(OWNER) == 1      # once, about the OTHER person's request
    assert senders.count(OTHER) == 1
    assert OWNER != OTHER


def test_one_match_sends_exactly_one_notification_to_each_side(
    db, creation_env, notifications, monkeypatch
):
    """Creating the request once notifies each participant once, not twice."""
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [_match(201, OTHER, "حلاقة")],
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )
    first_round = list(notifications)

    # A later, unrelated creation that matches nothing must not repeat them.
    monkeypatch.setattr(svc, "find_matches_for_request", lambda *a, **k: [])
    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )

    assert notifications == first_round
    assert [n["user_id"] for n in notifications].count(OWNER) == 1
    assert [n["user_id"] for n in notifications].count(OTHER) == 1


def test_two_matches_notify_each_counterpart_and_me_once_per_match(
    db, creation_env, notifications, monkeypatch
):
    monkeypatch.setattr(
        svc,
        "find_matches_for_request",
        lambda db, rid, requesting_user=None: [
            _match(201, OTHER, "حلاقة"),
            _match(301, 30, "نجارة"),
        ],
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=2),
    )

    assert [n["user_id"] for n in notifications] == [OTHER, OWNER, 30, OWNER]
    mine = [n for n in notifications if n["user_id"] == OWNER]
    assert [n["related_entity_id"] for n in mine] == [201, 301]
    assert "حلاقة" in mine[0]["message"] and "نجارة" in mine[1]["message"]


def test_the_real_matcher_finds_the_reciprocal_request_and_tells_both(
    db, creation_env, notifications, monkeypatch
):
    """
    End-to-end at the service level with the REAL two-way matching: I offer
    programming and want barbering; someone already offers barbering and
    wants programming. Both of us must hear about it.
    """
    PROGRAMMING, BARBER = 5, 2
    mine = SimpleNamespace(
        id=900,
        user_id=OWNER,
        status=ExchangeRequestStatus.OPEN,
        offered_category_id=PROGRAMMING,
        wanted_category_id=BARBER,
        offered_service_id=1,
        offered_service=SimpleNamespace(display_title="برمجة", custom_category_label=None),
        offered_category=SimpleNamespace(id=PROGRAMMING, is_other=False),
        wanted_category=SimpleNamespace(id=BARBER, is_other=False),
        wanted_custom_category_label=None,
    )
    theirs = SimpleNamespace(
        id=800,
        user_id=OTHER,
        status=ExchangeRequestStatus.OPEN,
        offered_category_id=BARBER,
        wanted_category_id=PROGRAMMING,
        offered_service_id=2,
        offered_service=SimpleNamespace(display_title="حلاقة", custom_category_label=None),
        offered_category=SimpleNamespace(id=BARBER, is_other=False),
        wanted_category=SimpleNamespace(id=PROGRAMMING, is_other=False),
        wanted_custom_category_label=None,
    )
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: mine)
    monkeypatch.setattr(
        svc, "list_open_requests", lambda db, exclude_user_id=None: [theirs]
    )

    svc.create_request(
        db,
        SimpleNamespace(id=OWNER),
        ExchangeRequestCreateRequest(offered_service_id=1, wanted_category_id=BARBER),
    )

    by_user = {n["user_id"]: n for n in notifications}
    assert set(by_user) == {OWNER, OTHER}
    assert by_user[OWNER]["related_entity_id"] == 800       # their request
    assert "حلاقة" in by_user[OWNER]["message"]
    assert by_user[OTHER]["message"] == "هناك من يريد ما تعرضه، ويعرض ما تحتاجه."


# =============================== accepting closes the request (concurrency)
#
# A request is "spoken for" the moment one proposal is accepted: it moves
# OPEN -> MATCHED, every other pending proposal is rejected, and both the
# proposal guard and a locked re-read of the request stop a second
# acceptance from slipping through.


def _request_with(proposals, status=ExchangeRequestStatus.OPEN):
    request = req(7, OWNER, 1, 2, status=status)
    request.proposals = proposals
    for p in proposals:
        p.request = request
    return request


def test_accepting_moves_the_request_out_of_open(db, respond_env, notifications):
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert request.status == ExchangeRequestStatus.MATCHED
    assert request.status != ExchangeRequestStatus.OPEN
    assert accepted.status == ExchangeProposalStatus.ACCEPTED
    db.commit.assert_called_once()


def test_a_second_acceptance_on_a_matched_request_is_refused(
    db, respond_env, notifications
):
    """The loser of a race: its own row still looks pending to it, but the
    request has already been matched by the winner."""
    loser = proposal(id=2)
    _request_with([loser], status=ExchangeRequestStatus.MATCHED)
    respond_env(loser)

    with pytest.raises(ValidationError, match="لم يعد مفتوحاً"):
        svc.respond_to_proposal(db, 2, SimpleNamespace(id=OWNER), accept=True)

    assert loser.status == ExchangeProposalStatus.PENDING   # nothing half-done
    db.commit.assert_not_called()
    assert notifications == []


def test_the_request_is_locked_before_it_is_read(db, respond_env, notifications):
    """The status re-read must be FOR UPDATE, or two acceptances can race."""
    accepted = proposal(id=1)
    _request_with([accepted])
    respond_env(accepted)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    statement = db.execute.call_args.args[0]
    assert statement._for_update_arg is not None, "the row is not locked"
    assert "exchange_requests" in str(statement)


def test_rejecting_takes_no_lock_and_leaves_the_request_open(
    db, respond_env, notifications
):
    p = proposal(id=1)
    request = _request_with([p])
    respond_env(p)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=False)

    assert p.status == ExchangeProposalStatus.REJECTED
    assert request.status == ExchangeRequestStatus.OPEN
    db.execute.assert_not_called()


def test_a_vanished_request_is_not_accepted(db, respond_env, notifications):
    p = proposal(id=1)
    _request_with([p])
    respond_env(p)
    db.execute.return_value.scalar_one_or_none.side_effect = lambda: None

    with pytest.raises(NotFoundError):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert p.status == ExchangeProposalStatus.PENDING
    db.commit.assert_not_called()


def test_the_other_pending_proposals_can_no_longer_be_accepted(
    db, respond_env, notifications
):
    """After one wins, the others are rejected — and rejected proposals are
    refused by the existing "answered already" guard."""
    winner = proposal(id=1)
    runner_up = proposal(id=2)
    _request_with([winner, runner_up])
    respond_env(winner)
    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)
    assert runner_up.status == ExchangeProposalStatus.REJECTED

    respond_env(runner_up)
    with pytest.raises(ValidationError, match="تم الرد على هذا العرض"):
        svc.respond_to_proposal(db, 2, SimpleNamespace(id=OWNER), accept=True)


def test_a_refused_acceptance_leaves_the_request_untouched(
    db, respond_env, notifications
):
    """A failure must not close the request as a side effect."""
    p = proposal(id=1)
    request = _request_with([p])
    respond_env(p)

    with pytest.raises(PermissionDeniedError):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OTHER), accept=True)

    assert request.status == ExchangeRequestStatus.OPEN
    assert p.status == ExchangeProposalStatus.PENDING
    db.commit.assert_not_called()


# ---------------------------------------------- no new proposals afterwards

def test_a_matched_request_takes_no_new_proposals(db, monkeypatch, notifications):
    request = req(7, OWNER, 1, 2, status=ExchangeRequestStatus.MATCHED)
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: request)

    with pytest.raises(ValidationError, match="لم يعد مفتوحاً"):
        svc.create_proposal(
            db, 7, SimpleNamespace(id=OTHER),
            ExchangeProposalCreateRequest(proposed_service_id=55),
        )

    db.add.assert_not_called()
    assert notifications == []


def test_an_open_request_still_takes_proposals(db, monkeypatch, notifications):
    request = req(7, OWNER, 1, 2)
    service = SimpleNamespace(id=55, provider_id=OTHER, display_title="Painting")
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: request)
    monkeypatch.setattr(svc, "get_service_by_id", lambda db, sid: service)
    monkeypatch.setattr(svc, "get_proposal_by_id", lambda db, pid: "reloaded")

    result = svc.create_proposal(
        db, 7, SimpleNamespace(id=OTHER),
        ExchangeProposalCreateRequest(proposed_service_id=55),
    )

    assert isinstance(db.add.call_args.args[0], ExchangeProposal)
    assert result == "reloaded"
    assert notifications[0]["user_id"] == OWNER


# ================ the sender's own request is settled by the same acceptance
#
# A two-way match is two requests: "I offer electronics, I want barbering"
# and "I offer barbering, I want electronics". Accepting the proposal used
# to settle only the request that received it, leaving the sender's own one
# open — still offered to everyone else, for a service already promised.
#
# The proposal itself records no link to it (it carries the service put up,
# not the request it came from, and it can be sent by someone who published
# no request at all), so the counterpart is recovered through the same
# direct-match relation that paired them: see [_reciprocal_request].


def _counterpart(id=5, user_id=OTHER, offered=2, wanted=1, **kw):
    """The sender's own request, the mirror image of req(7, OWNER, 1, 2)."""
    return req(id, user_id, offered, wanted, **kw)


def _locked_ids(db):
    """The request ids the acceptance locked, in the order it locked them."""
    ids = []
    for call in db.execute.call_args_list:
        statement = call.args[0]
        if getattr(statement, "_for_update_arg", None) is not None:
            ids.append(next(iter(statement.compile().params.values())))
    return ids


def test_accepting_also_matches_the_senders_own_request(db, respond_env, notifications):
    mine = _counterpart()
    accepted = proposal(id=1)
    _request_with([accepted])
    respond_env(accepted, mine)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert accepted.request.status == ExchangeRequestStatus.MATCHED
    assert mine.status == ExchangeRequestStatus.MATCHED
    assert accepted.status == ExchangeProposalStatus.ACCEPTED
    # Both rows are settled by one commit: there is no moment at which only
    # one of them is matched.
    db.commit.assert_called_once()


def test_both_rows_are_locked_lowest_id_first(db, respond_env, notifications):
    """A fixed order is what keeps two acceptances from deadlocking."""
    mine = _counterpart(id=5)
    accepted = proposal(id=1)
    _request_with([accepted])           # the request being answered is id 7
    respond_env(accepted, mine)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert _locked_ids(db) == [5, 7]


def test_the_counterpart_is_locked_before_it_is_matched(db, respond_env, notifications):
    mine = _counterpart(id=9)
    accepted = proposal(id=1)
    _request_with([accepted])
    respond_env(accepted, mine)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert 9 in _locked_ids(db)


def test_a_counterpart_taken_in_the_meantime_refuses_the_whole_acceptance(
    db, respond_env, notifications
):
    """Someone else matched the sender's request while this one decided."""
    mine = _counterpart(status=ExchangeRequestStatus.MATCHED)
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted, mine)

    with pytest.raises(ValidationError, match="المقابل"):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    # Nothing half-done: this side is untouched too.
    assert request.status == ExchangeRequestStatus.OPEN
    assert accepted.status == ExchangeProposalStatus.PENDING
    db.commit.assert_not_called()
    assert notifications == []


def test_a_counterpart_that_vanished_refuses_the_acceptance(
    db, respond_env, notifications
):
    """
    Deleted between the lookup and the lock. The sender did have a
    counterpart to this proposal, so this is not the «no counterpart at
    all» case: the proposal is stale and the acceptance is refused, rather
    than quietly settling one side.
    """
    mine = _counterpart(id=5)
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted, mine)
    # the counterpart's row is gone by the time the lock is granted
    rows_answer = db.execute.return_value.scalar_one_or_none.side_effect
    db.execute.return_value.scalar_one_or_none.side_effect = (
        lambda: None if _locked_ids(db)[-1] == 5 else rows_answer()
    )

    with pytest.raises(ValidationError, match="المقابل"):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert request.status == ExchangeRequestStatus.OPEN
    assert accepted.status == ExchangeProposalStatus.PENDING
    db.commit.assert_not_called()
    assert notifications == []


def test_a_sender_without_a_request_of_their_own_matches_one_side(
    db, respond_env, notifications
):
    """Proposing straight from «تصفح» is not a two-way match."""
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted)                      # no counterpart

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert request.status == ExchangeRequestStatus.MATCHED
    assert _locked_ids(db) == [7]              # one row, one lock
    db.commit.assert_called_once()


def test_rejecting_settles_neither_side(db, respond_env, notifications):
    mine = _counterpart()
    p = proposal(id=1)
    request = _request_with([p])
    respond_env(p, mine)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=False)

    assert request.status == ExchangeRequestStatus.OPEN
    assert mine.status == ExchangeRequestStatus.OPEN
    db.execute.assert_not_called()             # nothing was even looked up


# ------------------------------------------------- which request is the one

def _candidates(db, rows):
    db.execute.return_value.scalars.return_value.all.return_value = list(rows)


def _proposal_from(service_id=500, request=None):
    return SimpleNamespace(
        id=1,
        proposer_id=OTHER,
        proposed_service_id=service_id,
        request=request or req(7, OWNER, 1, 2),
    )


def test_the_counterpart_is_the_one_that_completes_the_exchange(db):
    mine = _counterpart(id=5)                  # offers 2, wants 1
    _candidates(db, [mine])
    assert svc._reciprocal_requests(db, _proposal_from()) == [mine]


def test_a_request_that_is_not_a_two_way_match_is_never_taken(db):
    # Same owner, same service — but it wants a category this request does
    # not offer, so the two do not complete each other.
    _candidates(db, [_counterpart(id=5, offered=2, wanted=3)])
    assert svc._reciprocal_requests(db, _proposal_from()) == []


def test_the_other_label_has_to_agree_too(db):
    """«أخرى» on both sides: the category id alone settles nothing."""
    target = req(7, OWNER, 1, OTHER_CATEGORY, wanted_label="سباكة")
    mismatch = _counterpart(id=5, offered=OTHER_CATEGORY, wanted=1, offered_label="نجارة")
    _candidates(db, [mismatch])
    assert svc._reciprocal_requests(db, _proposal_from(request=target)) == []

    agrees = _counterpart(id=6, offered=OTHER_CATEGORY, wanted=1, offered_label="سباكة")
    _candidates(db, [agrees])
    assert svc._reciprocal_requests(db, _proposal_from(request=target)) == [agrees]


def test_every_interchangeable_duplicate_is_reported_oldest_first(db):
    oldest, newer = _counterpart(id=5), _counterpart(id=8)
    _candidates(db, [oldest, newer])
    assert svc._reciprocal_requests(db, _proposal_from()) == [oldest, newer]


def test_the_lookup_does_not_filter_by_status(db):
    """
    An empty result has to mean «there is no counterpart», nothing else —
    so a matched or closed one is reported too, and whoever asked decides
    what that means once the rows are locked.
    """
    settled = _counterpart(id=5, status=ExchangeRequestStatus.MATCHED)
    withdrawn = _counterpart(id=6, status=ExchangeRequestStatus.CLOSED)
    _candidates(db, [settled, withdrawn])
    assert svc._reciprocal_requests(db, _proposal_from()) == [settled, withdrawn]

    statement = db.execute.call_args.args[0]
    assert "open" not in set(statement.compile().params.values())


def test_the_lookup_asks_only_for_the_senders_own_offers_of_that_service(db):
    _candidates(db, [])
    svc._reciprocal_requests(db, _proposal_from(service_id=500))

    statement = db.execute.call_args.args[0]
    assert set(statement.compile().params.values()) >= {OTHER, 500}
    assert "exchange_requests" in str(statement)
    assert statement._for_update_arg is None   # the lookup takes no lock


def test_the_oldest_open_candidate_is_the_one_settled(db, respond_env, notifications):
    """
    The sender published the same offer twice and the older exchange is
    already settled. The acceptance takes the one still open — not simply
    the oldest — and leaves the settled one exactly as it is.
    """
    settled = _counterpart(id=5, status=ExchangeRequestStatus.MATCHED)
    still_open = _counterpart(id=8)
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted, settled, still_open)

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert still_open.status == ExchangeRequestStatus.MATCHED
    assert settled.status == ExchangeRequestStatus.MATCHED   # untouched
    assert request.status == ExchangeRequestStatus.MATCHED
    db.commit.assert_called_once()


def test_a_withdrawn_candidate_is_passed_over_for_an_open_one(
    db, respond_env, notifications
):
    withdrawn = _counterpart(id=5, status=ExchangeRequestStatus.CLOSED)
    still_open = _counterpart(id=8)
    accepted = proposal(id=1)
    respond_env(accepted, withdrawn, still_open)
    _request_with([accepted])

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert still_open.status == ExchangeRequestStatus.MATCHED
    assert withdrawn.status == ExchangeRequestStatus.CLOSED   # not reopened


def test_candidates_that_are_all_unavailable_refuse_the_acceptance(
    db, respond_env, notifications
):
    """Matched and withdrawn, nothing open left: the proposal is stale."""
    settled = _counterpart(id=5, status=ExchangeRequestStatus.MATCHED)
    withdrawn = _counterpart(id=8, status=ExchangeRequestStatus.CLOSED)
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted, settled, withdrawn)

    with pytest.raises(ValidationError, match="المقابل"):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert request.status == ExchangeRequestStatus.OPEN
    assert accepted.status == ExchangeProposalStatus.PENDING
    assert settled.status == ExchangeRequestStatus.MATCHED
    assert withdrawn.status == ExchangeRequestStatus.CLOSED
    db.commit.assert_not_called()
    assert notifications == []


def test_a_withdrawn_counterpart_on_its_own_refuses_the_acceptance(
    db, respond_env, notifications
):
    withdrawn = _counterpart(id=5, status=ExchangeRequestStatus.CLOSED)
    accepted = proposal(id=1)
    request = _request_with([accepted])
    respond_env(accepted, withdrawn)

    with pytest.raises(ValidationError, match="المقابل"):
        svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert request.status == ExchangeRequestStatus.OPEN
    assert withdrawn.status == ExchangeRequestStatus.CLOSED
    db.commit.assert_not_called()
    assert notifications == []


def test_every_candidate_is_locked_lowest_id_first(db, respond_env, notifications):
    """Including the ones already settled: a fixed order over every row."""
    accepted = proposal(id=1)
    _request_with([accepted])                               # the request is id 7
    respond_env(
        accepted,
        _counterpart(id=9, status=ExchangeRequestStatus.MATCHED),
        _counterpart(id=3, status=ExchangeRequestStatus.CLOSED),
        _counterpart(id=5),
    )

    svc.respond_to_proposal(db, 1, SimpleNamespace(id=OWNER), accept=True)

    assert _locked_ids(db) == [3, 5, 7, 9]
