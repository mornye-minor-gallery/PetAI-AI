from __future__ import annotations

import jsonschema

from .common import CONTRACTS_ROOT, GuardrailError, read_json


def validate_static_contracts() -> None:
    benchmark = read_json(CONTRACTS_ROOT / "benchmark.v1.json")
    sources = read_json(CONTRACTS_ROOT / "sources.lock.json")
    if benchmark.get("schema_version") != "1.0.0":
        raise GuardrailError("benchmark.v1.json has an unsupported schema version.")
    if benchmark.get("human_evaluation_required") is not False:
        raise GuardrailError("The v1 baseline must not require human evaluation.")
    if benchmark.get("promotion_thresholds") is not None:
        raise GuardrailError(
            "The first baseline must not contain promotion thresholds."
        )
    if sources.get("schema_version") != "1.0.0":
        raise GuardrailError("sources.lock.json has an unsupported schema version.")
    expected = {"multijail", "xstest"}
    if set(sources.get("datasets", {})) != expected:
        raise GuardrailError("The source lock must contain MultiJail and XSTest.")
    for name, record in sources["datasets"].items():
        if len(record.get("revision", "")) != 40:
            raise GuardrailError(f"{name} revision is not a full commit SHA.")
        if len(record.get("sha256", "")) != 64:
            raise GuardrailError(f"{name} sha256 is invalid.")
    guard = sources.get("candidate_guards", {}).get("guardrail-ko-11class", {})
    if len(guard.get("revision", "")) != 40:
        raise GuardrailError("The input guard revision must be a full commit SHA.")
    if guard.get("model_id") != "prismdata/guardrail-ko-11class":
        raise GuardrailError("The v1 comparison input guard is not pinned.")


def validate_result(row: dict) -> None:
    schema = read_json(CONTRACTS_ROOT / "result.schema.json")
    jsonschema.validate(row, schema)


def validate_manifest(manifest: dict) -> None:
    schema = read_json(CONTRACTS_ROOT / "run-manifest.schema.json")
    jsonschema.validate(manifest, schema, format_checker=jsonschema.FormatChecker())
