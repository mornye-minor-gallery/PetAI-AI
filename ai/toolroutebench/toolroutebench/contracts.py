from __future__ import annotations

import itertools
import json
import re
from collections import Counter, defaultdict
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from .common import (
    CONFIGS_DIR,
    CONTRACTS_DIR,
    REPOSITORY_ROOT,
    ToolRouteBenchError,
    read_json,
    sha256_file,
)


POSITIVE_DIFFICULTIES = ("direct", "natural", "missing_parameter", "noisy")
NORMAL_DIFFICULTIES = (
    "mention_or_past",
    "negation",
    "capability_or_meta",
    "quoted_or_third_party",
    "hypothetical_or_wish",
    "semantic_boundary",
)


def load_tool_contract(path: Path | None = None) -> dict[str, Any]:
    value = read_json(path or CONTRACTS_DIR / "tools.v1.json")
    order = value.get("tool_order")
    tools = value.get("tools")
    if not isinstance(order, list) or len(order) != 7 or len(set(order)) != 7:
        raise ToolRouteBenchError("tool contract must define 7 unique ordered tools")
    if not isinstance(tools, dict) or set(tools) != set(order):
        raise ToolRouteBenchError("tool map and tool_order must match")
    return value


def load_benchmark_contract(path: Path | None = None) -> dict[str, Any]:
    value = read_json(path or CONTRACTS_DIR / "benchmark.v1.json")
    if value.get("benchmark_id") != "toolroutebench":
        raise ToolRouteBenchError("unsupported benchmark contract")
    if value.get("counts", {}).get("fixed_record_total") != 615:
        raise ToolRouteBenchError("Pilot contract must contain 615 fixed records")
    return value


def _load_model_registry() -> dict[str, dict[str, Any]]:
    registry = read_json(REPOSITORY_ROOT / "ai/models/runtime-models.json")
    artifacts = registry.get("artifacts")
    if not isinstance(artifacts, list):
        raise ToolRouteBenchError("runtime model registry must contain artifacts")
    return {item["id"]: item for item in artifacts}


def validate_contracts() -> None:
    tool_contract = load_tool_contract()
    tools = tool_contract["tool_order"]
    benchmark = load_benchmark_contract()
    config = read_json(CONFIGS_DIR / "embedding-router.pilot.v1.json")

    swift_contract_path = REPOSITORY_ROOT / tool_contract["source"]
    try:
        swift_source = swift_contract_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ToolRouteBenchError(
            f"could not read Swift Tool contract: {swift_contract_path}"
        ) from error
    native_tool_kind = re.search(
        r"public enum NativeToolKind[^\{]*\{(?P<body>.*?)\n\}",
        swift_source,
        re.DOTALL,
    )
    if native_tool_kind is None:
        raise ToolRouteBenchError("Swift source is missing NativeToolKind")
    swift_tools = re.findall(
        r'^\s*case\s+\w+\s*=\s*"([a-z0-9_]+)"',
        native_tool_kind.group("body"),
        re.MULTILINE,
    )
    if swift_tools != tools:
        raise ToolRouteBenchError(
            f"Tool contract differs from Swift enum: contract={tools}, swift={swift_tools}"
        )

    regex_contract = tool_contract.get("regex_baseline")
    if not isinstance(regex_contract, dict):
        raise ToolRouteBenchError("Tool contract is missing Regex baseline provenance")
    regex_source = REPOSITORY_ROOT / regex_contract["source"]
    if sha256_file(regex_source) != regex_contract.get("source_sha256"):
        raise ToolRouteBenchError(
            "Swift Regex Router changed without reviewing the Python baseline port"
        )

    if benchmark["counts"]["authoring"]["tool_count"] != len(tools):
        raise ToolRouteBenchError("authoring tool count does not match tool contract")
    if benchmark["arms"]["representations"] != config["representations"]:
        raise ToolRouteBenchError("representation grid differs between contract and config")
    if benchmark["arms"]["prototype_aggregations"] != config["prototype_aggregations"]:
        raise ToolRouteBenchError("aggregation grid differs between contract and config")
    if benchmark["arms"]["normal_decisions"] != config["normal_decisions"]:
        raise ToolRouteBenchError("NORMAL decision grid differs between contract and config")
    if benchmark["arms"]["threshold_structures"] != config["threshold_structures"]:
        raise ToolRouteBenchError("threshold grid differs between contract and config")

    registry = _load_model_registry()
    embedding = benchmark["embedding"]
    for role in ("model", "tokenizer"):
        item = registry.get(embedding[f"{role}_id"])
        if item is None:
            raise ToolRouteBenchError(f"registry is missing {role} artifact")
        if item["sha256"] != embedding[f"{role}_sha256"]:
            raise ToolRouteBenchError(f"{role} SHA-256 differs from runtime registry")
    if registry[embedding["model_id"]]["revision"] != embedding["model_revision"]:
        raise ToolRouteBenchError("embedding model revision differs from runtime registry")

    schema_paths = [
        CONTRACTS_DIR / "dataset.schema.json",
        CONTRACTS_DIR / "run-manifest.schema.json",
        REPOSITORY_ROOT
        / "ai/toolroutebench/schemas/generator-output.schema.json",
        REPOSITORY_ROOT
        / "ai/toolroutebench/schemas/validator-output.schema.json",
    ]
    for schema_path in schema_paths:
        schema = read_json(schema_path)
        try:
            import jsonschema
        except ImportError as error:
            raise ToolRouteBenchError(
                "jsonschema is required; run validation through `uv run`"
            ) from error
        jsonschema.Draft202012Validator.check_schema(schema)

    threshold_tuning = config.get("threshold_tuning")
    if threshold_tuning != {
        "cv_folds": 5,
        "shrinkage": 0.5,
        "candidate_values": "observed_score_midpoints",
    }:
        raise ToolRouteBenchError("threshold tuning contract changed unexpectedly")


def validate_record_schema(record: dict[str, Any]) -> None:
    try:
        import jsonschema
    except ImportError as error:
        raise ToolRouteBenchError(
            "jsonschema is required; run validation through `uv run`"
        ) from error
    schema = read_json(CONTRACTS_DIR / "dataset.schema.json")
    try:
        jsonschema.Draft202012Validator(schema).validate(record)
    except jsonschema.ValidationError as error:
        location = "/".join(str(item) for item in error.absolute_path)
        raise ToolRouteBenchError(
            f"dataset schema violation at {location or '<root>'}: {error.message}"
        ) from error


def validate_expression_family_partition(records: Iterable[dict[str, Any]]) -> None:
    splits_by_family: dict[str, set[str]] = defaultdict(set)
    for record in records:
        if record["split"] == "regression":
            continue
        splits_by_family[record["expression_family_id"]].add(record["split"])
    leaked = {
        family: sorted(splits)
        for family, splits in splits_by_family.items()
        if len(splits) > 1
    }
    if leaked:
        raise ToolRouteBenchError(f"expression families cross splits: {leaked}")


def validate_dataset(
    records: Iterable[dict[str, Any]], *, profile: str = "full"
) -> None:
    records = list(records)
    if profile not in {"full", "development", "holdout"}:
        raise ToolRouteBenchError(f"unknown dataset validation profile: {profile}")
    for record in records:
        validate_record_schema(record)
        expected_track = {
            "authoring": "single_tool",
            "dev": "single_tool",
            "holdout": "single_tool",
            "multilabel_challenge": "multi_label",
            "regression": "regression",
        }[record["split"]]
        if record["track"] != expected_track:
            raise ToolRouteBenchError(
                f"{record['case_id']}: split {record['split']} requires track {expected_track}"
            )

    case_ids = [record["case_id"] for record in records]
    if len(case_ids) != len(set(case_ids)):
        raise ToolRouteBenchError("dataset contains duplicate case IDs")
    validate_expression_family_partition(records)

    benchmark = load_benchmark_contract()
    tools = load_tool_contract()["tool_order"]
    fixed = [record for record in records if record["split"] != "regression"]
    expected_splits = Counter(
        {
            "full": {
                "authoring": benchmark["counts"]["authoring"]["total"],
                "dev": benchmark["counts"]["dev"]["total"],
                "holdout": benchmark["counts"]["holdout"]["total"],
                "multilabel_challenge": benchmark["counts"][
                    "multilabel_challenge"
                ]["total"],
            },
            "development": {
                "authoring": benchmark["counts"]["authoring"]["total"],
                "dev": benchmark["counts"]["dev"]["total"],
            },
            "holdout": {
                "holdout": benchmark["counts"]["holdout"]["total"],
            },
        }[profile]
    )
    actual_splits = Counter(record["split"] for record in fixed)
    if actual_splits != expected_splits:
        raise ToolRouteBenchError(
            f"dataset split counts mismatch: expected={dict(expected_splits)}, "
            f"actual={dict(actual_splits)}"
        )

    if profile in {"full", "development"}:
        authoring_positive = benchmark["counts"]["authoring"]["positive_per_tool"]
        authoring_normal = benchmark["counts"]["authoring"][
            "contrast_normal_per_tool"
        ]
        for tool in tools:
            for difficulty, expected in authoring_positive.items():
                actual = sum(
                    record["split"] == "authoring"
                    and record["difficulty"] == difficulty
                    and record["gold_tool_ids"] == [tool]
                    for record in fixed
                )
                if actual != expected:
                    raise ToolRouteBenchError(
                        f"authoring/{tool}/{difficulty}: expected {expected}, found {actual}"
                    )
            for difficulty, expected in authoring_normal.items():
                actual = sum(
                    record["split"] == "authoring"
                    and record["difficulty"] == difficulty
                    and record["gold_tool_ids"] == []
                    and record.get("contrast_tool_id") == tool
                    for record in fixed
                )
                if actual != expected:
                    raise ToolRouteBenchError(
                        f"authoring/NORMAL/{tool}/{difficulty}: expected {expected}, found {actual}"
                    )

    evaluated_splits = {
        "full": ("dev", "holdout"),
        "development": ("dev",),
        "holdout": ("holdout",),
    }[profile]
    for split in evaluated_splits:
        contract = benchmark["counts"][split]
        for tool in tools:
            for difficulty, expected in contract["positive_per_tool"].items():
                actual = sum(
                    record["split"] == split
                    and record["difficulty"] == difficulty
                    and record["gold_tool_ids"] == [tool]
                    for record in fixed
                )
                if actual != expected:
                    raise ToolRouteBenchError(
                        f"{split}/{tool}/{difficulty}: expected {expected}, found {actual}"
                    )
        for difficulty in NORMAL_DIFFICULTIES:
            actual = sum(
                record["split"] == split
                and record["difficulty"] == difficulty
                and record["gold_tool_ids"] == []
                for record in fixed
            )
            if actual != contract["normal_per_difficulty"]:
                raise ToolRouteBenchError(
                    f"{split}/NORMAL/{difficulty}: expected "
                    f"{contract['normal_per_difficulty']}, found {actual}"
                )

    if profile != "full":
        return

    challenge = [
        record for record in fixed if record["split"] == "multilabel_challenge"
    ]
    expected_pairs = {tuple(pair) for pair in itertools.combinations(tools, 2)}
    pair_difficulties: dict[tuple[str, str], Counter[str]] = defaultdict(Counter)
    order = {tool: index for index, tool in enumerate(tools)}
    for record in challenge:
        pair = tuple(sorted(record["gold_tool_ids"], key=order.__getitem__))
        pair_difficulties[pair][record["difficulty"]] += 1
    if set(pair_difficulties) != expected_pairs:
        raise ToolRouteBenchError("multilabel challenge does not cover all 21 tool pairs")
    expected_per_pair = Counter(
        benchmark["counts"]["multilabel_challenge"]["per_pair"]
    )
    for pair, counts in pair_difficulties.items():
        if counts != expected_per_pair:
            raise ToolRouteBenchError(
                f"multilabel pair {pair}: expected {dict(expected_per_pair)}, "
                f"found {dict(counts)}"
            )


def validate_development_dataset(records: Iterable[dict[str, Any]]) -> None:
    validate_dataset(records, profile="development")


def validate_holdout_dataset(records: Iterable[dict[str, Any]]) -> None:
    validate_dataset(records, profile="holdout")


def validate_run_manifest(path: Path) -> None:
    try:
        import jsonschema
    except ImportError as error:
        raise ToolRouteBenchError(
            "jsonschema is required; run validation through `uv run`"
        ) from error
    schema = read_json(CONTRACTS_DIR / "run-manifest.schema.json")
    manifest = read_json(path)
    try:
        jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(manifest)
    except jsonschema.ValidationError as error:
        location = "/".join(str(item) for item in error.absolute_path)
        raise ToolRouteBenchError(
            f"run manifest violation at {location or '<root>'}: {error.message}"
        ) from error
