#!/usr/bin/env python3
"""Export the frozen FacetRouteBench v2 candidate as an app resource."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "petai-scene-embedding-router-v1"
ARTIFACT_ID = "facetroutebench-v2-retrospective"
MODEL_ID = "litert-community/embeddinggemma-300m-seq256-mixed-precision"
MODEL_REVISION = "870cbe05ef460385363c6b574c851ae5d8989ce3"
MODEL_SHA256 = "37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5"
TOKENIZER_SHA256 = "d6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7"
CLASSIFICATION_PREFIX = "task: classification | query: "
DIMENSION = 768


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def load_prototypes(path: Path) -> list[dict[str, Any]]:
    prototypes: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, start=1):
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("kind") != "prototype":
                continue
            vector = record.get("embedding")
            if not isinstance(vector, list) or len(vector) != DIMENSION:
                raise ValueError(f"invalid prototype dimension at line {line_number}")
            values = [float(value) for value in vector]
            if not all(math.isfinite(value) for value in values):
                raise ValueError(f"non-finite prototype at line {line_number}")
            prototypes.append(
                {
                    "case_id": record["case_id"],
                    "route_id": record["route_id"],
                    "text": record["text"],
                    "embedding": values,
                }
            )
    return prototypes


def export(args: argparse.Namespace) -> None:
    routes_contract = load_json(args.routes)
    comparison = load_json(args.comparison)
    prototypes = load_prototypes(args.embeddings)

    route_order = [
        route_id
        for route_id in routes_contract["route_order"]
        if route_id != "GENERAL"
    ]
    strategy = comparison["strategies"]["per_route_one_vs_rest_threshold"]
    thresholds = strategy["refit_thresholds"]
    if strategy["selected_arbitration"] != "normalized_margin":
        raise ValueError("selected arbitration must be normalized_margin")
    if set(thresholds) != set(route_order):
        raise ValueError("threshold routes do not match the route contract")

    grouped: dict[str, list[dict[str, Any]]] = {route_id: [] for route_id in route_order}
    for prototype in prototypes:
        route_id = prototype["route_id"]
        if route_id not in grouped:
            raise ValueError(f"unexpected prototype route: {route_id}")
        grouped[route_id].append(prototype)
    for route_id in route_order:
        grouped[route_id].sort(key=lambda item: item["case_id"])
        if len(grouped[route_id]) != 12:
            raise ValueError(f"{route_id} must contain exactly 12 prototypes")

    args.output_manifest.parent.mkdir(parents=True, exist_ok=True)
    args.output_vectors.parent.mkdir(parents=True, exist_ok=True)

    route_entries: list[dict[str, Any]] = []
    vector_offset = 0
    with args.output_vectors.open("wb") as stream:
        for route_id in route_order:
            route_prototypes = grouped[route_id]
            route_entries.append(
                {
                    "route_id": route_id,
                    "threshold": float(thresholds[route_id]),
                    "prototype_offset": vector_offset,
                    "prototype_count": len(route_prototypes),
                    "prototypes": [
                        {
                            "case_id": item["case_id"],
                            "text": item["text"],
                        }
                        for item in route_prototypes
                    ],
                }
            )
            for prototype in route_prototypes:
                stream.write(struct.pack(f"<{DIMENSION}f", *prototype["embedding"]))
                vector_offset += 1

    if vector_offset != 228:
        raise ValueError(f"expected 228 prototypes, found {vector_offset}")

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "artifact_id": ARTIFACT_ID,
        "status": "experimental_retrospective",
        "model": {
            "id": MODEL_ID,
            "revision": MODEL_REVISION,
            "sha256": MODEL_SHA256,
            "tokenizer_sha256": TOKENIZER_SHA256,
            "classification_prefix": CLASSIFICATION_PREFIX,
            "dimension": DIMENSION,
        },
        "decision": {
            "similarity": "cosine",
            "prototype_aggregation": "max_similarity",
            "arbitration": "normalized_margin",
            "default_route": "GENERAL",
            "tie_break": "normalized_margin_then_score_then_route_order",
        },
        "vectors": {
            "file": args.output_vectors.name,
            "encoding": "float32_little_endian",
            "prototype_count": vector_offset,
            "sha256": sha256(args.output_vectors),
        },
        "route_order": route_order,
        "routes": route_entries,
        "provenance": {
            "route_contract_sha256": sha256(args.routes),
            "embedding_source_sha256": sha256(args.embeddings),
            "threshold_comparison_sha256": sha256(args.comparison),
            "selected_shrinkage": float(strategy["selected_shrinkage"]),
            "strategy_selection": strategy["strategy_selection"],
        },
    }
    args.output_manifest.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--routes", type=Path, required=True)
    parser.add_argument("--embeddings", type=Path, required=True)
    parser.add_argument("--comparison", type=Path, required=True)
    parser.add_argument("--output-manifest", type=Path, required=True)
    parser.add_argument("--output-vectors", type=Path, required=True)
    export(parser.parse_args())


if __name__ == "__main__":
    main()
