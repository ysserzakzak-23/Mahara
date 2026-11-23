"""
Pure logic of semantic search (no model download, no database) and the Firebase
push wrapper (firebase_admin is replaced by a fake module).
"""
import logging
import os
import subprocess
import sys
import types
from types import SimpleNamespace

import pytest

from app.core.exceptions import ServiceUnavailableError
from app.models.service import ServiceStatus  # noqa: F401  (imported by the service under test)
from app.schemas.semantic_search import SemanticSearchParams
from app.services import semantic_search_service as sem
from app.utils import fcm_client
from tests.helpers import make_result, where_clause


# ============================================================ text helpers
@pytest.mark.parametrize(
    "text, expected",
    [
        ("", 0.0),
        (None, 0.0),
        ("1234 !!", 0.0),          # no letters at all
        ("Plumbing", 0.0),
        ("سباكة", 1.0),
        ("ab مر", 0.5),            # 2 Latin + 2 Arabic letters
    ],
)
def test_arabic_fraction(text, expected):
    assert sem._arabic_fraction(text) == pytest.approx(expected)


@pytest.mark.parametrize(
    "a, b, expected",
    [
        ([1, 0], [1, 0], 1.0),
        ([1, 0], [0, 1], 0.0),
        ([1, 0], [-1, 0], -1.0),
        ([1, 1], [2, 2], 1.0),
        ([0, 0], [1, 1], 0.0),     # a zero vector never divides by zero
        ([1, 1], [0, 0], 0.0),
    ],
)
def test_cosine_similarity(a, b, expected):
    assert sem._cosine_similarity(a, b) == pytest.approx(expected)


def test_centering_subtracts_a_language_weighted_centroid(monkeypatch):
    monkeypatch.setattr(
        sem, "_calibration_centroid",
        lambda lang: [2.0, 4.0] if lang == "ar" else [0.0, 0.0],
    )
    assert sem._centered([3.0, 5.0], "مرحبا") == pytest.approx([1.0, 1.0])     # fully Arabic
    assert sem._centered([3.0, 5.0], "hello") == pytest.approx([3.0, 5.0])    # fully English
    assert sem._centered([3.0, 5.0], "ab مر") == pytest.approx([2.0, 3.0])    # half and half


def service(id=1, title="AC Repair", description="fixes air conditioners",
            category="Home", category_description=None, label=None):
    return SimpleNamespace(
        id=id, title=title, description=description, custom_category_label=label,
        category=SimpleNamespace(name=category, description=category_description),
    )


def test_searchable_chunks_keep_the_whole_text_and_split_identity_from_description():
    s = service(label="Cooling", category_description="Household")
    assert sem._searchable_chunks(s) == [
        "Home Household Cooling AC Repair fixes air conditioners",   # everything
        "Home Household Cooling AC Repair",                          # what it IS
        "fixes air conditioners",                                    # what it DOES
    ]


def test_searchable_chunks_skip_missing_parts_and_never_repeat_a_chunk():
    """Nothing to split without a description, so the identity is not listed twice."""
    s = service(description=None)
    assert sem._searchable_chunks(s) == ["Home AC Repair"]


def test_the_identity_chunk_carries_the_trade_words():
    """A one- or two-word identity keeps little of itself once centred and then
    scores high against anything, so it gets the trade's own words — the same
    ones a query gets. The whole text stays the provider's own wording."""
    s = service(title=None, category="سباكة", description="تصليح مغاسل")

    whole, identity, description = sem._searchable_chunks(s)

    assert identity == "سباكة سباك حنفية مواسير"
    assert whole == "سباكة تصليح مغاسل"        # nothing added here
    assert description == "تصليح مغاسل"


def test_an_unknown_category_adds_no_trade_words():
    """«أخرى» and any category added after the synonym table have none."""
    s = service(category="أخرى", label="Gardener", description="mows lawns")
    assert sem._searchable_chunks(s)[1] == "أخرى Gardener AC Repair"


# =========================================================== embedding cache
@pytest.fixture
def embeds(monkeypatch):
    monkeypatch.setattr(sem, "_embedding_cache", {})
    seen = []

    def fake_embed(text):
        seen.append(text)
        return [float(len(text))]

    monkeypatch.setattr(sem, "_embed", fake_embed)
    return seen


def test_a_service_is_embedded_once_per_chunk_while_its_text_is_unchanged(embeds):
    s = service()
    first = sem._cached_chunk_embeddings(s)
    second = sem._cached_chunk_embeddings(s)

    assert first == second
    assert len(embeds) == 3      # its three chunks, embedded on the first call only


def test_editing_the_listing_invalidates_its_cached_embedding(embeds):
    s = service()
    sem._cached_chunk_embeddings(s)
    s.title = "AC Repair and Installation"

    embedded = sem._cached_chunk_embeddings(s)

    assert len(embeds) == 6      # every chunk re-embedded, none served stale
    assert any("Installation" in text for _embedding, text in embedded)
    assert all(embedding == [float(len(text))] for embedding, text in embedded)


def test_each_service_has_its_own_cache_entry(embeds):
    sem._cached_chunk_embeddings(service(id=1))
    sem._cached_chunk_embeddings(service(id=2))
    sem._cached_chunk_embeddings(service(id=1))
    assert len(embeds) == 6      # three chunks each; the repeat is a cache hit


def test_embed_encodes_the_text_with_the_model(monkeypatch):
    seen = []
    model = SimpleNamespace(encode=lambda text: seen.append(text) or SimpleNamespace(tolist=lambda: [0.5, 0.25]))
    monkeypatch.setattr(sem, "_get_model", lambda: model)

    assert sem._embed("hello") == [0.5, 0.25]
    assert sem._embed(None) == [0.5, 0.25]
    assert seen == ["hello", ""]


# ============================================================== model loading
def test_missing_dependency_gives_a_helpful_503(monkeypatch):
    monkeypatch.setattr(sem, "_model", None)
    monkeypatch.setitem(sys.modules, "sentence_transformers", None)    # makes the import fail

    with pytest.raises(ServiceUnavailableError, match="sentence-transformers"):
        sem._get_model()


def test_the_model_is_loaded_once_and_reused(monkeypatch):
    created = []

    class FakeModel:
        def __init__(self, name, **kwargs):
            created.append((name, kwargs))

    monkeypatch.setattr(sem, "_model", None)
    monkeypatch.setitem(sys.modules, "sentence_transformers", SimpleNamespace(SentenceTransformer=FakeModel))

    first = sem._get_model()
    second = sem._get_model()

    assert first is second
    assert len(created) == 1 and created[0][0] == sem.MODEL_NAME


def test_warm_up_loads_the_model(monkeypatch):
    loaded = []
    monkeypatch.setattr(sem, "_get_model", lambda: loaded.append(True))
    sem.warm_up()
    assert loaded == [True]


# ================================================================= rating
def test_service_rating_rounds_and_handles_no_reviews(db):
    db.query.return_value.filter.return_value.first.return_value = (4.6666, 3)
    assert sem._service_rating(db, 1) == (4.67, 3)

    db.query.return_value.filter.return_value.first.return_value = (None, 0)
    assert sem._service_rating(db, 1) == (0.0, 0)

    db.query.return_value.filter.return_value.first.return_value = (None, None)
    assert sem._service_rating(db, 1) == (0.0, 0)


# =================================================================== search
VECTORS = {1: [1.0, 0.0, 0.0], 2: [0.0, 1.0, 0.0], 3: [0.6, 0.8, 0.0]}


@pytest.fixture
def search_env(monkeypatch, db):
    """Three services with hand-made embeddings; the query embeds to [1, 0, 0]."""
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", True)
    services = [
        service(1, "AC Repair", "fixes air conditioners"),
        service(2, "Plumbing", "fixes pipes"),
        service(3, "Cleaning", "house cleaning"),
    ]
    monkeypatch.setattr(
        sem, "_cached_chunk_embeddings", lambda s: [(VECTORS[s.id], sem._searchable_chunks(s)[0])]
    )
    monkeypatch.setattr(sem, "_embed", lambda text: [1.0, 0.0, 0.0])
    monkeypatch.setattr(sem, "_calibration_centroid", lambda lang: [0.0, 0.0, 0.0])
    # Ratings are read for the whole result page in one call.
    monkeypatch.setattr(sem, "service_ratings", lambda db, ids: {i: (4.5, 3) for i in ids})
    db.execute.return_value = make_result(scalars=SimpleNamespace(all=lambda: services))
    return services


def run(db, **params):
    params.setdefault("q", "cooling")
    return sem.search_services_semantic(db, SemanticSearchParams(**params))


def test_search_is_refused_when_the_feature_is_disabled(db, monkeypatch):
    monkeypatch.setattr(sem.settings, "SEMANTIC_SEARCH_ENABLED", False)
    with pytest.raises(ServiceUnavailableError, match="غير مفعّل"):
        run(db)
    db.execute.assert_not_called()


def test_results_are_ranked_by_similarity_and_filtered_by_threshold(db, search_env):
    results = run(db, threshold=0.5)

    assert [(s.id, score) for s, score, _ in results] == [(1, 1.0), (3, 0.6)]   # service 2 scores 0.0
    assert results[0][2] == (4.5, 3)                                             # rating attached


def test_sharing_a_word_does_not_keep_a_low_scoring_service(db, search_env):
    """Meaning alone decides: «Plumbing — fixes pipes» contains the query word
    but scores 0.0."""
    results = run(db, q="pipes", threshold=0.9)
    assert [s.id for s, _, _ in results] == [1]


def test_equal_scores_are_ordered_by_id(db, search_env, monkeypatch):
    monkeypatch.setattr(
        sem, "_cached_chunk_embeddings", lambda s: [([1.0, 0.0, 0.0], sem._searchable_chunks(s)[0])]
    )
    assert [s.id for s, _, _ in run(db, threshold=0.0)] == [1, 2, 3]


def test_limit_truncates_the_ranking(db, search_env):
    results = run(db, threshold=0.0, limit=1)
    assert [s.id for s, _, _ in results] == [1]


def test_scores_are_rounded_to_four_decimals(db, search_env, monkeypatch):
    monkeypatch.setattr(sem, "_embed", lambda text: [1.0, 0.3, 0.0])
    results = run(db, threshold=0.0)
    assert all(score == round(score, 4) for _, score, _ in results)


def test_a_blank_query_returns_nothing_without_touching_the_database(db, search_env):
    assert run(db, q="   ") == []
    db.execute.assert_not_called()


def test_the_query_is_embedded_with_its_trade_synonyms(db, search_env, monkeypatch):
    seen = []
    monkeypatch.setattr(sem, "_embed", lambda text: seen.append(text) or [1.0, 0.0, 0.0])

    run(db, q="جوال")
    assert seen == [seen[0]] and seen[0].startswith("جوال جوالات جوال موبايل")
    assert "موبايل" in seen[0]

    seen.clear()
    run(db, q="cooling")
    assert seen == ["cooling"]          # names no trade: sent as it is


def test_category_filter_is_part_of_the_query(db, search_env):
    run(db)
    assert ":category_id_1" not in where_clause(db.execute.call_args.args[0])

    run(db, category_id=4)
    assert ":category_id_1" in where_clause(db.execute.call_args.args[0])


# ========================================================= Firebase push
def install_fake_firebase(monkeypatch, send=None):
    admin = types.ModuleType("firebase_admin")
    credentials = types.ModuleType("firebase_admin.credentials")
    messaging = types.ModuleType("firebase_admin.messaging")
    state = SimpleNamespace(initialized=[], certificates=[], sent=[])

    class UnregisteredError(Exception):
        pass

    credentials.Certificate = lambda path: state.certificates.append(path) or "certificate"
    admin.initialize_app = lambda cred: state.initialized.append(cred) or "app"
    admin.credentials, admin.messaging = credentials, messaging
    messaging.UnregisteredError = UnregisteredError
    messaging.Message = lambda **kw: SimpleNamespace(**kw)
    messaging.Notification = lambda **kw: SimpleNamespace(**kw)
    messaging.send = send or (lambda message: state.sent.append(message))

    for name, module in {
        "firebase_admin": admin,
        "firebase_admin.credentials": credentials,
        "firebase_admin.messaging": messaging,
    }.items():
        monkeypatch.setitem(sys.modules, name, module)
    state.UnregisteredError = UnregisteredError
    return state


@pytest.fixture
def fcm_enabled(monkeypatch):
    monkeypatch.setattr(fcm_client.settings, "FCM_ENABLED", True)
    monkeypatch.setattr(fcm_client, "_firebase_app", None)


def test_push_is_a_silent_noop_when_fcm_is_disabled(monkeypatch):
    monkeypatch.setattr(fcm_client.settings, "FCM_ENABLED", False)
    monkeypatch.setitem(sys.modules, "firebase_admin", None)     # importing it would blow up

    assert fcm_client.send_push_notification("token-123456789", "T", "B") == (False, None)


def test_push_sends_title_body_and_stringified_data(monkeypatch, fcm_enabled):
    firebase = install_fake_firebase(monkeypatch)

    result = fcm_client.send_push_notification("tok-1", "Title", "Body", {"appointment_id": 42, "type": "x"})

    assert result == (True, None)
    message = firebase.sent[0]
    assert message.token == "tok-1"
    assert (message.notification.title, message.notification.body) == ("Title", "Body")
    assert message.data == {"appointment_id": "42", "type": "x"}


def test_push_without_data_sends_an_empty_dict(monkeypatch, fcm_enabled):
    firebase = install_fake_firebase(monkeypatch)
    fcm_client.send_push_notification("tok-1", "T", "B")
    assert firebase.sent[0].data == {}


def test_the_firebase_app_is_initialised_once_from_the_configured_credentials(monkeypatch, fcm_enabled):
    firebase = install_fake_firebase(monkeypatch)

    fcm_client.send_push_notification("tok-1", "T", "B")
    fcm_client.send_push_notification("tok-2", "T", "B")

    assert firebase.certificates == [fcm_client.settings.FIREBASE_CREDENTIALS_PATH]
    assert firebase.initialized == ["certificate"]
    assert len(firebase.sent) == 2


def test_a_send_failure_is_returned_not_raised(monkeypatch, fcm_enabled):
    boom = RuntimeError("network down")

    def failing_send(message):
        raise boom

    install_fake_firebase(monkeypatch, send=failing_send)

    assert fcm_client.send_push_notification("tok-1", "T", "B") == (False, boom)


def test_missing_firebase_package_is_also_returned_not_raised(monkeypatch, fcm_enabled):
    monkeypatch.setitem(sys.modules, "firebase_admin", None)

    success, error = fcm_client.send_push_notification("tok-1", "T", "B")

    assert success is False and isinstance(error, ImportError)


def test_only_unregistered_token_errors_count_as_dead_tokens(monkeypatch):
    firebase = install_fake_firebase(monkeypatch)

    assert fcm_client.is_invalid_token_error(firebase.UnregisteredError()) is True
    assert fcm_client.is_invalid_token_error(RuntimeError("timeout")) is False


def test_without_firebase_nothing_is_considered_a_dead_token(monkeypatch):
    monkeypatch.setitem(sys.modules, "firebase_admin", None)
    assert fcm_client.is_invalid_token_error(RuntimeError("x")) is False


# ================================================ application lifespan (6C)
#
# Startup moved from the deprecated @app.on_event("startup") to a lifespan
# context manager. These tests enter the lifespan deliberately — most router
# tests build TestClient WITHOUT the context manager precisely so startup
# never runs, and that stays true.
#
# Nothing here loads a real model, touches Firebase, opens a database or
# sleeps: warm_up is replaced by a recorder.

@pytest.fixture
def warm_up_calls(monkeypatch):
    """Records every semantic_search_service.warm_up() call, loading nothing."""
    from app.services import semantic_search_service

    calls = []
    monkeypatch.setattr(semantic_search_service, "warm_up", lambda: calls.append(1))
    return calls


@pytest.fixture
def enabled(monkeypatch):
    from app.core.config import settings

    monkeypatch.setattr(settings, "SEMANTIC_SEARCH_ENABLED", True)


@pytest.fixture
def disabled(monkeypatch):
    from app.core.config import settings

    monkeypatch.setattr(settings, "SEMANTIC_SEARCH_ENABLED", False)


def _client():
    """The real app, so the real lifespan runs."""
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


def test_the_lifespan_warms_up_semantic_search_when_enabled(enabled, warm_up_calls):
    with _client() as client:
        assert client.get("/health").status_code == 200

    assert warm_up_calls == [1]


def test_nothing_is_warmed_up_when_semantic_search_is_disabled(
    disabled, warm_up_calls
):
    with _client() as client:
        assert client.get("/health").status_code == 200

    assert warm_up_calls == []


def test_the_warm_up_runs_once_per_lifespan(enabled, warm_up_calls):
    with _client() as client:
        # Several requests inside one lifespan must not re-trigger it.
        client.get("/health")
        client.get("/health")

    assert warm_up_calls == [1]


def test_each_lifespan_warms_up_again(enabled, warm_up_calls):
    """Entering a second time is a second application start."""
    with _client():
        pass
    with _client():
        pass

    assert warm_up_calls == [1, 1]


def test_a_failed_warm_up_is_logged_and_the_app_still_starts(
    enabled, monkeypatch, caplog
):
    from app.services import semantic_search_service

    def boom():
        raise RuntimeError("model download failed")

    monkeypatch.setattr(semantic_search_service, "warm_up", boom)

    with caplog.at_level(logging.ERROR, logger="app.main"):
        with _client() as client:
            # The app is up and serving despite the failure.
            assert client.get("/health").status_code == 200

    assert any(
        record.levelno == logging.ERROR and record.exc_info
        for record in caplog.records
    ), "the failure was not logged with its traceback"
    assert "/search/semantic" in caplog.text


def test_a_failed_warm_up_does_not_set_smart_searchs_own_flag(
    enabled, monkeypatch
):
    """
    _semantic_failed belongs to smart_search_service and is set when a
    SEARCH fails, not when startup does. Startup must leave it alone.
    """
    from app.services import semantic_search_service, smart_search_service

    monkeypatch.setattr(smart_search_service, "_semantic_failed", False)
    monkeypatch.setattr(
        semantic_search_service,
        "warm_up",
        lambda: (_ for _ in ()).throw(RuntimeError("nope")),
    )

    with _client():
        pass

    assert smart_search_service._semantic_failed is False


def test_the_lifespan_is_entered_and_exited_around_the_requests(
    enabled, warm_up_calls
):
    client_ref = _client()

    # Not yet: building the client does not start the app.
    assert warm_up_calls == []

    with client_ref as client:
        assert warm_up_calls == [1]
        assert client.get("/health").json()["status"] == "ok"

    # Exiting ran shutdown without raising; the app took no further action.
    assert warm_up_calls == [1]


def test_a_client_used_without_the_context_manager_never_starts_up(
    enabled, warm_up_calls
):
    """
    What the router suites rely on: no lifespan, so no warm-up — which is
    why those tests need no semantic-search setup.
    """
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    assert client.get("/health").status_code == 200

    assert warm_up_calls == []


def test_the_app_no_longer_registers_a_deprecated_startup_event():
    """The migration itself: on_event handlers are gone."""
    from app.main import app

    assert app.router.on_startup == []
    assert app.router.on_shutdown == []
    assert app.router.lifespan_context is not None


# ========================= the optional dependency (Phase 6, Group F)
#
# sentence-transformers lives in requirements-semantic.txt, not in
# requirements.txt, so a normal install does not have it. These tests prove
# the app does not need it — and they prove it in a subprocess with the
# import actively BLOCKED, so the result does not depend on whether this
# machine happens to have the package installed.

_IMPORT_BLOCKER = """
import sys


class _Blocked:
    '''A meta-path finder that makes sentence_transformers unimportable.'''

    PREFIX = "sentence_transformers"

    def _mine(self, name):
        return name == self.PREFIX or name.startswith(self.PREFIX + ".")

    def find_spec(self, name, path=None, target=None):
        if self._mine(name):
            raise ImportError("blocked by the test: sentence_transformers is unavailable")
        return None


sys.meta_path.insert(0, _Blocked())

# The blocker has to actually work, or the rest proves nothing.
try:
    import sentence_transformers
    print("BLOCKER_FAILED")
    raise SystemExit(1)
except ImportError:
    pass
"""


def _run_with_blocked_dependency(body, *, enabled):
    """
    Runs `body` in a fresh interpreter where importing
    sentence_transformers raises ImportError, with the feature flag set.
    """
    env = dict(
        os.environ,
        DATABASE_URL="sqlite://",
        JWT_SECRET_KEY="test-secret-key-not-for-production",
        ENVIRONMENT="test",
        DEBUG="false",
        FCM_ENABLED="false",
        SEMANTIC_SEARCH_ENABLED="true" if enabled else "false",
        PYTHONPATH=os.getcwd(),
        PYTHONIOENCODING="utf-8",
    )
    completed = subprocess.run(
        [sys.executable, "-c", _IMPORT_BLOCKER + body],
        capture_output=True,
        text=True,
        env=env,
        cwd=os.getcwd(),
        timeout=180,
    )
    assert "BLOCKER_FAILED" not in completed.stdout, "the import blocker did not work"
    assert completed.returncode == 0, (
        f"subprocess failed (rc={completed.returncode})\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr[-2000:]}"
    )
    return completed.stdout


def test_the_app_imports_and_serves_without_the_optional_dependency():
    """Requirement 1: a base install (no sentence-transformers) is enough."""
    out = _run_with_blocked_dependency(
        """
import app.main
from fastapi.testclient import TestClient

# Every router and service is imported by now, and the lifespan runs on
# entering the client. /health is used deliberately: it needs no database,
# so this proves the app came up rather than testing schema provisioning.
with TestClient(app.main.app, raise_server_exceptions=False) as client:
    print("health", client.get("/health").status_code)
print("routes", len(app.main.app.routes))
""",
        enabled=False,
    )

    assert "health 200" in out
    # The whole API surface was built, not a stripped-down app.
    assert any(
        line.startswith("routes ") and int(line.split()[1]) > 50
        for line in out.splitlines()
    ), out


def test_nothing_imports_the_optional_dependency_when_disabled():
    """
    Requirement 2: not directly, and not indirectly either — importing the
    app pulls in every router and service, and running the lifespan runs
    startup, and still nothing reaches for it.
    """
    out = _run_with_blocked_dependency(
        """
import sys
import app.main
print("after_import", "sentence_transformers" in sys.modules)

from fastapi.testclient import TestClient
with TestClient(app.main.app) as client:
    client.get("/health")
print("after_lifespan", "sentence_transformers" in sys.modules)
""",
        enabled=False,
    )

    assert "after_import False" in out
    assert "after_lifespan False" in out


def test_an_enabled_app_still_starts_when_the_optional_dependency_is_missing():
    """
    Requirement 4, at startup: the warm-up fails loudly (logged by main's
    lifespan) and the application still comes up — it does not crash, and
    it does not pretend semantic search is working.
    """
    out = _run_with_blocked_dependency(
        """
import app.main
from fastapi.testclient import TestClient

# Entering the client runs the lifespan, which calls the warm-up. It fails
# and is logged, and the app still comes up.
with TestClient(app.main.app, raise_server_exceptions=False) as client:
    print("health", client.get("/health").status_code)

# And the failure a caller would hit names the missing package and how to
# install it, rather than pretending semantic search works.
from app.core.exceptions import ServiceUnavailableError
from app.services import semantic_search_service

try:
    semantic_search_service.warm_up()
    print("raised nothing")
except ServiceUnavailableError as error:
    print("error_class", type(error).__name__)
    print("names_package", "sentence-transformers" in error.message)
    print("names_install", "pip install" in error.message)
""",
        enabled=True,
    )

    assert "health 200" in out                   # the app started regardless
    assert "raised nothing" not in out, out      # it did not fail silently
    assert "error_class ServiceUnavailableError" in out
    assert "names_package True" in out
    assert "names_install True" in out
