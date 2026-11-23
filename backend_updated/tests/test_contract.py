"""
Backend side of the Flutter <-> FastAPI contract.

    python tools/export_contract.py     # writes contract/contract.json

* every generated sample must be accepted by the REAL response model, so the
  Flutter tests that feed those samples to the Dart models are testing something
  the backend could really send;
* once contract/contract.json exists it must match the current API, so nobody
  changes an endpoint without regenerating the contract for the app.
"""
import json
from pathlib import Path

import pytest
from pydantic import TypeAdapter

from tools.export_contract import build_contract, json_routes

CONTRACT_FILE = Path(__file__).resolve().parent.parent / "contract" / "contract.json"


def _app():
    from app.main import app

    return app


@pytest.fixture(scope="module")
def contract():
    return build_contract()


def test_the_contract_covers_the_api(contract):
    operations = [m for item in contract["openapi"]["paths"].values() for m in item]
    assert len(operations) > 60
    assert len(contract["samples"]) > 40


def test_every_declared_response_has_a_sample(contract):
    missing = [key for key, _ in json_routes(_app()) if key not in contract["samples"]]
    assert missing == []


def test_samples_are_accepted_by_the_real_response_models(contract):
    checked = 0
    failures = []
    for key, route in json_routes(_app()):
        adapter = TypeAdapter(route.response_model)
        for flavour, sample in contract["samples"][key].items():
            try:
                adapter.validate_python(sample)
            except Exception as exc:       # noqa: BLE001 - report every problem at once
                failures.append(f"{key} [{flavour}]: {exc}")
        checked += 1
    assert checked > 40
    assert failures == [], "\n".join(failures)


def test_both_sample_flavours_exist_for_every_endpoint(contract):
    assert all(set(v) == {"full", "nulls"} for v in contract["samples"].values())


def test_the_committed_contract_matches_the_current_api(contract):
    if not CONTRACT_FILE.exists():
        pytest.skip("run `python tools/export_contract.py` once to start enforcing this")
    committed = json.loads(CONTRACT_FILE.read_text(encoding="utf-8"))
    current = json.loads(json.dumps(contract))
    assert committed == current, (
        "The API changed since contract/contract.json was written. Regenerate it and "
        "copy it to the Flutter project:\n  python tools/export_contract.py --copy-to <flutter>/test/contract/data/contract.json"
    )
