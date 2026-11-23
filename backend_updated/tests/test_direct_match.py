from app.algorithms.direct_match import RequestEdge, find_direct_matches


def req(id, user, offered_cat, wanted_cat, service):
    return RequestEdge(
        id=id,
        user_id=user,
        offered_category_id=offered_cat,
        wanted_category_id=wanted_cat,
        offered_service_id=service,
    )


def test_match_has_the_documented_shape():
    a = req(1, 10, offered_cat=1, wanted_cat=2, service=100)
    b = req(2, 20, offered_cat=2, wanted_cat=1, service=200)

    assert find_direct_matches([a, b]) == [
        {
            "match_type": "direct",
            "user_a": 10,
            "user_b": 20,
            "request_a_id": 1,
            "request_b_id": 2,
            "service_a_id": 100,
            "service_b_id": 200,
        }
    ]


def test_user_a_is_the_request_that_comes_first_in_the_input():
    a = req(1, 10, 1, 2, 100)
    b = req(2, 20, 2, 1, 200)
    assert find_direct_matches([b, a])[0]["user_a"] == 20


def test_no_reverse_counterpart_means_no_match():
    a = req(1, 10, 1, 2, 100)
    b = req(2, 20, 1, 2, 200)  # same direction, not the reverse
    assert find_direct_matches([a, b]) == []


def test_same_user_is_skipped():
    a = req(1, 10, 1, 2, 100)
    b = req(2, 10, 2, 1, 200)
    assert find_direct_matches([a, b]) == []


def test_each_unordered_pair_appears_once():
    a = req(1, 10, 1, 2, 100)
    b = req(2, 20, 2, 1, 200)
    assert len(find_direct_matches([a, b])) == 1


def test_one_request_matches_every_valid_counterpart():
    a = req(1, 10, 1, 2, 100)
    b = req(2, 20, 2, 1, 200)
    c = req(3, 30, 2, 1, 300)
    matches = find_direct_matches([a, b, c])
    assert {(m["request_a_id"], m["request_b_id"]) for m in matches} == {(1, 2), (1, 3)}


def test_empty_input():
    assert find_direct_matches([]) == []


def test_scales_to_many_requests():
    # 500 users offering 1/wanting 2 and 500 offering 2/wanting 1 -> 250,000 pairs
    left = [req(i, i, 1, 2, i) for i in range(1, 501)]
    right = [req(1000 + i, 1000 + i, 2, 1, 1000 + i) for i in range(1, 501)]
    assert len(find_direct_matches(left + right)) == 500 * 500
