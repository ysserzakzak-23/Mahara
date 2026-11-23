"""
FastAPI application entrypoint.

Each phase adds its router(s) here as they're built. Currently wired:
  - Phase 2: auth, users
  - Phase 3: categories, services, portfolio, barter preferences
  - Phase 4: search (geo)
  - Phase 5: reviews
  - Phase 6: availability, appointments
  - Phase 7: notifications
  - Phase 8: admin
  - Phase 9: barter matches
"""
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.core.config import settings
from app.core.error_handlers import register_error_handlers
from app.routers import (
    admin,
    appointments,
    auth,
    availability,
    barter_matches,
    barter_preferences,
    categories,
    cities,
    exchange,
    notifications,
    portfolio,
    reviews,
    search,
    services,
    uploads,
    users,
)

logger = logging.getLogger(__name__)


def _warm_up_semantic_search() -> None:
    """
    Pre-loads the semantic search model at boot instead of on the first
    search request — see semantic_search_service.warm_up() for why.
    Only runs when SEMANTIC_SEARCH_ENABLED=true; a slow/failed download
    here is logged but doesn't stop the server from starting, so the rest
    of the API stays usable even if this one optional feature can't load.
    """
    if not settings.SEMANTIC_SEARCH_ENABLED:
        return

    from app.services import semantic_search_service

    logger.info(
        "Semantic search enabled — loading embedding model (%s). "
        "First run downloads it (~1.1GB); this may take a while.",
        semantic_search_service.MODEL_NAME,
    )
    try:
        semantic_search_service.warm_up()
        logger.info("Semantic search model loaded.")
    except Exception:
        logger.exception(
            "Failed to load the semantic search model at startup — "
            "/search/semantic will return 503 until this is fixed."
        )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Startup and shutdown, in place of the deprecated on_event hooks.

    The warm-up is called directly rather than through a threadpool: that
    is what Starlette did with a synchronous on_event("startup") handler
    (routing.Router.startup awaits async handlers and calls sync ones
    inline), so the execution model is unchanged. Nothing is served until
    startup finishes either way.

    There is nothing to do on shutdown — the database sessions are
    per-request and closed by their dependency.
    """
    _warm_up_semantic_search()
    yield


app = FastAPI(
    title=settings.APP_NAME,
    debug=settings.DEBUG,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

register_error_handlers(app)

UPLOAD_DIR = Path(__file__).resolve().parent.parent / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=str(UPLOAD_DIR)), name="uploads")

app.include_router(auth.router)
app.include_router(users.router)
app.include_router(categories.router)
app.include_router(cities.router)
app.include_router(services.router)
app.include_router(portfolio.router)
app.include_router(barter_preferences.router)
app.include_router(search.router)
app.include_router(reviews.router)
app.include_router(availability.router)
app.include_router(appointments.router)
app.include_router(notifications.router)
app.include_router(admin.router)
app.include_router(barter_matches.router)
app.include_router(exchange.router)
app.include_router(exchange.proposals_router)
app.include_router(uploads.router)


@app.get("/health", tags=["Health"])
def health_check() -> dict:
    """Basic liveness check used for deployment health probes."""
    return {"status": "ok", "environment": settings.ENVIRONMENT}
