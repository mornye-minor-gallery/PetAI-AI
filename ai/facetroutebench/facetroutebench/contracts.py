from __future__ import annotations

from collections import Counter
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from .common import CONTRACTS_DIR, FacetRouteBenchError, final_user_text, read_json


def load_benchmark_contract(path: Path | None = None) -> dict[str, Any]:
    value = read_json(path or CONTRACTS_DIR / "benchmark.v1.json")
    if value.get("benchmark_id") != "facetroutebench":
        raise FacetRouteBenchError("unsupported benchmark contract")
    if value.get("counts", {}).get("fixed_record_total") != 1920:
        raise FacetRouteBenchError("benchmark contract must contain 1,920 records")
    return value


def load_route_contract(path: Path | None = None) -> dict[str, Any]:
    value = read_json(path or CONTRACTS_DIR / "routes.v1.json")
    route_order = value.get("route_order")
    routes = value.get("routes")
    if not isinstance(route_order, list) or len(route_order) != 20:
        raise FacetRouteBenchError("route contract must define 20 ordered routes")
    if not isinstance(routes, dict) or set(routes) != set(route_order):
        raise FacetRouteBenchError("route map and route_order must match")
    if route_order[-1] != "GENERAL":
        raise FacetRouteBenchError("GENERAL must be the final route")
    return value


def validate_record_schema(
    record: dict[str, Any], schema_path: Path | None = None
) -> None:
    try:
        import jsonschema
    except ImportError as error:
        raise FacetRouteBenchError(
            "jsonschema is required; run this command through `uv run`"
        ) from error
    schema = read_json(schema_path or CONTRACTS_DIR / "dataset.schema.json")
    try:
        jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(record)
    except jsonschema.ValidationError as error:
        location = "/".join(str(item) for item in error.absolute_path)
        raise FacetRouteBenchError(
            f"dataset schema violation at {location or '<root>'}: {error.message}"
        ) from error


def validate_record_semantics(record: dict[str, Any]) -> None:
    routes = load_route_contract()["routes"]
    route = routes[record["gold_route_id"]]
    if record["facet_id"] != route["facet_id"]:
        raise FacetRouteBenchError(
            f"{record['case_id']}: facet does not match gold route"
        )
    messages = record["messages"]
    roles = [message["role"] for message in messages]
    expected = [
        "user" if index % 2 == 0 else "assistant" for index in range(len(messages))
    ]
    if roles != expected:
        raise FacetRouteBenchError(
            f"{record['case_id']}: messages must alternate from user to final user"
        )
    if record["track"] == "context_challenge" and not 3 <= len(messages) <= 7:
        raise FacetRouteBenchError(
            f"{record['case_id']}: context must fit the app's six-turn history window"
        )
    if (
        record["difficulty"] == "neighbor"
        and record.get("neighbor_route_id") not in route["neighbor_route_ids"]
    ):
        raise FacetRouteBenchError(
            f"{record['case_id']}: invalid contracted neighbor route"
        )
    contrast_route = record.get("contrast_route_id")
    if record["split"] == "authoring" and record["difficulty"] == "hard_negative":
        if contrast_route not in routes or contrast_route == "GENERAL":
            raise FacetRouteBenchError(
                f"{record['case_id']}: authoring hard negative needs a specialist contrast route"
            )
    elif contrast_route is not None:
        raise FacetRouteBenchError(
            f"{record['case_id']}: contrast route is only valid for authoring hard negatives"
        )


def validate_dataset_counts(
    records: Iterable[dict[str, Any]],
    benchmark: dict[str, Any],
) -> None:
    records = list(records)
    split_counts = Counter(record["split"] for record in records)
    expected = {
        "authoring": benchmark["counts"]["authoring"]["total"],
        "dev": benchmark["counts"]["dev"]["total"],
        "frozen": benchmark["counts"]["frozen"]["total"],
        "context_challenge": benchmark["counts"]["context_challenge"]["total"],
    }
    if split_counts != Counter(expected):
        raise FacetRouteBenchError(
            f"dataset split counts mismatch: expected={expected}, actual={dict(split_counts)}"
        )

    routes = load_route_contract()["route_order"]
    specialists = routes[:-1]
    for split in ("authoring", "dev", "frozen"):
        expected_per_difficulty = 4 if split == "authoring" else 8
        for route in specialists:
            for difficulty in ("direct", "natural", "neighbor"):
                actual = sum(
                    1
                    for record in records
                    if record["split"] == split
                    and record["gold_route_id"] == route
                    and record["difficulty"] == difficulty
                )
                if actual != expected_per_difficulty:
                    raise FacetRouteBenchError(
                        f"{split}/{route}/{difficulty}: expected "
                        f"{expected_per_difficulty}, found {actual}"
                    )
    for difficulty in ("general", "hard_negative"):
        actual = sum(
            1
            for record in records
            if record["split"] == "authoring"
            and record["gold_route_id"] == "GENERAL"
            and record["difficulty"] == difficulty
        )
        if actual != 120:
            raise FacetRouteBenchError(
                f"authoring/GENERAL/{difficulty}: expected 120, found {actual}"
            )
    for split in ("dev", "frozen"):
        for difficulty in ("general", "hard_negative"):
            actual = sum(
                1
                for record in records
                if record["split"] == split
                and record["gold_route_id"] == "GENERAL"
                and record["difficulty"] == difficulty
            )
            if actual != 120:
                raise FacetRouteBenchError(
                    f"{split}/GENERAL/{difficulty}: expected 120, found {actual}"
                )
    for route in routes:
        actual = sum(
            1
            for record in records
            if record["split"] == "context_challenge"
            and record["gold_route_id"] == route
        )
        if actual != 3:
            raise FacetRouteBenchError(
                f"context_challenge/{route}: expected 3, found {actual}"
            )

    domain_allocations = benchmark["authoring"]["domain_allocation_by_cell_size"]
    grouped_cells: Counter[tuple[str, str, str]] = Counter(
        (record["split"], record["gold_route_id"], record["difficulty"])
        for record in records
    )
    for cell, cell_count in grouped_cells.items():
        expected_domains = domain_allocations[str(cell_count)]
        actual_domains = Counter(
            record["domain"]
            for record in records
            if (record["split"], record["gold_route_id"], record["difficulty"])
            == cell
        )
        if actual_domains != Counter(expected_domains):
            raise FacetRouteBenchError(
                f"{cell}: expected domains {expected_domains}, "
                f"found {dict(actual_domains)}"
            )

    ids = [record["case_id"] for record in records]
    if len(ids) != len(set(ids)):
        raise FacetRouteBenchError("dataset contains duplicate case IDs")
    for record in records:
        final_user_text(record["messages"])
        validate_record_semantics(record)
