"""
Export the backend's API contract for the Flutter contract tests.

    cd backend_updated
    python tools/export_contract.py
    python tools/export_contract.py --copy-to "C:/path/to/service_hub/test/contract/data/contract.json"

The file it writes (default: contract/contract.json) holds two things:

  * "openapi": FastAPI's own OpenAPI document (paths, request bodies, query
    parameters, response schemas, enums) - the single source of truth.
  * "samples": for every endpoint that returns JSON, example responses built
    FROM those schemas, in two flavours:
        "full"  - every field present, optional fields filled in
        "nulls" - every field present, optional fields null
    (FastAPI sends optional fields as null by default, so "nulls" is what the
    app really receives for a sparse record.)

The backend tests check that every sample is accepted by the real response
models, and the Flutter tests feed the samples to the real Dart models.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from types import UnionType
from typing import Union, get_args, get_origin

ROOT = Path(__file__).resolve().parent.parent
HTTP_METHODS = ("get", "post", "put", "patch", "delete")
SUCCESS_STATUSES = ("200", "201")
MAX_DEPTH = 8


class SampleGenerator:
    """Builds an example JSON value for a (resolved) OpenAPI schema."""

    def __init__(self, spec: dict, nullable_as_null: bool):
        self.spec = spec
        self.nullable_as_null = nullable_as_null

    # -- helpers ---------------------------------------------------------
    def resolve(self, schema: dict) -> dict:
        while isinstance(schema, dict) and "$ref" in schema:
            name = schema["$ref"].split("/")[-1]
            schema = self.spec["components"]["schemas"][name]
        return schema

    @staticmethod
    def allows_null(schema: dict) -> bool:
        for key in ("anyOf", "oneOf"):
            if any(isinstance(a, dict) and a.get("type") == "null" for a in schema.get(key, [])):
                return True
        return schema.get("type") == "null"

    # -- generation ------------------------------------------------------
    def make(self, schema: dict, depth: int = 0):
        if depth > MAX_DEPTH:
            return None
        schema = self.resolve(schema)

        if "enum" in schema:
            return schema["enum"][0]
        if "const" in schema:
            return schema["const"]

        if "allOf" in schema:
            merged = {"type": "object", "properties": {}, "required": []}
            for part in schema["allOf"]:
                part = self.resolve(part)
                merged["properties"].update(part.get("properties", {}))
                merged["required"] += part.get("required", [])
            return self.make(merged, depth + 1)

        for key in ("anyOf", "oneOf"):
            if key in schema:
                options = [a for a in schema[key] if self.resolve(a).get("type") != "null"]
                if not options:
                    return None
                kinds = {self.resolve(a).get("type") for a in options}
                if kinds == {"number", "string"}:      # pydantic Decimal -> JSON string
                    return "10.50"
                # Not depth + 1: an anyOf is a choice between shapes, not a
                # level of nesting. Counting it spends the depth budget on
                # `T | None` and on an endpoint's `list[T] | Page[T]`, which
                # would quietly null out the deepest optional fields of an
                # opt-in-paginated endpoint's sample.
                return self.make(options[0], depth)

        kind = schema.get("type")
        if isinstance(kind, list):
            kind = next((k for k in kind if k != "null"), None)

        if kind == "object" or "properties" in schema:
            result = {}
            for name, prop in (schema.get("properties") or {}).items():
                if self.nullable_as_null and self.allows_null(self.resolve(prop)):
                    result[name] = None
                else:
                    result[name] = self.make(prop, depth + 1)
            return result
        if kind == "array":
            return [self.make(schema.get("items", {}), depth + 1)]
        if kind == "string":
            return self._string(schema)
        if kind == "integer":
            return self._integer(schema)
        if kind == "number":
            minimum = schema.get("minimum", schema.get("exclusiveMinimum"))
            return 1.5 if not isinstance(minimum, (int, float)) or minimum < 1 else float(minimum) + 0.5
        if kind == "boolean":
            return True
        if kind == "null":
            return None
        return "value"          # schema without a type (e.g. a bare `dict` response)

    @staticmethod
    def _string(schema: dict) -> str:
        formats = {
            "date-time": "2026-10-05T12:00:00",
            "date": "2026-10-05",
            "time": "09:00:00",
            "email": "user@example.com",
            "uuid": "00000000-0000-4000-8000-000000000000",
            "uri": "https://example.com/x",
            "decimal": "10.50",
            "money": "10.50",
        }
        value = formats.get(schema.get("format"), "text")

        # A `pattern` must really match (pydantic describes a Decimal in a response
        # as a string with a numeric pattern), so try a few typical values.
        pattern = schema.get("pattern")
        if pattern:
            for candidate in (value, "10.50", "1", "a", "abc123"):
                try:
                    if re.search(pattern, candidate):
                        value = candidate
                        break
                except re.error:
                    break

        minimum = schema.get("minLength", 0)
        while len(value) < minimum:
            value += "x"
        maximum = schema.get("maxLength")
        return value[:maximum] if maximum else value

    @staticmethod
    def _integer(schema: dict) -> int:
        value = 1
        if isinstance(schema.get("minimum"), (int, float)):
            value = max(value, int(schema["minimum"]))
        if isinstance(schema.get("exclusiveMinimum"), (int, float)):
            value = max(value, int(schema["exclusiveMinimum"]) + 1)
        if isinstance(schema.get("maximum"), (int, float)):
            value = min(value, int(schema["maximum"]))
        return value


def response_schema(operation: dict):
    """The JSON schema of the first 2xx response that has a JSON body, or None."""
    for status in SUCCESS_STATUSES:
        content = operation.get("responses", {}).get(status, {}).get("content", {})
        if "application/json" in content:
            return content["application/json"].get("schema")
    return None


def build_samples(spec: dict) -> dict:
    samples = {}
    for path, item in spec.get("paths", {}).items():
        for method in HTTP_METHODS:
            operation = item.get(method)
            if not operation:
                continue
            schema = response_schema(operation)
            if not schema:
                continue
            samples[f"{method.upper()} {path}"] = {
                "full": SampleGenerator(spec, nullable_as_null=False).make(schema),
                "nulls": SampleGenerator(spec, nullable_as_null=True).make(schema),
            }
    return samples


def json_routes(app):
    """(\"METHOD /path\", route) for every documented route that declares a response model."""
    from fastapi.routing import APIRoute

    for route in app.routes:
        if isinstance(route, APIRoute) and route.include_in_schema and route.response_model is not None:
            for method in sorted(route.methods - {"HEAD", "OPTIONS"}):
                yield f"{method} {route.path}", route


def _set_path(data, location, value) -> None:
    for step in location[:-1]:
        data = data[step]
    data[location[-1]] = value


def _model_for(response_model, sample):
    """
    The single response model a sample should be validated against.

    An endpoint with opt-in pagination declares two shapes - `list[X]` without
    pagination, the `Page[X]` envelope with it. No one sample can satisfy both,
    and a union reports a failure for *every* branch, so the one Decimal
    problem below would be buried next to a `model_type` complaint from the
    branch the sample was never meant to match. Narrow the union to the branch
    the sample is actually shaped like; a plain model is returned unchanged.
    """
    if get_origin(response_model) not in (Union, UnionType):
        return response_model
    wanted = list if isinstance(sample, list) else None
    for member in get_args(response_model):
        origin = get_origin(member)
        if (origin if origin is list else None) == wanted:
            return member
    return response_model


def repair_with_models(app, samples: dict) -> None:
    """
    OpenAPI describes some types loosely (a Decimal in a response, for instance),
    so a sample built from the schema alone can be rejected by the real model.
    Ask the real response models and fix the value pydantic points at. Anything
    that is NOT a Decimal problem is left alone for the backend test to report.
    """
    from pydantic import TypeAdapter, ValidationError

    for key, route in json_routes(app):
        for sample in samples.get(key, {}).values():
            adapter = TypeAdapter(_model_for(route.response_model, sample))
            for _ in range(10):
                try:
                    adapter.validate_python(sample)
                    break
                except ValidationError as exc:
                    problems = exc.errors()
                    if not problems or not all(p["type"].startswith("decimal") for p in problems):
                        break
                    for problem in problems:
                        _set_path(sample, problem["loc"], "10.50")


def build_contract(app=None) -> dict:
    if app is None:
        sys.path.insert(0, str(ROOT))
        from app.main import app as fastapi_app

        app = fastapi_app
    spec = json.loads(json.dumps(app.openapi()))       # plain, detached copy
    samples = build_samples(spec)
    repair_with_models(app, samples)
    return {"openapi": spec, "samples": samples}


def write_contract(contract: dict, *targets: Path) -> None:
    text = json.dumps(contract, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    for target in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--out", default=str(ROOT / "contract" / "contract.json"))
    parser.add_argument("--copy-to", action="append", default=[], metavar="PATH",
                        help="also write the file here (e.g. the Flutter project's test/contract/data/contract.json)")
    args = parser.parse_args()

    contract = build_contract()
    targets = [Path(args.out)] + [Path(p) for p in args.copy_to]
    write_contract(contract, *targets)

    operations = sum(1 for item in contract["openapi"]["paths"].values() for m in HTTP_METHODS if m in item)
    print(f"{operations} operations, {len(contract['samples'])} response samples")
    for target in targets:
        print("wrote", target)


if __name__ == "__main__":
    main()
