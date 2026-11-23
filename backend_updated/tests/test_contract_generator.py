"""The contract sample generator is plain Python: tested here without the app."""
import json

import pytest

from tools.export_contract import SampleGenerator, build_samples

SPEC = {
    "paths": {
        "/api/v1/services/{service_id}": {
            "get": {"responses": {"200": {"content": {"application/json": {
                "schema": {"$ref": "#/components/schemas/ServiceResponse"}}}}}},
            "delete": {"responses": {"204": {"description": "deleted"}}},
        },
        "/api/v1/cities": {"get": {"responses": {"200": {"content": {"application/json": {
            "schema": {"type": "array", "items": {"type": "string"}}}}}}}},
        "/api/v1/admin/stats": {"get": {"responses": {"200": {"content": {"application/json": {
            "schema": {"$ref": "#/components/schemas/Stats"}}}}}}},
    },
    "components": {"schemas": {
        "Category": {"type": "object", "required": ["id", "name"], "properties": {
            "id": {"type": "integer"},
            "name": {"type": "string", "minLength": 2},
            "icon_name": {"anyOf": [{"type": "string"}, {"type": "null"}]}}},
        "Status": {"type": "string", "enum": ["active", "suspended"]},
        "ServiceResponse": {"type": "object", "properties": {
            "id": {"type": "integer"},
            "title": {"type": "string"},
            "long": {"type": "string", "minLength": 6},
            "short": {"type": "string", "maxLength": 2},
            "price": {"anyOf": [{"type": "number"}, {"type": "string", "pattern": "^[0-9.]+$"}]},
            "total": {"type": "string", "pattern": "^(?!^[-+.]*$)[+-]?0*\\d*\\.?\\d*$"},
            "status": {"$ref": "#/components/schemas/Status"},
            "created_at": {"type": "string", "format": "date-time"},
            "start": {"type": "string", "format": "time"},
            "latitude": {"anyOf": [{"type": "number"}, {"type": "null"}]},
            "rating": {"type": "integer", "exclusiveMinimum": 0},
            "email": {"type": "string", "format": "email"},
            "category": {"$ref": "#/components/schemas/Category"},
            "tags": {"type": "array", "items": {"type": "string"}},
            "is_remote": {"type": "boolean", "default": False}}},
        "Stats": {"type": "object", "properties": {
            "avg": {"type": "number"}, "n": {"type": "integer", "minimum": 5}}},
    }},
}


@pytest.fixture(scope="module")
def samples():
    return build_samples(SPEC)


@pytest.fixture
def full(samples):
    return samples["GET /api/v1/services/{service_id}"]["full"]


@pytest.fixture
def nulls(samples):
    return samples["GET /api/v1/services/{service_id}"]["nulls"]


def test_only_endpoints_with_a_json_body_get_samples(samples):
    assert set(samples) == {
        "GET /api/v1/services/{service_id}", "GET /api/v1/cities", "GET /api/v1/admin/stats",
    }                                                           # DELETE (204) has none


def test_decimals_become_strings_like_pydantic_serialises_them(full):
    assert full["price"] == "10.50"


def test_a_decimal_described_as_a_patterned_string_gets_a_matching_value(full):
    # pydantic documents a Decimal in a RESPONSE as {"type": "string", "pattern": "<numeric>"}
    assert full["total"] == "10.50"


def test_enums_use_their_first_value(full):
    assert full["status"] == "active"


def test_formats(full):
    assert full["created_at"] == "2026-10-05T12:00:00"
    assert full["start"] == "09:00:00"
    assert full["email"] == "user@example.com"


def test_scalars(full):
    assert full["latitude"] == 1.5
    assert full["rating"] == 1
    assert full["is_remote"] is True
    assert full["tags"] == ["text"]


def test_length_limits_are_respected(full):
    assert full["long"] == "textxx"          # padded up to minLength 6
    assert full["short"] == "te"             # cut down to maxLength 2


def test_numeric_minimums_are_respected(samples):
    assert samples["GET /api/v1/admin/stats"]["full"] == {"avg": 1.5, "n": 5}


def test_nested_refs_are_followed(full):
    assert full["category"] == {"id": 1, "name": "text", "icon_name": "text"}


def test_nulls_flavour_nulls_only_nullable_fields_recursively(nulls):
    assert nulls["latitude"] is None
    assert nulls["category"]["icon_name"] is None
    assert nulls["title"] == "text"           # non-nullable stays filled
    assert nulls["price"] == "10.50"
    assert nulls["category"]["id"] == 1


def test_array_of_strings(samples):
    assert samples["GET /api/v1/cities"]["full"] == ["text"]


def test_samples_survive_a_json_round_trip(samples):
    assert json.loads(json.dumps(samples)) == samples


def test_cycles_do_not_recurse_forever():
    spec = {"components": {"schemas": {"Node": {"type": "object", "properties": {
        "child": {"$ref": "#/components/schemas/Node"}}}}}}
    value = SampleGenerator(spec, nullable_as_null=False).make({"$ref": "#/components/schemas/Node"})
    assert isinstance(value, dict)


def test_decimals_are_repaired_against_the_real_response_model():
    """Whatever the OpenAPI says about a Decimal, the exported sample must be accepted by the model."""
    from decimal import Decimal

    from fastapi import FastAPI
    from pydantic import BaseModel

    from tools.export_contract import build_contract

    class Item(BaseModel):
        name: str
        price: Decimal

    mini_app = FastAPI()

    @mini_app.get("/items", response_model=list[Item])
    def items():
        return []

    sample = build_contract(mini_app)["samples"]["GET /items"]["full"]

    assert Decimal(sample[0]["price"]) == Decimal("10.50")
    assert sample[0]["name"] == "text"
