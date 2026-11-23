"""
Race condition: the owner of an exchange request accepts two proposals at
the same moment (two tabs, a double tap, two devices).

Both requests read their own proposal as PENDING BEFORE either of them
writes. A threading.Barrier placed right after that read makes the race
deterministic instead of "hoping" the threads interleave. Only the row lock
taken on the request can save us here — which is why this test is worth
running against real PostgreSQL: SQLite has no row locks and would let both
through.
"""
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import text

from app.core.exceptions import ValidationError
from app.models.exchange import (
    ExchangeProposal,
    ExchangeProposalStatus,
    ExchangeRequest,
    ExchangeRequestStatus,
)
from app.models import User
from app.services import exchange_service

from .helpers import make_category, make_service, make_user, new_session

ACCEPTED_COUNT_SQL = text(
    "SELECT count(*) FROM exchange_proposals "
    "WHERE request_id = :rid AND status = 'accepted'"
)
REQUEST_STATUS_SQL = text("SELECT status FROM exchange_requests WHERE id = :rid")


@pytest.fixture
def contested(world):
    """
    The provider's request is open, and two OTHER providers have each sent a
    pending proposal on it — each offering a service they actually own, so
    the rows are the shape create_proposal would have written.
    """
    session = world.session
    request = ExchangeRequest(
        user_id=world.provider.id,
        offered_service_id=world.service.id,
        offered_category_id=world.service.category_id,
        wanted_category_id=world.service.category_id,
        status=ExchangeRequestStatus.OPEN,
    )
    session.add(request)
    session.commit()

    # world only gives one service to other_provider, so the second bidder
    # gets a listing of their own here.
    second_bidder = make_user(session, is_provider=True)
    second_service = make_service(session, second_bidder, make_category(session))

    first = ExchangeProposal(
        request_id=request.id,
        proposer_id=world.other_provider.id,
        proposed_service_id=world.other_service.id,
    )
    second = ExchangeProposal(
        request_id=request.id,
        proposer_id=second_bidder.id,
        proposed_service_id=second_service.id,
    )
    session.add_all([first, second])
    session.commit()
    return request, first, second


def _run_race(engine, monkeypatch, world, request_id, proposal_ids):
    barrier = threading.Barrier(2, timeout=20)
    original = exchange_service.get_proposal_by_id
    # respond_to_proposal calls get_proposal_by_id a SECOND time at the end,
    # to return the proposal with its relations loaded. Only the first call
    # of each thread is the one we want to line up on the barrier — waiting
    # on the second would just time out the winner after it had already
    # committed.
    once = threading.local()

    def read_then_wait(db, proposal_id):
        proposal = original(db, proposal_id)        # both threads see PENDING...
        if not getattr(once, "waited", False):
            once.waited = True
            barrier.wait()                          # ...and only then does either lock
        return proposal

    monkeypatch.setattr(exchange_service, "get_proposal_by_id", read_then_wait)

    def attempt(proposal_id: int):
        s = new_session(engine)
        try:
            owner = s.get(User, world.provider.id)
            accepted = exchange_service.respond_to_proposal(
                s, proposal_id, owner, accept=True
            )
            return ("ok", accepted.id)
        except Exception as exc:  # noqa: BLE001 - the type is inspected below
            s.rollback()
            return ("error", exc)
        finally:
            s.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(attempt, proposal_ids))


def test_race_never_accepts_two_proposals(db_engine, monkeypatch, world, contested):
    request, first, second = contested

    results = _run_race(db_engine, monkeypatch, world, request.id, [first.id, second.id])

    winners = [r for r in results if r[0] == "ok"]
    losers = [r for r in results if r[0] == "error"]
    assert len(winners) == 1, results
    assert len(losers) == 1, results
    assert isinstance(losers[0][1], ValidationError), losers[0][1]

    with db_engine.connect() as conn:
        assert conn.execute(ACCEPTED_COUNT_SQL, {"rid": request.id}).scalar() == 1
        assert conn.execute(REQUEST_STATUS_SQL, {"rid": request.id}).scalar() == "matched"


def test_race_leaves_no_half_finished_state(db_engine, monkeypatch, world, contested):
    """The loser writes nothing: no second acceptance, no second request update."""
    request, first, second = contested

    _run_race(db_engine, monkeypatch, world, request.id, [first.id, second.id])

    session = new_session(db_engine)
    try:
        proposals = (
            session.query(ExchangeProposal)
            .filter(ExchangeProposal.request_id == request.id)
            .order_by(ExchangeProposal.id)
            .all()
        )
        statuses = sorted(p.status for p in proposals)
        assert statuses == sorted(
            [ExchangeProposalStatus.ACCEPTED, ExchangeProposalStatus.REJECTED]
        ), statuses
        assert session.get(ExchangeRequest, request.id).status is ExchangeRequestStatus.MATCHED
    finally:
        session.close()


def test_sequential_second_acceptance_is_refused(db_engine, world, contested):
    """The same guard without a race: the request is no longer open."""
    request, first, second = contested
    session = new_session(db_engine)
    try:
        owner = session.get(User, world.provider.id)
        exchange_service.respond_to_proposal(session, first.id, owner, accept=True)

        with pytest.raises(ValidationError):
            exchange_service.respond_to_proposal(session, second.id, owner, accept=True)
    finally:
        session.rollback()
        session.close()

    with db_engine.connect() as conn:
        assert conn.execute(ACCEPTED_COUNT_SQL, {"rid": request.id}).scalar() == 1
        assert conn.execute(REQUEST_STATUS_SQL, {"rid": request.id}).scalar() == "matched"


def test_a_matched_request_takes_no_new_proposal(db_engine, world, contested):
    from app.schemas.exchange import ExchangeProposalCreateRequest

    request, first, _second = contested
    session = new_session(db_engine)
    try:
        owner = session.get(User, world.provider.id)
        exchange_service.respond_to_proposal(session, first.id, owner, accept=True)

        newcomer = session.get(User, world.other_customer.id)
        with pytest.raises(ValidationError):
            exchange_service.create_proposal(
                session,
                request.id,
                newcomer,
                ExchangeProposalCreateRequest(proposed_service_id=world.service.id),
            )
    finally:
        session.rollback()
        session.close()

    with db_engine.connect() as conn:
        assert conn.execute(
            text("SELECT count(*) FROM exchange_proposals WHERE request_id = :rid"),
            {"rid": request.id},
        ).scalar() == 2
