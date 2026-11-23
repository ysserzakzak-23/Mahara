from types import SimpleNamespace

import pytest
from pydantic import ValidationError as PydanticValidationError

from app.algorithms.barter_matching import MatchResult, PreferenceEdge
from app.core.exceptions import ConflictError, NotFoundError, PermissionDeniedError
from app.models.barter import BarterMatch, BarterMatchType, BarterParticipant, BarterPreference
from app.models.notification import NotificationType
from app.schemas.barter import BarterPreferenceCreateRequest
from app.services import barter_matching_service as matching
from app.services import barter_preference_service as prefs
from tests.helpers import make_result, where_clause

USER = SimpleNamespace(id=7)


def edge(pref_id, user_id, offered, needed):
    return PreferenceEdge(pref_id, user_id, offered, needed)


# ============================================================ preference schema

def test_offered_and_needed_categories_must_differ():
    with pytest.raises(PydanticValidationError):
        BarterPreferenceCreateRequest(offered_category_id=1, needed_category_id=1)
    BarterPreferenceCreateRequest(offered_category_id=1, needed_category_id=2)


# ======================================================== barter_preference_service

@pytest.fixture
def pref_env(monkeypatch):
    log = []
    checked = []
    monkeypatch.setattr(prefs, "get_category_by_id", lambda db, cid: checked.append(cid))
    monkeypatch.setattr(
        prefs.barter_matching_service,
        "run_matching_for_new_preference",
        lambda db: log.append("match"),
    )
    return SimpleNamespace(log=log, checked=checked)


def pref_payload():
    return BarterPreferenceCreateRequest(offered_category_id=1, needed_category_id=2)


def test_duplicate_preference_is_a_conflict(db, pref_env):
    db.execute.return_value = make_result(scalar_one_or_none=object())
    with pytest.raises(ConflictError):
        prefs.create_preference(db, USER, pref_payload())
    db.add.assert_not_called()
    assert pref_env.log == []


def test_unknown_category_stops_creation(db, monkeypatch):
    def missing(db, cid):
        raise NotFoundError("Service category not found")

    monkeypatch.setattr(prefs, "get_category_by_id", missing)
    with pytest.raises(NotFoundError):
        prefs.create_preference(db, USER, pref_payload())
    db.add.assert_not_called()


def test_create_preference_saves_then_runs_matching(db, pref_env):
    db.execute.side_effect = [
        make_result(scalar_one_or_none=None),
        make_result(scalar_one="reloaded"),
    ]
    db.commit.side_effect = lambda: pref_env.log.append("commit")

    result = prefs.create_preference(db, USER, pref_payload())

    created = db.add.call_args.args[0]
    assert isinstance(created, BarterPreference)
    assert (created.user_id, created.offered_category_id, created.needed_category_id) == (7, 1, 2)
    assert pref_env.checked == [1, 2]                 # both categories validated
    assert pref_env.log == ["commit", "match"]        # matching only AFTER the save
    assert result == "reloaded"


def test_deactivate_preference(db):
    p = SimpleNamespace(user_id=7, is_active=True)
    db.get.return_value = p
    prefs.deactivate_preference(db, 1, USER)
    assert p.is_active is False


def test_deactivate_missing_preference_is_404(db):
    db.get.return_value = None
    with pytest.raises(NotFoundError):
        prefs.deactivate_preference(db, 1, USER)


def test_cannot_deactivate_someone_elses_preference(db):
    p = SimpleNamespace(user_id=99, is_active=True)
    db.get.return_value = p
    with pytest.raises(PermissionDeniedError):
        prefs.deactivate_preference(db, 1, USER)
    assert p.is_active is True


# ===================================================== barter_matching_service

def test_active_preferences_become_graph_edges(db):
    rows = [SimpleNamespace(id=1, user_id=10, offered_category_id=1, needed_category_id=2)]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: rows))

    assert matching._load_active_preference_edges(db) == [edge(1, 10, 1, 2)]


def _recorded_env(db, candidate_rows, participant_sets):
    results = [make_result(all=candidate_rows)]
    for s in participant_sets:
        results.append(make_result(scalars=SimpleNamespace(all=lambda s=s: list(s))))
    db.execute.side_effect = results


def pair_result():
    return MatchResult(edges=(edge(1, 10, 1, 2), edge(2, 20, 2, 1)))


def test_match_with_identical_participants_is_already_recorded(db):
    _recorded_env(db, [(5,)], [{1, 2}])
    assert matching._match_already_recorded(db, pair_result()) is True


def test_match_sharing_only_some_preferences_is_not_a_duplicate(db):
    _recorded_env(db, [(5,)], [{1, 2, 3}])      # an older 3-way cycle that includes both
    assert matching._match_already_recorded(db, pair_result()) is False


def test_brand_new_match_is_not_recorded(db):
    _recorded_env(db, [], [])
    assert matching._match_already_recorded(db, pair_result()) is False
    assert db.execute.call_count == 1


def test_duplicate_found_among_several_candidate_matches(db):
    _recorded_env(db, [(5,), (6,)], [{1, 9}, {1, 2}])
    assert matching._match_already_recorded(db, pair_result()) is True


# ----------------------------------------------------------------------- run

@pytest.fixture
def run_env(monkeypatch):
    persisted, notified = [], []

    def persist(db, result, match_type):
        match = SimpleNamespace(match_type=match_type, length=result.length)
        persisted.append(match)
        return match

    monkeypatch.setattr(matching, "_persist_match", persist)
    monkeypatch.setattr(matching, "_notify_participants", lambda db, m: notified.append(m))
    monkeypatch.setattr(matching, "_match_already_recorded", lambda db, r: False)

    def with_edges(edges):
        monkeypatch.setattr(matching, "_load_active_preference_edges", lambda db: edges)

    return SimpleNamespace(persisted=persisted, notified=notified, with_edges=with_edges,
                           monkeypatch=monkeypatch)


def test_nothing_to_match(db, run_env):
    run_env.with_edges([edge(1, 10, 1, 2)])
    assert matching.run_matching(db) == []
    assert run_env.persisted == []


def test_direct_pair_is_persisted_and_participants_notified(db, run_env):
    run_env.with_edges([edge(1, 10, 1, 2), edge(2, 20, 2, 1)])

    created = matching.run_matching(db)

    assert [m.match_type for m in created] == [BarterMatchType.DIRECT]
    assert run_env.notified == created


def test_three_way_cycle_is_persisted_as_cyclic(db, run_env):
    run_env.with_edges([edge(1, 10, 1, 2), edge(2, 20, 2, 3), edge(3, 30, 3, 1)])

    created = matching.run_matching(db)

    assert [(m.match_type, m.length) for m in created] == [(BarterMatchType.CYCLIC, 3)]


def test_already_recorded_matches_are_skipped(db, run_env):
    run_env.with_edges([edge(1, 10, 1, 2), edge(2, 20, 2, 1)])
    run_env.monkeypatch.setattr(matching, "_match_already_recorded", lambda db, r: True)

    assert matching.run_matching(db) == []
    assert run_env.notified == []


def test_entry_point_for_new_preferences_runs_the_full_pass(db, run_env):
    run_env.with_edges([edge(1, 10, 1, 2), edge(2, 20, 2, 1)])
    assert len(matching.run_matching_for_new_preference(db)) == 1


def test_cycles_longer_than_the_cap_are_ignored(db, run_env):
    assert matching.MAX_CYCLE_LENGTH == 3
    run_env.with_edges([
        edge(1, 10, 1, 2), edge(2, 20, 2, 3), edge(3, 30, 3, 4), edge(4, 40, 4, 1),
    ])
    assert matching.run_matching(db) == []


# ------------------------------------------------------------------- persist

def test_persist_creates_match_and_ordered_participants(db):
    result = MatchResult(edges=(edge(1, 10, 1, 2), edge(2, 20, 2, 3), edge(3, 30, 3, 1)))

    matching._persist_match(db, result, BarterMatchType.CYCLIC)

    added = [call.args[0] for call in db.add.call_args_list]
    assert isinstance(added[0], BarterMatch)
    assert (added[0].match_type, added[0].cycle_length) == (BarterMatchType.CYCLIC, 3)
    participants = added[1:]
    assert all(isinstance(p, BarterParticipant) for p in participants)
    assert [(p.sequence_order, p.user_id, p.preference_id) for p in participants] == [
        (0, 10, 1), (1, 20, 2), (2, 30, 3),
    ]
    db.flush.assert_called_once()
    db.commit.assert_called_once()


# -------------------------------------------------------------------- notify

@pytest.mark.parametrize(
    "match_type, length, expected",
    [
        (BarterMatchType.DIRECT, 2, "مطابقة مقايضة مباشرة"),
        (BarterMatchType.CYCLIC, 3, "دورة مقايضة بين 3 أطراف"),
    ],
)
def test_every_participant_is_notified(db, notifications, match_type, length, expected):
    participants = [SimpleNamespace(user_id=10), SimpleNamespace(user_id=20)]
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: participants))
    match = SimpleNamespace(id=5, match_type=match_type, cycle_length=length)

    matching._notify_participants(db, match)

    assert [n["user_id"] for n in notifications] == [10, 20]
    assert all(n["notification_type"] == NotificationType.BARTER_MATCH for n in notifications)
    assert all(n["related_entity_id"] == 5 for n in notifications)
    assert all(expected in n["message"] for n in notifications)


# ============================ recorded matches: reading and marking viewed
#
# GET /barter-matches/me and POST /barter-matches/{id}/view used to run
# their query, ownership check, mutation and commit inside the router
# (Phase 6, Group D). They now live here, so they are covered here too —
# against the same mocked session the rest of this module uses, with no
# live database.

def participation(user_id, *, order=0, viewed=False):
    return SimpleNamespace(
        user_id=user_id,
        sequence_order=order,
        is_viewed=viewed,
        user=SimpleNamespace(id=user_id),
        preference=SimpleNamespace(offered_category=object(), needed_category=object()),
    )


def recorded_match(*participants, match_id=9):
    return SimpleNamespace(
        id=match_id,
        match_type=BarterMatchType.DIRECT,
        cycle_length=len(participants),
        participants=list(participants),
    )


def test_my_matches_are_scoped_to_me_and_newest_first(db):
    mine = recorded_match(participation(USER.id), participation(2, order=1))
    db.execute.return_value = make_result(
        scalars=SimpleNamespace(unique=lambda: SimpleNamespace(all=lambda: [mine]))
    )

    assert matching.list_my_matches(db, USER) == [mine]

    statement = db.execute.call_args.args[0]
    where = where_clause(statement)
    sql = str(statement)
    # Scoped by the participant join, not by the match itself.
    assert "JOIN barter_participants" in sql
    assert "barter_participants.user_id" in where
    assert "ORDER BY barter_matches.created_at DESC" in sql


def test_my_matches_eager_load_each_participants_user_and_preference(db):
    db.execute.return_value = make_result(
        scalars=SimpleNamespace(unique=lambda: SimpleNamespace(all=lambda: []))
    )

    matching.list_my_matches(db, USER)

    paths = {
        " -> ".join(str(part) for part in opt.path)
        for opt in db.execute.call_args.args[0]._with_options
    }
    # The response needs participant.user and participant.preference, each
    # reached through BarterMatch.participants.
    assert any(
        "BarterMatch.participants" in path and "BarterParticipant.user" in path
        for path in paths
    ), paths
    assert any(
        "BarterMatch.participants" in path and "BarterParticipant.preference" in path
        for path in paths
    ), paths


def test_my_matches_collapse_the_rows_the_join_duplicates(db):
    """A three-way match yields three joined rows for one match."""
    unique_called = []
    one = recorded_match(participation(USER.id))

    def scalars():
        def unique():
            unique_called.append(True)
            return SimpleNamespace(all=lambda: [one])

        return SimpleNamespace(unique=unique)

    db.execute.return_value = SimpleNamespace(scalars=scalars)

    assert matching.list_my_matches(db, USER) == [one]
    assert unique_called, "unique() was not applied, so duplicates could leak"


def test_my_matches_neither_write_nor_commit(db):
    db.execute.return_value = make_result(
        scalars=SimpleNamespace(unique=lambda: SimpleNamespace(all=lambda: []))
    )

    matching.list_my_matches(db, USER)

    db.commit.assert_not_called()


def test_marking_viewed_flips_only_my_own_flag_and_commits_once(db):
    me, other = participation(USER.id), participation(2, order=1)
    match = recorded_match(me, other)
    db.execute.return_value = make_result(scalar_one_or_none=match)

    assert matching.mark_match_viewed(db, 9, USER) is match

    assert (me.is_viewed, other.is_viewed) == (True, False)
    db.commit.assert_called_once()
    db.refresh.assert_called_once_with(match)


def test_marking_viewed_looks_the_match_up_by_id(db):
    match = recorded_match(participation(USER.id))
    db.execute.return_value = make_result(scalar_one_or_none=match)

    matching.mark_match_viewed(db, 9, USER)

    assert "barter_matches.id" in where_clause(db.execute.call_args.args[0])


def test_marking_an_already_viewed_match_is_harmless(db):
    me = participation(USER.id, viewed=True)
    match = recorded_match(me)
    db.execute.return_value = make_result(scalar_one_or_none=match)

    matching.mark_match_viewed(db, 9, USER)

    # Unchanged behaviour: the assignment is unconditional and the single
    # commit still happens; SQLAlchemy emits no UPDATE for an unchanged value.
    assert me.is_viewed is True
    db.commit.assert_called_once()


def test_marking_an_unknown_match_is_not_found_and_writes_nothing(db):
    db.execute.return_value = make_result(scalar_one_or_none=None)

    with pytest.raises(NotFoundError) as excinfo:
        matching.mark_match_viewed(db, 9, USER)

    assert excinfo.value.message == "مطابقة المقايضة غير موجودة"
    db.commit.assert_not_called()
    db.refresh.assert_not_called()


def test_marking_someone_elses_match_is_refused_and_writes_nothing(db):
    stranger, other = participation(5), participation(6, order=1)
    match = recorded_match(stranger, other)
    db.execute.return_value = make_result(scalar_one_or_none=match)

    with pytest.raises(PermissionDeniedError) as excinfo:
        matching.mark_match_viewed(db, 9, USER)

    assert excinfo.value.message == "أنت لست طرفاً في مطابقة المقايضة هذه"
    assert [p.is_viewed for p in match.participants] == [False, False]
    db.commit.assert_not_called()
    db.refresh.assert_not_called()


def test_the_refreshed_match_is_what_the_caller_gets_back(db):
    """
    The router serialises the returned instance, so the flow must hand back
    the match itself — refreshed — not a copy or a participant.
    """
    match = recorded_match(participation(USER.id))
    db.execute.return_value = make_result(scalar_one_or_none=match)

    returned = matching.mark_match_viewed(db, 9, USER)

    assert returned is match
    assert returned.participants[0].user.id == USER.id
    assert returned.participants[0].preference.offered_category is not None
