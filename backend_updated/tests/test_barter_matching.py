from app.algorithms.barter_matching import (
    MatchResult,
    PreferenceEdge,
    find_cyclic_matches,
    find_direct_matches,
)


def edge(pref_id, user_id, offered, needed):
    return PreferenceEdge(
        preference_id=pref_id,
        user_id=user_id,
        offered_category_id=offered,
        needed_category_id=needed,
    )


# --------------------------------------------------------------- direct matches

def test_simple_direct_match():
    a = edge(1, 10, offered=1, needed=2)
    b = edge(2, 20, offered=2, needed=1)
    matches = find_direct_matches([a, b])

    assert len(matches) == 1
    assert matches[0].is_direct
    assert matches[0].length == 2
    assert matches[0].user_ids == (10, 20)


def test_no_match_when_only_one_side_is_satisfied():
    a = edge(1, 10, offered=1, needed=2)
    b = edge(2, 20, offered=2, needed=3)  # B offers what A needs, but A doesn't offer what B needs
    assert find_direct_matches([a, b]) == []


def test_user_cannot_match_with_themselves():
    a = edge(1, 10, offered=1, needed=2)
    b = edge(2, 10, offered=2, needed=1)
    assert find_direct_matches([a, b]) == []


def test_each_pair_is_reported_once():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 1)
    assert len(find_direct_matches([a, b])) == 1
    assert len(find_direct_matches([b, a])) == 1


def test_one_edge_can_match_several_partners():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 1)
    c = edge(3, 30, 2, 1)
    matches = find_direct_matches([a, b, c])
    assert {m.user_ids for m in matches} == {(10, 20), (10, 30)}


def test_empty_input():
    assert find_direct_matches([]) == []
    assert find_cyclic_matches([]) == []


# ---------------------------------------------------------------- cyclic matches

def three_cycle(ids=(1, 2, 3)):
    # A offers 1 needs 2 -> B offers 2 needs 3 -> C offers 3 needs 1 -> back to A
    return [
        edge(ids[0], 10, offered=1, needed=2),
        edge(ids[1], 20, offered=2, needed=3),
        edge(ids[2], 30, offered=3, needed=1),
    ]


def test_finds_a_three_party_cycle():
    matches = find_cyclic_matches(three_cycle())
    assert len(matches) == 1
    assert matches[0].length == 3
    assert not matches[0].is_direct
    assert set(matches[0].user_ids) == {10, 20, 30}


def test_cycle_is_reported_once_regardless_of_edge_order_or_ids():
    edges = three_cycle(ids=(7, 3, 5))
    assert len(find_cyclic_matches(edges)) == 1
    assert len(find_cyclic_matches(list(reversed(edges)))) == 1


def test_cycle_starts_from_the_smallest_preference_id():
    edges = three_cycle(ids=(7, 3, 5))
    match = find_cyclic_matches(edges)[0]
    assert match.edges[0].preference_id == 3


def test_direct_matches_are_not_reported_as_cycles():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 1)
    assert find_cyclic_matches([a, b]) == []


def test_broken_chain_gives_no_cycle():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 3)
    c = edge(3, 30, 3, 4)  # nobody offers category 4
    assert find_cyclic_matches([a, b, c]) == []


def test_same_user_cannot_fill_two_seats_in_a_cycle():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 3)
    c = edge(3, 10, 3, 1)  # same user as A
    assert find_cyclic_matches([a, b, c]) == []


def test_four_cycle_needs_max_length_four():
    edges = [
        edge(1, 10, 1, 2),
        edge(2, 20, 2, 3),
        edge(3, 30, 3, 4),
        edge(4, 40, 4, 1),
    ]
    assert find_cyclic_matches(edges, max_length=3) == []
    four = find_cyclic_matches(edges, max_length=4)
    assert len(four) == 1 and four[0].length == 4


def test_match_result_helpers():
    a = edge(1, 10, 1, 2)
    b = edge(2, 20, 2, 1)
    result = MatchResult(edges=(a, b))
    assert result.is_direct and result.length == 2 and result.user_ids == (10, 20)
