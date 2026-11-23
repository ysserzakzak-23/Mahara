"""
Barter matching algorithms: direct-pair detection and cycle detection.

THE GRAPH MODEL
================
Each active BarterPreference is a directed edge in a graph:

    offered_category_id  --->  needed_category_id

labeled with (user_id, preference_id). A user who "offers Electrical Work,
needs Phone Repair" is an edge from the Electrical-Work node to the
Phone-Repair node.

A DIRECT MATCH is the simplest possible cycle: two preferences where
A's offer satisfies B's need AND B's offer satisfies A's need — i.e. a
cycle of length 2 (A -> B -> A). A CYCLIC MATCH is any longer directed
cycle, e.g. A -> B -> C -> A (length 3): A's offer satisfies B's need,
B's offer satisfies C's need, C's offer satisfies A's need.

This means direct matching is mathematically a special case of cycle
detection. We still implement it as its own simple O(n^2) pairwise
function — both because it's the common case worth optimizing for
directly, and because presenting "the simple case" and "the general
case" as two distinct, separately-understandable algorithms is clearer
than asking a reader to mentally specialize a general graph algorithm
down to n=2.

SCOPE: cycle search is capped at length 3 (product decision) — this
keeps the search bounded and cheap enough to run synchronously every
time a new BarterPreference is created, without needing a background
job queue. The DFS-based search function is written generally (it could
search any max_length), but Phase 9 only ever calls it with max_length=3.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class PreferenceEdge:
    """
    One directed edge in the barter graph: a single active BarterPreference,
    flattened to the plain data the algorithm needs (no ORM/session
    dependency, so this module has zero database coupling).
    """
    preference_id: int
    user_id: int
    offered_category_id: int
    needed_category_id: int


@dataclass(frozen=True)
class MatchResult:
    """
    One detected match: an ordered cycle of preference edges where each
    edge's offered_category satisfies the NEXT edge's needed_category
    (wrapping around). `is_direct` is True iff the cycle has exactly 2
    participants.
    """
    edges: tuple[PreferenceEdge, ...]

    @property
    def is_direct(self) -> bool:
        return len(self.edges) == 2

    @property
    def length(self) -> int:
        return len(self.edges)

    @property
    def user_ids(self) -> tuple[int, ...]:
        return tuple(edge.user_id for edge in self.edges)


def find_direct_matches(edges: list[PreferenceEdge]) -> list[MatchResult]:
    """
    Finds all direct (2-party) matches: pairs of edges A, B (different
    users) where A.offered == B.needed AND A.needed == B.offered.

    O(n^2) pairwise comparison. This is intentionally simple rather than
    routed through the general cycle-search machinery below — for the
    2-party case there's nothing a graph traversal buys you over directly
    checking every pair, and keeping this as its own readable function
    matters for explaining the algorithm clearly.

    Each unordered pair is returned exactly once (A matched with B is the
    same match as B matched with A) — achieved by only considering pairs
    where edges[i] precedes edges[j] in the input list (i < j).
    """
    matches: list[MatchResult] = []

    for i in range(len(edges)):
        for j in range(i + 1, len(edges)):
            edge_a, edge_b = edges[i], edges[j]

            if edge_a.user_id == edge_b.user_id:
                continue  # a user can't barter with themselves

            if (
                edge_a.offered_category_id == edge_b.needed_category_id
                and edge_a.needed_category_id == edge_b.offered_category_id
            ):
                matches.append(MatchResult(edges=(edge_a, edge_b)))

    return matches


def find_cyclic_matches(edges: list[PreferenceEdge], max_length: int = 3) -> list[MatchResult]:
    """
    Finds all directed cycles of length 3 up to `max_length` in the barter
    graph (length-2 cycles are direct matches, handled separately by
    find_direct_matches — this function only returns cycles of length >= 3
    to avoid reporting the same direct matches twice under a different name).

    ALGORITHM: bounded depth-first search. For each edge as a potential
    cycle start, follow chains of edges where the current edge's
    needed_category matches the next edge's offered_category, until
    either the chain closes back to the starting edge's offered_category
    (a cycle found) or max_length is exceeded (abandon this branch).

    This is a small, intentionally-bounded search — NOT a general-purpose
    "find all cycles in a graph" algorithm (e.g. Johnson's algorithm),
    which would be needed if max_length were unbounded. Capping at 3
    (the product requirement) keeps this both simple to explain and cheap
    enough to run synchronously on every new preference.

    Each distinct cycle (as a set of participating users) is returned
    once, regardless of which edge in the cycle the search happened to
    start from — achieved by only keeping cycles whose starting edge has
    the smallest preference_id among all edges in that cycle.
    """
    # Index edges by their offered_category for fast "what can extend this chain" lookups.
    edges_by_offered_category: dict[int, list[PreferenceEdge]] = {}
    for edge in edges:
        edges_by_offered_category.setdefault(edge.offered_category_id, []).append(edge)

    found_cycles: list[MatchResult] = []

    for start_edge in edges:
        _search_from(
            start_edge=start_edge,
            current_edge=start_edge,
            chain=[start_edge],
            visited_user_ids={start_edge.user_id},
            edges_by_offered_category=edges_by_offered_category,
            max_length=max_length,
            found_cycles=found_cycles,
        )

    return found_cycles


def _search_from(
    start_edge: PreferenceEdge,
    current_edge: PreferenceEdge,
    chain: list[PreferenceEdge],
    visited_user_ids: set[int],
    edges_by_offered_category: dict[int, list[PreferenceEdge]],
    max_length: int,
    found_cycles: list[MatchResult],
) -> None:
    """Recursive DFS helper for find_cyclic_matches. Mutates found_cycles in place."""
    if len(chain) >= max_length:
        return  # this branch can't reach a valid cycle within the length cap

    candidates = edges_by_offered_category.get(current_edge.needed_category_id, [])

    for next_edge in candidates:
        if next_edge.user_id in visited_user_ids:
            continue  # would revisit a user already in this chain (or close too early)

        new_chain = chain + [next_edge]

        # Does this new edge close the cycle back to the start?
        if next_edge.needed_category_id == start_edge.offered_category_id:
            if len(new_chain) >= 3:  # length-2 closures are direct matches, not cyclic ones
                # De-duplication: only keep this cycle if start_edge has the
                # smallest preference_id in the chain, so the same cycle
                # found starting from a different edge isn't reported again.
                if start_edge.preference_id == min(e.preference_id for e in new_chain):
                    found_cycles.append(MatchResult(edges=tuple(new_chain)))
            continue  # don't also try to extend past a closing edge

        # Otherwise, keep extending the chain (if there's room left).
        if len(new_chain) < max_length:
            _search_from(
                start_edge=start_edge,
                current_edge=next_edge,
                chain=new_chain,
                visited_user_ids=visited_user_ids | {next_edge.user_id},
                edges_by_offered_category=edges_by_offered_category,
                max_length=max_length,
                found_cycles=found_cycles,
            )
