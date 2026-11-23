"""
Direct matching algorithm for ExchangeRequest — O(n) hash-map based.

This is deliberately a SEPARATE, simpler algorithm from
app/algorithms/barter_matching.py (which does O(n^2) pairwise + bounded
cycle search over BarterPreference "category radar" edges). This one
operates on ExchangeRequest rows specifically — each tied to one
concrete offered_service, not just a category — and only looks for
direct (2-party) matches, which is the common case worth optimizing for.

ALGORITHM: build a hash map keyed by (offered_category_id,
wanted_category_id) -> list of requests with that exact pair. Then for
each request, do an O(1) lookup of the REVERSE key (wanted, offered) to
find every request that would satisfy it — no pairwise O(n^2) comparison
needed. Overall O(n) instead of O(n^2).

THE «أخرى» (OTHER) CATEGORY: its category id alone says nothing about the
service ("Other" offered by a plumber and "Other" offered by a carpenter
share the same id), so for Other the custom label is what identifies the
service. A request edge therefore carries `offered_label` / `wanted_label`,
set ONLY when that side's category is Other (an empty string if the label is
missing). After the O(1) category lookup, every labelled side is verified
with `labels_equivalent` — in BOTH directions — so a match still requires:
  1. the other request offers what this one wants, and
  2. the other request wants what this one offers.
"""
from dataclasses import dataclass
from typing import Optional

from app.utils.arabic_search import labels_equivalent


@dataclass(frozen=True)
class RequestEdge:
    """
    One ExchangeRequest, flattened to the plain data the algorithm needs
    (no ORM/session dependency — this module has zero database coupling,
    matching the convention in app/algorithms/barter_matching.py).
    """
    id: int
    user_id: int
    offered_category_id: int
    wanted_category_id: int
    offered_service_id: int
    # Custom labels — only set (to a possibly empty string) when that
    # side's category is «أخرى». None means "a regular category: its id
    # already identifies the service".
    offered_label: Optional[str] = None
    wanted_label: Optional[str] = None


def _side_matches(wanted_label: Optional[str], offered_label: Optional[str]) -> bool:
    """Does an offer satisfy a want, given they already share a category id?"""
    if wanted_label is None and offered_label is None:
        return True  # a regular category: same id is the same service
    return labels_equivalent(wanted_label, offered_label)


def is_direct_match(a: RequestEdge, b: RequestEdge) -> bool:
    """
    True when `a` and `b` form a complete two-way exchange: b offers what a
    wants AND a offers what b wants (categories and, for «أخرى», labels).
    """
    if a.id == b.id or a.user_id == b.user_id:
        return False
    return (
        a.wanted_category_id == b.offered_category_id
        and a.offered_category_id == b.wanted_category_id
        and _side_matches(a.wanted_label, b.offered_label)
        and _side_matches(b.wanted_label, a.offered_label)
    )


def find_direct_matches(requests: list[RequestEdge]) -> list[dict]:
    """
    Finds every direct (2-party) match among open ExchangeRequests: pairs
    where A offers what B wants AND B offers what A wants (see
    `is_direct_match`; «أخرى» labels are compared, not just category ids).

    Returns a list of plain dicts (not a dataclass) — this is the shape
    the API/notification layer consumes directly, one dict per match:
        {
            "match_type": "direct",
            "user_a": <user_id>, "user_b": <user_id>,
            "request_a_id": <id>, "request_b_id": <id>,
            "service_a_id": <offered_service_id>, "service_b_id": <offered_service_id>,
        }
    """
    matches: list[dict] = []
    lookup: dict[tuple[int, int], list[RequestEdge]] = {}

    # Build the hash map: (offered_category_id, wanted_category_id) -> requests.
    for request in requests:
        key = (request.offered_category_id, request.wanted_category_id)
        lookup.setdefault(key, []).append(request)

    processed_pairs: set[tuple[int, int]] = set()

    # Look up matches: for each request, its reverse key is exactly what
    # a satisfying counterpart's (offered, wanted) pair would be.
    for request in requests:
        reverse_key = (request.wanted_category_id, request.offered_category_id)
        if reverse_key not in lookup:
            continue

        for candidate in lookup[reverse_key]:
            # Self-matches, same-user pairs and «أخرى» label mismatches
            # (either direction) are all rejected here.
            if not is_direct_match(request, candidate):
                continue

            pair = tuple(sorted([request.id, candidate.id]))
            if pair in processed_pairs:
                continue  # each unordered pair reported exactly once
            processed_pairs.add(pair)

            matches.append(
                {
                    "match_type": "direct",
                    "user_a": request.user_id,
                    "user_b": candidate.user_id,
                    "request_a_id": request.id,
                    "request_b_id": candidate.id,
                    "service_a_id": request.offered_service_id,
                    "service_b_id": candidate.offered_service_id,
                }
            )

    return matches
