"""
Semantic (AI) search over service listings.

Uses a multilingual sentence-transformer model — works for both Arabic and
English, which matters since this marketplace's users search in either —
to embed the user's free-text query and each active service's
title/description/category, then ranks by cosine similarity instead of
exact keyword matching. That's what lets a query like "بدي حدا يصلح
التكييف" surface a listing titled "AC Repair".

Performance note (this is the part the original prototype got wrong):
embedding a piece of text is the expensive step — a small forward pass
through a transformer model — so re-embedding every service on every
search request does not scale past a handful of listings. Per-service
embeddings are instead cached in-process, keyed by the service's id and a
hash of its searchable chunks, and only recomputed when those actually
change (title/description/category edited). A search request therefore
only pays the embedding cost once, for the query itself; every service
embedding after the first search is a cache hit.

This in-memory cache is intentionally simple, matching the scope of the
rest of this project — it resets on restart and isn't shared across
worker processes. A production deployment serving real traffic should
persist embeddings instead (a pgvector column, or a small vector store)
rather than recomputing them in memory per process.
"""
import hashlib
import re
from math import sqrt

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.config import settings
from app.core.exceptions import ServiceUnavailableError
from app.models.review import Review
from app.models.service import Service, ServiceStatus
from app.models.user import User
from app.schemas.semantic_search import SemanticSearchParams
from app.services import exchange_service
from app.utils import trade_synonyms

# Replaced paraphrase-multilingual-MiniLM-L12-v2 (2026-11-19). On the 29-query
# set, ranked with no cut-off: first result right 22/29 vs 18/29, MRR 0.829 vs
# 0.718. Costs ~3x the time per query and a ~1.1GB download instead of ~470MB.
MODEL_NAME = "paraphrase-multilingual-mpnet-base-v2"

_model = None
# service_id -> (hash of its searchable chunks, [(embedding, chunk text), ...])
# Simple process-local cache — see module docstring.
_embedding_cache: dict[int, tuple[str, list[tuple[list[float], str]]]] = {}

# Cheap language detection: presence of any Arabic-block character is
# enough to tell Arabic from English/Latin text for this app's purposes —
# no need for a real language-ID model for a two-language marketplace.
_ARABIC_CHAR_RE = re.compile(r"[\u0600-\u06FF]")


def _arabic_fraction(text: str) -> float:
    """
    Rough fraction, from 0.0 (purely Latin/English) to 1.0 (purely
    Arabic-script), of how "Arabic" a piece of text is — the share of
    Arabic-block letters among all letters in it.

    A service can legitimately mix an English name ("Electronics Repair")
    with an Arabic description ("بصلح لابتوبات وجوالات"), so this is a
    continuous mix rather than a single ar/en label — see `_centered`,
    which uses it to blend the two language centroids proportionally
    instead of picking one or the other.
    """
    arabic = len(_ARABIC_CHAR_RE.findall(text or ""))
    latin = len(re.findall(r"[A-Za-z]", text or ""))
    total = arabic + latin
    if total == 0:
        return 0.0
    return arabic / total


def _get_model():
    """Lazily loads the sentence-transformer model on first real use, so a
    server with SEMANTIC_SEARCH_ENABLED=false (or without the optional
    dependency installed) never pays the import/download cost.

    In the normal running app this is actually triggered once, up front,
    by warm_up() at server startup (see main.py) rather than by the first
    search request — see warm_up()'s docstring for why."""
    global _model
    if _model is None:
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as error:
            raise ServiceUnavailableError(
                "البحث الذكي يتطلب مكتبة 'sentence-transformers'. "
                "ثبّتها باستخدام: pip install sentence-transformers"
            ) from error
        # low_cpu_mem_usage=False: without this, a recent `transformers`
        # paired with this pinned sentence-transformers version loads the
        # model onto a `meta` device (a memory-saving trick meant for huge
        # models) and then fails to materialize it, raising
        # "NotImplementedError: Cannot copy out of meta tensor; no data!".
        # This is a small CPU-only embedding model, so we don't need that
        # optimization anyway — disabling it sidesteps the bug regardless
        # of exactly which `transformers` version pip happened to resolve.
        _model = SentenceTransformer(
            MODEL_NAME, model_kwargs={"low_cpu_mem_usage": False}
        )
    return _model


def warm_up() -> None:
    """
    Loads (and, on the very first run ever, downloads — ~1.1GB) the
    embedding model immediately, instead of waiting for the first real
    search request to trigger it.

    Called once from main.py's startup hook when SEMANTIC_SEARCH_ENABLED
    is true. Without this, the first user to hit /search/semantic pays
    that entire download+load cost inline — which routinely exceeds a
    normal HTTP client timeout (the Flutter app's is 20s) and surfaces as
    a scary "server took too long to respond" error, even though the
    server is working fine, just busy downloading. Paying that cost once
    at startup instead means it shows up as a slower `uvicorn` boot
    (logged, expected, one-time) rather than a broken-looking first
    request.
    """
    _get_model()


def _embed(text: str) -> list[float]:
    model = _get_model()
    return model.encode(text or "").tolist()


def _searchable_chunks(service: Service) -> list[str]:
    """
    The texts a service is matched on, scored separately by `rank_services`,
    which keeps the best of them.

    One text would be simpler, and was what this did until 2026-11-20. The
    problem is dilution: a sentence embedding averages a whole text, so a
    trade name sits in it alongside everything else the provider wrote. A
    real plumber here, filed under «سباكة» and described as «تثبيت وتوصيل
    المغاسل واحواض الاستحمام وسخانات المياه والحنفيات», scored 0.148 for the
    query «سباك» — under any usable cut-off — while the same listing with a
    short description scored 0.75. The trade name was one word in nine.

    So the whole text is kept (it is what matches a query phrased like a
    sentence), and two narrower views are added beside it:

      * the identity — the category, its description, the «أخرى» label and
        the title: what the service IS, undiluted, which is what a one-word
        trade query («سباك») actually looks like;
      * the description alone — what the provider DOES, which is what a
        specific query («مغسلة», «سخان») looks like.

    The identity chunk also carries the trade's everyday words, the same ones
    `_query_vector` sends with the query. Without them it is often one or two
    words, and a very short text keeps little of itself once the language
    centroid is subtracted (see `_centered`) — it then scores high against
    anything. That is measurable: the chunk «سباكة» alone answered the query
    «الحلاقة» at 0.53, above the cut-off, and «سباكة سباك حنفية مواسير» drops
    that to nothing while raising the plumber's own queries (0.77 -> 0.85 for
    «حنفية»). Damping short chunks instead was measured and was far worse —
    it took the rescue away and 9 of 17 live queries went back to empty.

    A listing with no description has nothing to split, so it yields the one
    chunk rather than near-duplicates.
    """
    identity = " ".join(
        part
        for part in [
            service.category.name,
            service.category.description,
            # When filed under "Others", the category name itself ("Others"
            # / "أخرى") carries no useful meaning for matching a query like
            # "سباك" or "plumber" — the custom label is what actually
            # describes the service, so it's included here same as the title.
            service.custom_category_label,
            service.title,
        ]
        if part
    )
    description = service.description or ""
    if not identity:
        return [description] if description else []
    # The whole text keeps the provider's own wording, with nothing added.
    identity_chunk = " ".join([identity, *trade_synonyms.core_words(service.category.name)])
    if not description:
        return [identity_chunk]
    return [f"{identity} {description}", identity_chunk, description]


def _cached_chunk_embeddings(service: Service) -> list[tuple[list[float], str]]:
    """Returns [(embedding, chunk text)] for a service, using the cache when
    its searchable chunks haven't changed."""
    chunks = _searchable_chunks(service)
    # The separator cannot appear in the chunks themselves, so two different
    # splits can never hash the same.
    chunks_hash = hashlib.sha256("\0".join(chunks).encode("utf-8")).hexdigest()
    cached = _embedding_cache.get(service.id)
    if cached is not None and cached[0] == chunks_hash:
        return cached[1]

    embedded = [(_embed(chunk), chunk) for chunk in chunks]
    _embedding_cache[service.id] = (chunks_hash, embedded)
    return embedded


# A handful of everyday service-request sentences per language, covering a
# spread of trades so their average represents "this language" in general
# rather than any one topic (repair, cleaning, tutoring, ...).
_CALIBRATION_SENTENCES: dict[str, list[str]] = {
    "en": [
        "I need someone to repair my laptop.",
        "Looking for a plumber to fix a leaking pipe.",
        "Can you clean my apartment this weekend?",
        "I want to hire a math tutor for my son.",
        "Need an electrician to fix the wiring in my kitchen.",
        "Looking for a professional photographer for a wedding.",
        "I need my car serviced and the oil changed.",
        "Can someone paint the walls of my living room?",
        "I'm searching for a babysitter for two evenings a week.",
        "Need a graphic designer to make a logo for my business.",
        "Looking for a personal trainer for weight loss.",
        "I need a mobile phone screen replaced.",
        "Searching for a moving company to relocate furniture.",
        "Can you fix my broken air conditioner?",
        "I need a haircut and a beard trim.",
        "Looking for someone to translate a document into French.",
        "I need help setting up a new Wi-Fi router at home.",
        "Searching for a caterer for a birthday party.",
        "Need a carpenter to build a wooden bookshelf.",
        "Looking for a private chef to cook dinner for guests.",
    ],
    "ar": [
        "بدي حدا يصلحلي اللابتوب تبعي.",
        "بدور عالسباك يصلح تسريب بالمي.",
        "ممكن حدا ينضف الشقة هالويكند؟",
        "بدي معلم رياضيات لابني.",
        "بدي كهربائي يصلح الأسلاك بالمطبخ.",
        "بدور عالمصور محترف لعرس.",
        "بدي أصلح سيارتي وبدل الزيت.",
        "ممكن حدا يدهن حيطان الصالون؟",
        "بدور عالبيبي سيتر لسهرتين بالأسبوع.",
        "بدي مصمم غرافيك يعملي لوغو لمشروعي.",
        "بدور عالمدرب شخصي عشان خسارة وزن.",
        "بدي بدل شاشة الموبايل المكسورة.",
        "بدور عالشركة نقل تنقلي الأثاث.",
        "المكيف تبعي عاطل بدي يتصلح.",
        "بدي قصة شعر وتنعيم دقن.",
        "بدور عحدا يترجملي مستند عالفرنسي.",
        "بدي مساعدة بتنصيب الراوتر بالبيت.",
        "بدور عالطعام لحفلة عيد ميلاد.",
        "بدي نجار يعملّي مكتبة خشب.",
        "بدور عالشيف يطبخلي عشا لضيوف.",
    ],
}

_calibration_centroid_cache: dict[str, list[float]] = {}


def _calibration_centroid(lang: str) -> list[float]:
    """
    Fixed, catalog-independent reference point for "generic marketplace
    text in this language" — see `_centered` for why this is subtracted
    from embeddings before comparing them.

    Computed once (lazily, on first use, then cached for the process
    lifetime) from `_CALIBRATION_SENTENCES`, a small hand-written set of
    everyday service requests. Deriving the centroid this way — instead
    of averaging whatever services already happen to be in the catalog —
    means it doesn't need the catalog to already contain several listings
    in a language before that language starts working properly: a brand
    new catalog with just one Arabic listing gets just as good an Arabic
    centroid as one with a thousand.
    """
    cached = _calibration_centroid_cache.get(lang)
    if cached is not None:
        return cached

    vectors = [_embed(sentence) for sentence in _CALIBRATION_SENTENCES[lang]]
    dim = len(vectors[0])
    centroid = [sum(vector[i] for vector in vectors) / len(vectors) for i in range(dim)]
    _calibration_centroid_cache[lang] = centroid
    return centroid


def _centered(embedding: list[float], text: str) -> list[float]:
    """
    Subtracts a language centroid from `embedding` to correct for the
    "language gap": multilingual sentence-transformer models place each
    language's sentences in a slightly different region of the embedding
    space, so even a perfect Arabic/English translation pair ends up with
    a noticeably lower cosine similarity than two same-language sentences
    with the same meaning. That's what made Arabic queries effectively
    only surface Arabic listings (and English queries only English ones)
    even though nothing here explicitly filters by language.

    `text` is the original text this embedding came from (the query, or a
    service's searchable text), used only to weigh how "Arabic vs
    English" it is (see `_arabic_fraction`) so a listing that mixes an
    English name with an Arabic description gets a proportionally blended
    centroid rather than being forced into one language or the other.
    """
    alpha = _arabic_fraction(text)
    ar_centroid = _calibration_centroid("ar")
    en_centroid = _calibration_centroid("en")
    blended = [
        alpha * ar_value + (1 - alpha) * en_value
        for ar_value, en_value in zip(ar_centroid, en_centroid)
    ]
    return [value - mean for value, mean in zip(embedding, blended)]


def _query_vector(query: str) -> list[float]:
    """
    The centred embedding of a search query, with the everyday words of the
    trades it names (see app/utils/trade_synonyms.py): «جوال» alone sits
    nowhere near a phone-repair listing for this model; with «موبايل هاتف
    …» beside it, it does.
    """
    text = trade_synonyms.expand(query)
    return _centered(_embed(text), text)


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    dot_product = sum(x * y for x, y in zip(a, b))
    magnitude_a = sqrt(sum(x * x for x in a))
    magnitude_b = sqrt(sum(y * y for y in b))
    if magnitude_a == 0 or magnitude_b == 0:
        return 0.0
    return dot_product / (magnitude_a * magnitude_b)


def ensure_enabled() -> None:
    """Search ranks by the model alone, so without it there is no search."""
    if not settings.SEMANTIC_SEARCH_ENABLED:
        raise ServiceUnavailableError(
            "البحث الذكي غير مفعّل على هذا السيرفر. فعّل SEMANTIC_SEARCH_ENABLED=true "
            "في ملف .env ثم أعد تشغيل السيرفر (راجع SEMANTIC_SEARCH_SETUP.md)."
        )


def rank_services(services, query: str, threshold: float) -> list[tuple[Service, float]]:
    """
    [(service, similarity)] for the services at or above `threshold`, best
    first (ties by id, so the order does not depend on the database's).

    A service's similarity is the best of its searchable chunks (see
    `_searchable_chunks`): it matches on any one view of itself rather than
    on the average of all of them.
    """
    query_vector = _query_vector(query)
    scored: list[tuple[Service, float]] = []
    for service in services:
        score = max(
            (
                _cosine_similarity(query_vector, _centered(embedding, text))
                for embedding, text in _cached_chunk_embeddings(service)
            ),
            # A service with no category name, title or description at all
            # has nothing to match against.
            default=0.0,
        )
        if score >= threshold:
            scored.append((service, score))
    scored.sort(key=lambda pair: (-pair[1], pair[0].id))
    return scored


def _service_rating(db: Session, service_id: int) -> tuple[float, int]:
    avg_rating, total_reviews = (
        db.query(func.avg(Review.rating), func.count(Review.id))
        .filter(Review.service_id == service_id)
        .first()
    )
    return (
        round(float(avg_rating), 2) if avg_rating is not None else 0.0,
        total_reviews or 0,
    )


def service_ratings(db: Session, service_ids: list[int]) -> dict[int, tuple[float, int]]:
    """
    (average_rating, total_reviews) for every id in `service_ids`, read with
    ONE grouped query for the whole result page instead of one query per
    result. Same values as `_service_rating`: the average rounded to two
    decimals, and (0.0, 0) for a service that has no reviews yet.
    """
    rated = exchange_service.service_ratings(db, service_ids)
    return {service_id: rated.get(service_id, (0.0, 0)) for service_id in service_ids}


def search_services_semantic(
    db: Session, params: SemanticSearchParams
) -> list[tuple[Service, float, tuple[float, int]]]:
    """
    Returns (Service, similarity_score, (average_rating, total_reviews))
    tuples for active services whose embedding similarity to `params.q`
    meets `params.threshold`, best match first.
    """
    ensure_enabled()

    query = params.q.strip()
    if not query:
        return []

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

    services = db.execute(stmt).scalars().all()
    top = rank_services(services, query, params.threshold)[: params.limit]

    ratings = service_ratings(db, [service.id for service, _ in top])
    return [(service, round(score, 4), ratings[service.id]) for service, score in top]
