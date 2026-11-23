"""
Smart search — the app's main search.

Ranks by meaning alone: the embedding model compares the query — sent with
the everyday words of the trade it names (app/utils/trade_synonyms.py), so
«جوال» reaches the model as «جوال جوالات جوال موبايل هاتف» — with
each listing, and keeps the ones at or above SIMILARITY_THRESHOLD. A listing
is compared on several views of itself (its whole text, its trade, its
description) and keeps its best one, so a long description cannot bury the
trade name — see semantic_search_service._searchable_chunks.

Two floors decide what is shown: SIMILARITY_THRESHOLD, a fixed one, and
RELATIVE_THRESHOLD, measured against the best score for that same query. The
second exists because a neighbouring trade can clear any fixed floor that the
genuine weaker matches also need.

The Arabic keyword engine (app/utils/arabic_search.py) takes no part in the
ranking. Only its tokenizer is used, to answer a query with no real word in
it («بدي حدا», «!!!») without touching the database.

It therefore needs the model: with SEMANTIC_SEARCH_ENABLED=false, or after
the model failed to load, it answers 503 like /search/semantic.
"""
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.exceptions import ServiceUnavailableError
from app.models.profile import UserProfile
from app.models.service import Service, ServiceStatus
from app.models.user import User
from app.schemas.semantic_search import SmartSearchParams
from app.services import semantic_search_service as sem
from app.utils import arabic_search

logger = logging.getLogger(__name__)

# Re-measured on the 29-query set (40 listings) after ranking moved to the best
# of a listing's chunks rather than one averaged text — see
# semantic_search_service._searchable_chunks. Chunking lifts every score, so the
# cut-off that went with the single text is too low for it. Columns: first
# result right, within top 3, MRR, queries answered with nothing, wrong results
# inside the top 3, and the share of all the expected listings found at all.
#   0.30: 19/29  23/29  0.727  2  31  77%
#   0.35: 19/29  23/29  0.718  2  28  74%
#   0.40: 18/29  22/29  0.684  4  22  70%
#   0.45: 18/29  21/29  0.667  5  17  65%
# The single averaged text at 0.30 — the behaviour before chunking — scored
#         17/29  22/29  0.667  4  19  67%.
#
# 0.45 is the only point that beats that old behaviour on both of the things a
# user notices: more queries whose FIRST result is right (18 vs 17) and FEWER
# wrong results sitting in the top 3 (17 vs 19). It costs one more query that
# returns nothing (5 vs 4) and two points of recall.
#
# A relative cut-off was measured as the alternative — keep a result only within
# x% of the query's best score — and rejected: it sheds noise harder but takes
# correct listings with it (recall 63% at 0.85, against 65% here), and 13 of the
# 29 queries have more than one right answer, so a provider who is a genuine
# second-best match would stop being shown at all.
SIMILARITY_THRESHOLD = 0.45

# A second, relative floor: keep a result only while it is within this share of
# the best score for that same query.
#
# The absolute cut-off alone cannot separate "related trade" from "the trade":
# «حنفية» answered with the plumber at 0.85 and then a locksmith at 0.59 and a
# barber at 0.46 — both far below the right answer, both above 0.45. The model
# reads locks and plumbing as neighbours (home fitting and maintenance), so no
# absolute number splits them without also losing «مغسلة» (0.59) and «جوال»
# (0.48). A floor measured per query does split them.
#
# Measured on the 29-query set at the 0.45 floor — wrong-in-top-3 / recall:
#   none: 17 / 65%     0.70: 13 / 63%     0.75: 13 / 63%     0.80: 12 / 60%
# first-right, top-3 and MRR are identical across all of them. On the live
# catalogue 0.75 took the extra results from 6 to 0 with all 20 first results
# still correct.
#
# It costs one correct SECOND answer across the 29 («الغرفة ما عم تبرد»: the
# first AC specialist is kept, a second one falls away). That is the trade-off
# being accepted here: a provider who is a distant second stops being listed.
# This was measured and rejected once before, when it cost 11 points of recall;
# it only became cheap after the identity chunk started carrying the trade
# words and right answers rose to 0.85-1.00. Re-measure before changing it.
RELATIVE_THRESHOLD = 0.75

# Set when the embedding model fails once, so it is not reloaded (and logged)
# on every request. Restart the server after fixing the model setup.
_semantic_failed = False

_MODEL_FAILED_MESSAGE = (
    "البحث غير متاح حالياً: تعذّر تشغيل موديل البحث على السيرفر. "
    "أعد تشغيل السيرفر بعد إصلاحه (راجع SEMANTIC_SEARCH_SETUP.md)."
)


def search_services_smart(
    db: Session, params: SmartSearchParams
) -> list[tuple[Service, float, tuple[float, int]]]:
    """
    Returns (Service, similarity, (average_rating, total_reviews)) for active
    services whose meaning is close enough to `params.q`, best match first.
    """
    global _semantic_failed
    if arabic_search.analyze_query(params.q).is_empty:
        return []
    sem.ensure_enabled()
    if _semantic_failed:
        raise ServiceUnavailableError(_MODEL_FAILED_MESSAGE)

    stmt = (
        select(Service)
        .join(User, Service.provider_id == User.id)
        .options(
            selectinload(Service.category),
            selectinload(Service.provider).selectinload(User.profile),
        )
        .where(Service.status == ServiceStatus.ACTIVE, User.is_active.is_(True))
    )
    if params.category_id is not None:
        stmt = stmt.where(Service.category_id == params.category_id)
    if params.city is not None:
        stmt = stmt.join(UserProfile, UserProfile.user_id == User.id).where(UserProfile.city == params.city)

    services = list(db.execute(stmt).scalars().all())
    if not services:
        return []

    try:
        ranked = sem.rank_services(services, params.q, SIMILARITY_THRESHOLD)
    except Exception as error:
        _semantic_failed = True
        logger.warning("Embedding model unavailable - search is down until restart.", exc_info=True)
        raise ServiceUnavailableError(_MODEL_FAILED_MESSAGE) from error

    if ranked:
        # rank_services returns best first, so ranked[0] carries the top score.
        floor = ranked[0][1] * RELATIVE_THRESHOLD
        ranked = [pair for pair in ranked if pair[1] >= floor]

    top = ranked[: params.limit]
    # One grouped query for the whole page (not one per result).
    ratings = sem.service_ratings(db, [service.id for service, _ in top])
    return [(service, round(score, 4), ratings[service.id]) for service, score in top]
