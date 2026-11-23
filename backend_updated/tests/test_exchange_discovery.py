"""
Exchange discovery: «اهتماماتي» (My Interests), the exchange smart search,
offered-service rating sort and the two-way direct matching.

The service layer is exercised with plain objects (no database): the open
request list, the user's own services and the rating query are swapped for
fakes, while the real matching and the real Arabic search engine
(app/utils/arabic_search.py) run unmodified.
"""
from types import SimpleNamespace

import pytest

from app.algorithms.direct_match import RequestEdge, find_direct_matches, is_direct_match
from app.models.exchange import ExchangeRequestStatus
from app.models.service import ServiceStatus
from app.services import exchange_service as svc
from app.utils.arabic_search import labels_equivalent

ME, ALICE, BOB, CAROL, DAN = 1, 2, 3, 4, 5

# id -> (name, is_other)
CATEGORIES = {
    1: ("برمجة", False),
    2: ("تصميم جرافيك", False),
    3: ("كهرباء", False),
    4: ("سباكة", False),
    5: ("تكييف وتبريد", False),
    6: ("نجارة", False),
    99: ("أخرى", True),
}
PROGRAMMING, DESIGN, ELECTRICAL, PLUMBING, AC, CARPENTRY, OTHER = 1, 2, 3, 4, 5, 6, 99


def category(cid):
    name, is_other = CATEGORIES[cid]
    return SimpleNamespace(id=cid, name=name, is_other=is_other)


def xreq(
    id, user_id, offered, wanted, *, title=None, offered_label=None, wanted_label=None,
    description="", status=ExchangeRequestStatus.OPEN,
):
    """An ExchangeRequest-shaped object with the relations the service reads."""
    return SimpleNamespace(
        id=id,
        user_id=user_id,
        status=status,
        offered_category_id=offered,
        wanted_category_id=wanted,
        offered_service_id=id * 100,
        offered_service=SimpleNamespace(
            id=id * 100,
            title=title or CATEGORIES[offered][0],
            description=description,
            custom_category_label=offered_label,
        ),
        offered_category=category(offered),
        wanted_category=category(wanted),
        wanted_custom_category_label=wanted_label,
        proposals=[],
    )


def my_service(category_id, label=None):
    return SimpleNamespace(
        category_id=category_id,
        category=category(category_id),
        custom_category_label=label,
        status=ServiceStatus.ACTIVE,
    )


def ids(results):
    """Request ids from list_interests/search_requests results."""
    return [r[0].id for r in results]


@pytest.fixture
def env(db, monkeypatch):
    """
    Installs fakes for the three data sources:
      env.open      — every OPEN, available request (list_open_requests honours
                      exclude_user_id exactly like the real query);
      env.services  — the current user's own active services;
      env.ratings   — {service_id: (average, count)} for reviewed services.
    """
    state = SimpleNamespace(open=[], services=[], ratings={}, rating_calls=[])

    def fake_open(db, exclude_user_id=None):
        return [
            r for r in state.open
            if r.status == ExchangeRequestStatus.OPEN and r.user_id != exclude_user_id
        ]

    def fake_ratings(db, service_ids):
        state.rating_calls.append(list(service_ids))
        return {sid: state.ratings[sid] for sid in service_ids if sid in state.ratings}

    def fake_offers(db, user):
        offers = []
        for s in state.services:
            key = (s.category_id, (s.custom_category_label or "") if s.category.is_other else None)
            if key not in offers:
                offers.append(key)
        return offers

    monkeypatch.setattr(svc, "list_open_requests", fake_open)
    monkeypatch.setattr(svc, "service_ratings", fake_ratings)
    monkeypatch.setattr(svc, "_my_offers", fake_offers)
    return state


me = SimpleNamespace(id=ME)


# =========================================================== My Interests

def test_interests_are_requests_wanting_a_service_i_offer(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),   # wants programming -> yes
        xreq(11, BOB, PROGRAMMING, PLUMBING),       # OFFERS programming -> no
    ]
    assert ids(svc.list_interests(db, me)) == [10]


def test_interests_cover_every_service_i_offer(db, env):
    # The example from the spec: I offer programming and graphic design.
    env.services = [my_service(PROGRAMMING), my_service(DESIGN)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),
        xreq(11, BOB, DESIGN, PROGRAMMING),
        xreq(12, CAROL, PLUMBING, DESIGN),
    ]
    assert sorted(ids(svc.list_interests(db, me))) == [10, 11, 12]


def test_interests_exclude_requests_for_services_i_do_not_offer(db, env):
    env.services = [my_service(PROGRAMMING), my_service(DESIGN)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),
        xreq(13, DAN, PROGRAMMING, PLUMBING),       # wants plumbing
        xreq(14, DAN, DESIGN, AC),                  # wants AC
    ]
    assert ids(svc.list_interests(db, me)) == [10]


def test_interests_do_not_require_a_two_way_match(db, env):
    env.services = [my_service(PROGRAMMING)]
    # Alice offers carpentry, which I never asked for — still listed.
    env.open = [xreq(10, ALICE, CARPENTRY, PROGRAMMING)]
    assert ids(svc.list_interests(db, me)) == [10]


def test_interests_exclude_my_own_requests(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ME, ELECTRICAL, PROGRAMMING),
        xreq(11, ALICE, ELECTRICAL, PROGRAMMING),
    ]
    assert ids(svc.list_interests(db, me)) == [11]


def test_interests_exclude_closed_and_matched_requests(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING, status=ExchangeRequestStatus.CLOSED),
        xreq(11, BOB, ELECTRICAL, PROGRAMMING, status=ExchangeRequestStatus.MATCHED),
        xreq(12, CAROL, ELECTRICAL, PROGRAMMING),
    ]
    assert ids(svc.list_interests(db, me)) == [12]


def test_interests_list_each_request_once_even_with_several_matching_services(db, env):
    env.services = [my_service(PROGRAMMING), my_service(PROGRAMMING)]
    env.open = [xreq(10, ALICE, ELECTRICAL, PROGRAMMING)]
    assert ids(svc.list_interests(db, me)) == [10]


def test_interests_are_empty_when_i_offer_nothing(db, env):
    env.services = []
    env.open = [xreq(10, ALICE, ELECTRICAL, PROGRAMMING)]
    assert svc.list_interests(db, me) == []


def test_interests_follow_my_services_as_they_change(db, env):
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),
        xreq(11, BOB, ELECTRICAL, DESIGN),
    ]
    env.services = [my_service(PROGRAMMING)]
    assert ids(svc.list_interests(db, me)) == [10]
    env.services = [my_service(DESIGN)]          # e.g. programming paused, design added
    assert ids(svc.list_interests(db, me)) == [11]


def test_interests_match_other_category_by_its_custom_label(db, env):
    env.services = [my_service(OTHER, label="منسق حفلات")]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, OTHER, wanted_label="منسق الحفلات"),   # same trade
        xreq(11, BOB, ELECTRICAL, OTHER, wanted_label="مدرب سباحة"),        # different
        xreq(12, CAROL, ELECTRICAL, OTHER, wanted_label=None),              # unlabelled
    ]
    assert ids(svc.list_interests(db, me)) == [10]


def test_my_other_service_does_not_match_a_regular_category_request(db, env):
    env.services = [my_service(OTHER, label="برمجة")]
    env.open = [xreq(10, ALICE, ELECTRICAL, PROGRAMMING)]
    assert svc.list_interests(db, me) == []


# --------------------------------------------------------- rating sort

def test_interests_sort_by_offered_service_rating_highest_first(db, env):
    env.services = [my_service(PROGRAMMING)]
    a = xreq(10, ALICE, ELECTRICAL, PROGRAMMING)
    b = xreq(11, BOB, DESIGN, PROGRAMMING)
    c = xreq(12, CAROL, PLUMBING, PROGRAMMING)
    env.open = [c, a, b]
    env.ratings = {1000: (4.9, 3), 1100: (4.5, 8), 1200: (4.2, 20)}

    results = svc.list_interests(db, me)

    assert ids(results) == [10, 11, 12]                       # A -> B -> C
    assert [r[1] for r in results] == [4.9, 4.5, 4.2]
    assert [r[2] for r in results] == [3, 8, 20]
    assert all(r[3] is None for r in results)                 # no search score


def test_unrated_services_come_after_rated_ones(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),   # unrated
        xreq(11, BOB, DESIGN, PROGRAMMING),         # rated low
        xreq(12, CAROL, PLUMBING, PROGRAMMING),     # unrated
    ]
    env.ratings = {1100: (1.0, 1)}

    results = svc.list_interests(db, me)

    assert ids(results)[0] == 11
    assert [r[1] for r in results] == [1.0, None, None]
    assert [r[2] for r in results] == [1, 0, 0]


def test_rating_ties_are_broken_consistently(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING),
        xreq(11, BOB, DESIGN, PROGRAMMING),
        xreq(12, CAROL, PLUMBING, PROGRAMMING),
        xreq(13, DAN, AC, PROGRAMMING),
    ]
    # Same average: more reviews first; same average and count: newer first.
    env.ratings = {1000: (4.0, 2), 1100: (4.0, 9), 1200: (4.0, 2)}

    first = ids(svc.list_interests(db, me))
    env.open.reverse()
    second = ids(svc.list_interests(db, me))

    assert first == second == [11, 12, 10, 13]


def test_ratings_are_looked_up_for_the_offered_services_in_one_call(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [xreq(10, ALICE, ELECTRICAL, PROGRAMMING), xreq(11, BOB, DESIGN, PROGRAMMING)]

    svc.list_interests(db, me)

    assert len(env.rating_calls) == 1
    assert sorted(env.rating_calls[0]) == [1000, 1100]   # offered_service ids


def test_service_ratings_use_one_grouped_review_query(db):
    db.execute.return_value.all.return_value = [(1000, 4.666666, 3), (1100, 5, 1)]

    ratings = svc.service_ratings(db, [1100, 1000, 1000, 1200])

    assert ratings == {1000: (4.67, 3), 1100: (5.0, 1)}       # 1200 has no reviews
    db.execute.assert_called_once()
    sql = str(db.execute.call_args.args[0].compile(compile_kwargs={"literal_binds": True}))
    assert "FROM reviews" in sql
    assert "GROUP BY reviews.service_id" in sql
    assert "IN (1000, 1100, 1200)" in sql


def test_service_ratings_skip_the_query_for_no_services(db):
    assert svc.service_ratings(db, []) == {}
    db.execute.assert_not_called()


# ============================================================ smart search

def test_search_returns_exchange_requests_not_catalog_services(db, env):
    env.open = [xreq(10, ALICE, PROGRAMMING, ELECTRICAL, title="مطوّر تطبيقات موبايل")]

    results = svc.search_requests(db, "برمجة")

    assert ids(results) == [10]
    request, rating, count, score = results[0]
    assert request is env.open[0]                     # the ExchangeRequest itself
    assert hasattr(request, "wanted_category")        # not a Service row
    assert 0 < score <= 1


def test_search_ignores_diacritics_and_letter_variants(db, env):
    env.open = [
        xreq(10, ALICE, PROGRAMMING, ELECTRICAL, title="برمجة مواقع"),
        xreq(11, BOB, PLUMBING, ELECTRICAL, title="سباك"),
    ]
    for query in ("البرمجة", "بَرْمَجَة", "برمجه", "برمـــجة"):
        assert ids(svc.search_requests(db, query)) == [10], query


def test_search_understands_trades_from_everyday_words(db, env):
    env.open = [
        xreq(10, ALICE, AC, PROGRAMMING, title="فني صيانة"),   # category: تكييف وتبريد
        xreq(11, BOB, CARPENTRY, PROGRAMMING, title="نجار"),
    ]
    assert ids(svc.search_requests(db, "تصليح مكيف")) == [10]


def test_search_tolerates_small_spelling_mistakes(db, env):
    env.open = [
        xreq(10, ALICE, PLUMBING, PROGRAMMING, title="سباك محترف"),
        xreq(11, BOB, CARPENTRY, PROGRAMMING, title="نجار"),
    ]
    assert ids(svc.search_requests(db, "سباااك")) == [10]
    assert ids(svc.search_requests(db, "سبّاك")) == [10]


def test_search_also_finds_what_a_request_wants(db, env):
    env.open = [
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING, title="كهربائي"),   # WANTS programming
        xreq(11, BOB, PLUMBING, CARPENTRY, title="سباك"),
    ]
    assert ids(svc.search_requests(db, "برمجة")) == [10]


def test_search_reads_other_custom_labels(db, env):
    env.open = [
        xreq(10, ALICE, OTHER, PROGRAMMING, title="خدمة", offered_label="تنسيق حفلات"),
        xreq(11, BOB, OTHER, PROGRAMMING, title="خدمة", offered_label="تعليم قيادة"),
    ]
    assert ids(svc.search_requests(db, "حفلات")) == [10]


def test_browse_search_covers_every_open_request_of_any_category(db, env):
    env.open = [
        xreq(10, ALICE, PROGRAMMING, ELECTRICAL, title="برمجة مواقع"),
        xreq(11, BOB, DESIGN, PLUMBING, title="برمجة ألعاب"),
        xreq(12, CAROL, PROGRAMMING, AC, title="برمجة", status=ExchangeRequestStatus.CLOSED),
    ]
    assert sorted(ids(svc.search_requests(db, "برمجة"))) == [10, 11]


def test_browse_search_leaves_out_the_callers_own_requests(db, env):
    env.open = [
        xreq(10, ME, PROGRAMMING, ELECTRICAL, title="برمجة"),
        xreq(11, ALICE, PROGRAMMING, ELECTRICAL, title="برمجة"),
    ]
    assert ids(svc.search_requests(db, "برمجة", exclude_user_id=ME)) == [11]


def test_search_with_only_filler_words_returns_nothing(db, env):
    env.open = [xreq(10, ALICE, PROGRAMMING, ELECTRICAL)]
    assert svc.search_requests(db, "في من على") == []


def test_interests_search_never_leaves_my_interests(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        xreq(10, ALICE, PLUMBING, PROGRAMMING, title="سباك"),   # in my interests
        xreq(11, BOB, PLUMBING, DESIGN, title="سباك ممتاز"),    # NOT (wants design)
    ]
    assert ids(svc.list_interests(db, me, "سباك")) == [10]
    assert svc.list_interests(db, me, "نجار") == []


def test_interests_search_orders_by_relevance(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [
        # An electrician who only mentions plumbing in the description.
        xreq(10, ALICE, ELECTRICAL, PROGRAMMING, title="فني", description="وأعمال سباكة"),
        xreq(11, BOB, PLUMBING, PROGRAMMING, title="سباك محترف"),
    ]
    env.ratings = {1000: (5.0, 10)}

    results = svc.list_interests(db, me, "سباك")

    assert ids(results)[0] == 11            # title match beats a better rating
    assert results[0][3] >= results[-1][3]


def test_blank_interests_query_behaves_like_no_query(db, env):
    env.services = [my_service(PROGRAMMING)]
    env.open = [xreq(10, ALICE, ELECTRICAL, PROGRAMMING)]
    assert ids(svc.list_interests(db, me, "   ")) == [10]


# ========================================================= direct matching

def edge(id, user, offered, wanted, offered_label=None, wanted_label=None):
    return RequestEdge(id, user, offered, wanted, id * 100, offered_label, wanted_label)


def test_spec_example_one_programming_for_electrical():
    mine = edge(1, ME, PROGRAMMING, ELECTRICAL)
    theirs = edge(2, ALICE, ELECTRICAL, PROGRAMMING)
    assert is_direct_match(mine, theirs) and is_direct_match(theirs, mine)


def test_spec_example_two_design_for_programming():
    mine = edge(1, ME, DESIGN, PROGRAMMING)
    theirs = edge(2, ALICE, PROGRAMMING, DESIGN)
    assert is_direct_match(mine, theirs)


@pytest.mark.parametrize("theirs", [
    edge(2, ALICE, ELECTRICAL, DESIGN),        # offers what I want, wants something else
    edge(3, ALICE, PLUMBING, PROGRAMMING),     # wants what I offer, offers something else
])
def test_one_sided_matches_are_not_direct_matches(theirs):
    mine = edge(1, ME, PROGRAMMING, ELECTRICAL)
    assert not is_direct_match(mine, theirs)
    assert find_direct_matches([mine, theirs]) == []


def test_other_category_needs_matching_labels_both_ways():
    # I offer «أخرى: تنسيق حفلات» and want electrical.
    mine = edge(1, ME, OTHER, ELECTRICAL, offered_label="تنسيق حفلات")
    good = edge(2, ALICE, ELECTRICAL, OTHER, wanted_label="منسق الحفلات")
    wrong_label = edge(3, BOB, ELECTRICAL, OTHER, wanted_label="تعليم قيادة")
    no_label = edge(4, CAROL, ELECTRICAL, OTHER, wanted_label="")

    assert is_direct_match(mine, good)
    assert not is_direct_match(mine, wrong_label)
    assert not is_direct_match(mine, no_label)
    pairs = {(m["request_a_id"], m["request_b_id"]) for m in find_direct_matches(
        [mine, good, wrong_label, no_label])}
    assert pairs == {(1, 2)}


def test_other_on_both_sides_checks_both_labels():
    mine = edge(1, ME, OTHER, OTHER, offered_label="سباك", wanted_label="نجار")
    swapped = edge(2, ALICE, OTHER, OTHER, offered_label="نجار", wanted_label="سباك")
    half = edge(3, BOB, OTHER, OTHER, offered_label="نجار", wanted_label="دهان")
    assert is_direct_match(mine, swapped)
    assert not is_direct_match(mine, half)


def _direct_env(monkeypatch, target, others):
    monkeypatch.setattr(svc, "get_request_by_id", lambda db, rid: target)
    monkeypatch.setattr(
        svc, "list_open_requests",
        lambda db, exclude_user_id=None: [
            r for r in [target, *others]
            if r.status == ExchangeRequestStatus.OPEN and r.user_id != exclude_user_id
        ],
    )


def test_direct_matches_return_every_valid_two_way_counterpart(db, monkeypatch):
    target = xreq(1, ME, PROGRAMMING, ELECTRICAL)
    others = [
        xreq(5, ALICE, ELECTRICAL, PROGRAMMING),
        xreq(3, BOB, ELECTRICAL, PROGRAMMING),
        xreq(4, CAROL, ELECTRICAL, DESIGN),        # one-sided
        xreq(6, DAN, PLUMBING, PROGRAMMING),       # one-sided
        xreq(7, DAN, ELECTRICAL, PROGRAMMING),
    ]
    _direct_env(monkeypatch, target, others)

    matches = svc.find_matches_for_request(db, 1, requesting_user=SimpleNamespace(id=ME))

    assert [m.id for m in matches] == [3, 5, 7]       # all of them, ordered, once each


def test_direct_matches_exclude_the_request_itself_and_my_other_requests(db, monkeypatch):
    target = xreq(1, ME, PROGRAMMING, ELECTRICAL)
    mine_too = xreq(2, ME, ELECTRICAL, PROGRAMMING)
    partner = xreq(3, ALICE, ELECTRICAL, PROGRAMMING)
    _direct_env(monkeypatch, target, [mine_too, partner])

    assert [m.id for m in svc.find_matches_for_request(db, 1)] == [3]


def test_direct_matches_exclude_closed_and_matched_requests(db, monkeypatch):
    target = xreq(1, ME, PROGRAMMING, ELECTRICAL)
    others = [
        xreq(2, ALICE, ELECTRICAL, PROGRAMMING, status=ExchangeRequestStatus.CLOSED),
        xreq(3, BOB, ELECTRICAL, PROGRAMMING, status=ExchangeRequestStatus.MATCHED),
        xreq(4, CAROL, ELECTRICAL, PROGRAMMING),
    ]
    _direct_env(monkeypatch, target, others)

    assert [m.id for m in svc.find_matches_for_request(db, 1)] == [4]


def test_a_matched_target_has_no_direct_matches(db, monkeypatch):
    target = xreq(1, ME, PROGRAMMING, ELECTRICAL, status=ExchangeRequestStatus.MATCHED)
    _direct_env(monkeypatch, target, [xreq(2, ALICE, ELECTRICAL, PROGRAMMING)])
    assert svc.find_matches_for_request(db, 1) == []


def test_direct_matches_compare_other_labels(db, monkeypatch):
    target = xreq(1, ME, OTHER, ELECTRICAL, offered_label="سباك")
    others = [
        xreq(2, ALICE, ELECTRICAL, OTHER, wanted_label="سباكة"),        # same trade
        xreq(3, BOB, ELECTRICAL, OTHER, wanted_label="نجار"),           # other trade
    ]
    _direct_env(monkeypatch, target, others)

    assert [m.id for m in svc.find_matches_for_request(db, 1)] == [2]


def test_each_of_my_requests_gets_its_own_matches(db, monkeypatch):
    # Multiple services: one request per offered service, each matched on its own.
    first = xreq(1, ME, PROGRAMMING, ELECTRICAL)
    second = xreq(2, ME, DESIGN, PLUMBING)
    for_first = xreq(3, ALICE, ELECTRICAL, PROGRAMMING)
    for_second = xreq(4, BOB, PLUMBING, DESIGN)
    everyone = [second, for_first, for_second]

    _direct_env(monkeypatch, first, everyone)
    assert [m.id for m in svc.find_matches_for_request(db, 1)] == [3]
    _direct_env(monkeypatch, second, [first, for_first, for_second])
    assert [m.id for m in svc.find_matches_for_request(db, 2)] == [4]


# ===================================================== labels_equivalent

@pytest.mark.parametrize("a, b", [
    ("سباك", "سباك"),
    ("مُبَرْمِج", "مبرمج"),
    ("سباك", "تصليح حنفيات"),          # same trade via the knowledge base
    ("تنسيق حفلات", "تنسيق الحفلات"),
    ("برمجة", "برمجه"),                # taa marbuta / haa
])
def test_equivalent_labels(a, b):
    assert labels_equivalent(a, b)
    assert labels_equivalent(b, a)


@pytest.mark.parametrize("a, b", [
    ("سباك", "نجار"),
    ("برمجة", "تصميم"),
    ("تنسيق حفلات", "تعليم قيادة"),
    ("", "سباك"),
    (None, "سباك"),
    ("", ""),
])
def test_different_or_missing_labels(a, b):
    assert not labels_equivalent(a, b)


# ================================================ available-request query

def _sql(db):
    return str(db.execute.call_args.args[0].compile(compile_kwargs={"literal_binds": True}))


def test_open_requests_query_only_keeps_available_requests(db):
    db.execute.return_value.scalars.return_value.all.return_value = []
    svc.list_open_requests(db)
    sql = _sql(db)
    assert "exchange_requests.status = 'open'" in sql
    assert "services.status = 'active'" in sql
    assert "users.is_active IS true" in sql
    assert "ORDER BY exchange_requests.id DESC" in sql


def test_my_offers_read_my_active_services(db):
    db.execute.return_value.scalars.return_value.all.return_value = [
        my_service(PROGRAMMING), my_service(PROGRAMMING), my_service(OTHER, "سباك"),
        my_service(DESIGN, label="stale label on a regular category"),
    ]
    offers = svc._my_offers(db, SimpleNamespace(id=ME))

    assert offers == [(PROGRAMMING, None), (OTHER, "سباك"), (DESIGN, None)]
    sql = _sql(db)
    assert "services.provider_id = 1" in sql
    assert "services.status = 'active'" in sql
