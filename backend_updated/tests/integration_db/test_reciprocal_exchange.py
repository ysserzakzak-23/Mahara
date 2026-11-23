"""
A two-way exchange is TWO requests, and accepting settles both of them.

    User A: offers electronics, wants barbering
    User B: offers barbering,   wants electronics

B sends a proposal on A's request; A accepts. From that moment neither
service is on offer any more, so both requests leave OPEN — otherwise B's
own request keeps advertising a service already promised to A.

Why these run against real PostgreSQL: the two rows are settled under
`SELECT ... FOR UPDATE`, taken lowest id first. SQLite has no row locks at
all and would let two acceptances through, so only here can the locking be
shown to do anything. Without TEST_DATABASE_URL every test in this
directory is skipped (see conftest).
"""
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import pytest
from sqlalchemy import text

from app.core.exceptions import ValidationError
from app.models import Service, User
from app.models.notification import Notification
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)
from app.services import exchange_service

from .helpers import make_category, make_service, make_user, new_session

STATUS_SQL = text("SELECT status FROM exchange_requests WHERE id = :rid")


def _request(session, user, service, wanted_category) -> ExchangeRequest:
    """An open request: "I offer this service, I want that category"."""
    request = ExchangeRequest(
        user_id=user.id,
        offered_service_id=service.id,
        offered_category_id=service.category_id,
        wanted_category_id=wanted_category.id,
        status=ExchangeRequestStatus.OPEN,
    )
    session.add(request)
    session.commit()
    return request


def _propose(session, request, proposer, service) -> ExchangeProposal:
    proposal = ExchangeProposal(
        request_id=request.id,
        proposer_id=proposer.id,
        proposed_service_id=service.id,
    )
    session.add(proposal)
    session.commit()
    return proposal


@dataclass
class TwoWay:
    session: object
    a: User                 # publishes the request that gets the proposal
    b: User                 # sends the proposal
    service_a: Service
    service_b: Service
    category_a: object
    category_b: object
    request_a: ExchangeRequest
    request_b: ExchangeRequest   # B's own request, the mirror image
    proposal: ExchangeProposal


@pytest.fixture
def two_way(session) -> TwoWay:
    category_a = make_category(session)
    category_b = make_category(session)
    a = make_user(session, is_provider=True)
    b = make_user(session, is_provider=True)
    service_a = make_service(session, a, category_a)
    service_b = make_service(session, b, category_b)

    request_a = _request(session, a, service_a, category_b)
    request_b = _request(session, b, service_b, category_a)
    proposal = _propose(session, request_a, b, service_b)
    return TwoWay(
        session, a, b, service_a, service_b,
        category_a, category_b, request_a, request_b, proposal,
    )


def _accept(engine, two_way, proposal_id=None):
    """Accept as the request's owner, in a session of its own."""
    s = new_session(engine)
    try:
        owner = s.get(User, two_way.a.id)
        return exchange_service.respond_to_proposal(
            s, proposal_id or two_way.proposal.id, owner, accept=True
        )
    finally:
        s.close()


def _status(engine, request_id) -> str:
    with engine.connect() as conn:
        return conn.execute(STATUS_SQL, {"rid": request_id}).scalar()


# ============================================================ both sides close

def test_accepting_matches_both_requests(db_engine, two_way):
    _accept(db_engine, two_way)

    assert _status(db_engine, two_way.request_a.id) == "matched"
    assert _status(db_engine, two_way.request_b.id) == "matched"


def test_the_accepted_proposal_stays_accepted(db_engine, two_way):
    _accept(db_engine, two_way)

    session = new_session(db_engine)
    try:
        assert session.get(ExchangeProposal, two_way.proposal.id).status is (
            ExchangeProposalStatus.ACCEPTED
        )
    finally:
        session.close()


def test_matched_is_not_closed(db_engine, two_way):
    """Two different meanings: closed is «the owner withdrew it»."""
    _accept(db_engine, two_way)

    for request_id in (two_way.request_a.id, two_way.request_b.id):
        assert _status(db_engine, request_id) != "closed"


def test_another_users_identical_request_is_left_open(db_engine, two_way):
    """Same categories, same shape — but not the one that was proposed."""
    session = two_way.session
    c = make_user(session, is_provider=True)
    service_c = make_service(session, c, two_way.category_b)
    bystander = _request(session, c, service_c, two_way.category_a)

    _accept(db_engine, two_way)

    assert _status(db_engine, bystander.id) == "open"


def test_the_senders_other_service_is_left_open(db_engine, two_way):
    """B's second request offers a DIFFERENT service: it was not promised."""
    session = two_way.session
    another_service = make_service(session, two_way.b, two_way.category_b)
    untouched = _request(session, two_way.b, another_service, two_way.category_a)

    _accept(db_engine, two_way)

    assert _status(db_engine, untouched.id) == "open"


def test_the_senders_request_for_a_different_category_is_left_open(db_engine, two_way):
    """Same service, but wanting something this exchange does not give."""
    session = two_way.session
    category_c = make_category(session)
    elsewhere = _request(session, two_way.b, two_way.service_b, category_c)

    _accept(db_engine, two_way)

    assert _status(db_engine, elsewhere.id) == "open"


def test_other_pending_proposals_are_rejected(db_engine, two_way):
    session = two_way.session
    c = make_user(session, is_provider=True)
    service_c = make_service(session, c, two_way.category_b)
    runner_up = _propose(session, two_way.request_a, c, service_c)

    _accept(db_engine, two_way)

    s = new_session(db_engine)
    try:
        assert s.get(ExchangeProposal, runner_up.id).status is (
            ExchangeProposalStatus.REJECTED
        )
    finally:
        s.close()


def test_a_sender_without_a_request_of_their_own_matches_one_side(db_engine, session):
    """Proposing straight from «تصفح»: there is no second request to settle."""
    category_a = make_category(session)
    category_b = make_category(session)
    a = make_user(session, is_provider=True)
    b = make_user(session, is_provider=True)
    request_a = _request(session, a, make_service(session, a, category_a), category_b)
    proposal = _propose(session, request_a, b, make_service(session, b, category_b))

    s = new_session(db_engine)
    try:
        exchange_service.respond_to_proposal(s, proposal.id, s.get(User, a.id), accept=True)
    finally:
        s.close()

    assert _status(db_engine, request_a.id) == "matched"


# ======================================================== the lists afterwards

def test_browse_offers_neither_matched_request(db_engine, two_way):
    session = two_way.session
    before = {r.id for r in exchange_service.list_open_requests(session)}
    assert {two_way.request_a.id, two_way.request_b.id} <= before

    _accept(db_engine, two_way)

    s = new_session(db_engine)
    try:
        after = {r.id for r in exchange_service.list_open_requests(s)}
    finally:
        s.close()
    assert two_way.request_a.id not in after
    assert two_way.request_b.id not in after


def test_browse_keeps_the_open_requests_of_everyone_else(db_engine, two_way):
    session = two_way.session
    c = make_user(session, is_provider=True)
    bystander = _request(
        session, c, make_service(session, c, two_way.category_b), two_way.category_a
    )

    _accept(db_engine, two_way)

    s = new_session(db_engine)
    try:
        assert bystander.id in {r.id for r in exchange_service.list_open_requests(s)}
    finally:
        s.close()


def test_my_interests_offers_neither_matched_request(db_engine, two_way):
    """A third user who could serve either side sees both — until they close."""
    session = two_way.session
    c = make_user(session, is_provider=True)
    make_service(session, c, two_way.category_a)   # can serve B's request
    make_service(session, c, two_way.category_b)   # can serve A's request

    before = {request.id for request, *_rank in exchange_service.list_interests(session, c)}
    assert {two_way.request_a.id, two_way.request_b.id} <= before

    _accept(db_engine, two_way)

    s = new_session(db_engine)
    try:
        after = {
            request.id
            for request, *_rank in exchange_service.list_interests(s, s.get(User, c.id))
        }
    finally:
        s.close()
    assert after == set()


def test_my_requests_still_shows_each_owner_their_matched_request(db_engine, two_way):
    _accept(db_engine, two_way)

    s = new_session(db_engine)
    try:
        for user_id, request_id in (
            (two_way.a.id, two_way.request_a.id),
            (two_way.b.id, two_way.request_b.id),
        ):
            mine = exchange_service.list_my_requests(s, s.get(User, user_id))
            found = [r for r in mine if r.id == request_id]
            assert found, f"user {user_id} lost sight of request {request_id}"
            assert found[0].status is ExchangeRequestStatus.MATCHED
    finally:
        s.close()


# =================================================================== atomicity

def test_a_failed_commit_leaves_neither_side_matched(db_engine, two_way, monkeypatch):
    """Both rows travel in one transaction: all of it, or none of it."""
    s = new_session(db_engine)
    try:
        monkeypatch.setattr(
            s, "commit", lambda: (_ for _ in ()).throw(RuntimeError("boom"))
        )
        with pytest.raises(RuntimeError):
            exchange_service.respond_to_proposal(
                s, two_way.proposal.id, s.get(User, two_way.a.id), accept=True
            )
    finally:
        s.rollback()
        s.close()

    assert _status(db_engine, two_way.request_a.id) == "open"
    assert _status(db_engine, two_way.request_b.id) == "open"
    s = new_session(db_engine)
    try:
        assert s.get(ExchangeProposal, two_way.proposal.id).status is (
            ExchangeProposalStatus.PENDING
        )
    finally:
        s.close()


def _set_status(two_way, status):
    two_way.session.get(ExchangeRequest, two_way.request_b.id).status = status
    two_way.session.commit()


def _notifications_for(engine, user_id) -> int:
    s = new_session(engine)
    try:
        return s.query(Notification).filter(Notification.user_id == user_id).count()
    finally:
        s.close()


def test_a_counterpart_already_matched_refuses_the_acceptance(db_engine, two_way):
    """
    B's own request was settled with somebody else first, so B's proposal
    here is stale: the service it offers is already promised elsewhere.
    This is NOT the «B never published a request» case, and must not be
    treated as one.
    """
    _set_status(two_way, ExchangeRequestStatus.MATCHED)

    with pytest.raises(ValidationError, match="المقابل"):
        _accept(db_engine, two_way)

    assert _status(db_engine, two_way.request_a.id) == "open"
    assert _status(db_engine, two_way.request_b.id) == "matched"   # untouched
    s = new_session(db_engine)
    try:
        assert s.get(ExchangeProposal, two_way.proposal.id).status is (
            ExchangeProposalStatus.PENDING
        )
    finally:
        s.close()


def test_a_counterpart_the_owner_withdrew_refuses_the_acceptance(db_engine, two_way):
    """Closed is unavailable too — and the closed request is not reopened."""
    _set_status(two_way, ExchangeRequestStatus.CLOSED)

    with pytest.raises(ValidationError, match="المقابل"):
        _accept(db_engine, two_way)

    assert _status(db_engine, two_way.request_a.id) == "open"
    assert _status(db_engine, two_way.request_b.id) == "closed"


def test_a_refused_acceptance_notifies_nobody(db_engine, two_way):
    _set_status(two_way, ExchangeRequestStatus.MATCHED)
    before = _notifications_for(db_engine, two_way.b.id)

    with pytest.raises(ValidationError):
        _accept(db_engine, two_way)

    assert _notifications_for(db_engine, two_way.b.id) == before


def test_the_oldest_open_counterpart_is_the_one_settled(db_engine, two_way):
    """
    B offered the same service for the same category twice. The older
    exchange is already settled, so the newer request is the one this
    acceptance takes — and the settled one is left exactly as it is.
    """
    session = two_way.session
    newer = _request(session, two_way.b, two_way.service_b, two_way.category_a)
    _set_status(two_way, ExchangeRequestStatus.MATCHED)   # the older one

    _accept(db_engine, two_way)

    assert _status(db_engine, newer.id) == "matched"
    assert _status(db_engine, two_way.request_a.id) == "matched"
    assert _status(db_engine, two_way.request_b.id) == "matched"   # as it was


def test_a_withdrawn_counterpart_is_passed_over_for_an_open_one(db_engine, two_way):
    session = two_way.session
    newer = _request(session, two_way.b, two_way.service_b, two_way.category_a)
    _set_status(two_way, ExchangeRequestStatus.CLOSED)

    _accept(db_engine, two_way)

    assert _status(db_engine, newer.id) == "matched"
    assert _status(db_engine, two_way.request_b.id) == "closed"    # not reopened


def test_every_counterpart_unavailable_refuses_the_acceptance(db_engine, two_way):
    """One matched, one withdrawn, nothing open left."""
    session = two_way.session
    withdrawn = _request(session, two_way.b, two_way.service_b, two_way.category_a)
    withdrawn.status = ExchangeRequestStatus.CLOSED
    session.commit()
    _set_status(two_way, ExchangeRequestStatus.MATCHED)

    with pytest.raises(ValidationError, match="المقابل"):
        _accept(db_engine, two_way)

    assert _status(db_engine, two_way.request_a.id) == "open"
    assert _status(db_engine, two_way.request_b.id) == "matched"
    assert _status(db_engine, withdrawn.id) == "closed"


def test_a_counterpart_deleted_before_the_lock_refuses_the_acceptance(
    db_engine, two_way, monkeypatch
):
    """
    Found by the lookup, gone by the time the row is locked. The sender did
    have a counterpart, so this is not the «none at all» case: refuse
    instead of settling one side.
    """
    found = exchange_service._reciprocal_requests

    def vanish(db, proposal):
        candidates = found(db, proposal)
        with db_engine.begin() as conn:                 # another transaction
            conn.execute(
                text("DELETE FROM exchange_requests WHERE id = :rid"),
                {"rid": two_way.request_b.id},
            )
        return candidates

    monkeypatch.setattr(exchange_service, "_reciprocal_requests", vanish)

    with pytest.raises(ValidationError, match="المقابل"):
        _accept(db_engine, two_way)

    assert _status(db_engine, two_way.request_a.id) == "open"
    s = new_session(db_engine)
    try:
        assert s.get(ExchangeProposal, two_way.proposal.id).status is (
            ExchangeProposalStatus.PENDING
        )
    finally:
        s.close()


# ================================================================= concurrency

def _race(engine, attempts):
    """Runs `attempts` (callables taking a session) at the same instant."""
    barrier = threading.Barrier(len(attempts), timeout=20)
    original = exchange_service.get_proposal_by_id
    once = threading.local()

    def read_then_wait(db, proposal_id):
        proposal = original(db, proposal_id)
        if not getattr(once, "waited", False):
            once.waited = True
            barrier.wait()
        return proposal

    exchange_service.get_proposal_by_id = read_then_wait
    try:
        def run(attempt):
            s = new_session(engine)
            try:
                return ("ok", attempt(s))
            except Exception as exc:  # noqa: BLE001 - inspected by the tests
                s.rollback()
                return ("error", exc)
            finally:
                s.close()

        with ThreadPoolExecutor(max_workers=len(attempts)) as pool:
            return list(pool.map(run, attempts))
    finally:
        exchange_service.get_proposal_by_id = original


def _acceptance(proposal_id: int, owner_id: int):
    """One thread's attempt, over plain ids — it shares nothing with the others."""
    def attempt(session):
        return exchange_service.respond_to_proposal(
            session, proposal_id, session.get(User, owner_id), accept=True
        ).id
    return attempt


def test_one_counterpart_cannot_be_promised_to_two_requests(db_engine, session):
    """
    B has ONE request, and proposed with that same service on the requests of
    both A and C. Both owners accept at the same instant: only one exchange
    can be settled, because both acceptances need B's row.
    """
    category_a = make_category(session)
    category_b = make_category(session)
    a = make_user(session, is_provider=True)
    c = make_user(session, is_provider=True)
    b = make_user(session, is_provider=True)
    service_b = make_service(session, b, category_b)

    request_a = _request(session, a, make_service(session, a, category_a), category_b)
    request_c = _request(session, c, make_service(session, c, category_a), category_b)
    request_b = _request(session, b, service_b, category_a)
    to_a = _propose(session, request_a, b, service_b)
    to_c = _propose(session, request_c, b, service_b)

    # Every id is read HERE, on the fixture's session. Reading one inside a
    # thread would make two threads refresh the same expired instance on
    # that one session at once, which SQLAlchemy refuses — and the race
    # would fail for a reason that has nothing to do with the lock.
    results = _race(
        db_engine,
        [_acceptance(to_a.id, a.id), _acceptance(to_c.id, c.id)],
    )

    winners = [r for r in results if r[0] == "ok"]
    losers = [r for r in results if r[0] == "error"]
    assert len(winners) == 1, results
    assert isinstance(losers[0][1], ValidationError), losers[0][1]

    assert _status(db_engine, request_b.id) == "matched"   # settled exactly once
    settled = [
        rid for rid in (request_a.id, request_c.id)
        if _status(db_engine, rid) == "matched"
    ]
    assert len(settled) == 1, settled


def test_two_proposals_on_one_request_settle_only_one_counterpart(db_engine, session):
    """
    Two senders, each with a request of their own, propose on the same
    request. The owner accepts both at once: one wins, and the loser's own
    request is left open — not half-matched.
    """
    category_a = make_category(session)
    category_b = make_category(session)
    a = make_user(session, is_provider=True)
    request_a = _request(session, a, make_service(session, a, category_a), category_b)

    senders = []
    for _ in range(2):
        sender = make_user(session, is_provider=True)
        service = make_service(session, sender, category_b)
        own = _request(session, sender, service, category_a)
        senders.append((sender, own, _propose(session, request_a, sender, service)))

    owner_id = a.id
    results = _race(
        db_engine,
        [_acceptance(proposal.id, owner_id) for _sender, _own, proposal in senders],
    )

    assert len([r for r in results if r[0] == "ok"]) == 1, results
    assert _status(db_engine, request_a.id) == "matched"
    own_statuses = sorted(_status(db_engine, own.id) for _s, own, _p in senders)
    assert own_statuses == ["matched", "open"], own_statuses
