from __future__ import annotations

import platform
import subprocess
from pathlib import Path
from typing import Any

from .common import (
    CONTRACTS_DIR,
    REPO_ROOT,
    ROOT,
    FacetRouteBenchError,
    read_json,
    sha256_file,
    utc_now,
    write_json,
)
from .contracts import load_benchmark_contract


def git_commit() -> str:
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if status:
        raise FacetRouteBenchError(
            "benchmark runs require a clean Git worktree; commit the harness or dataset first"
        )
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def validate_run_manifest(value: dict[str, Any]) -> None:
    try:
        import jsonschema
    except ImportError as error:
        raise FacetRouteBenchError(
            "jsonschema is required; run through `uv run`"
        ) from error
    schema = read_json(CONTRACTS_DIR / "run-manifest.schema.json")
    try:
        jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(value)
    except jsonschema.ValidationError as error:
        location = "/".join(str(item) for item in error.absolute_path)
        raise FacetRouteBenchError(
            f"run manifest violation at {location or '<root>'}: {error.message}"
        ) from error


def write_validated_manifest(path: Path, value: dict[str, Any]) -> Path:
    validate_run_manifest(value)
    write_json(path, value)
    return path.resolve()


def embedding_run_manifest(
    *,
    run_id: str,
    track: str,
    candidate_id: str,
    dataset_path: Path,
    record_count: int,
    dataset_version: str,
    embeddings_path: Path,
    result_path: Path,
    started_at: str,
    notes: str,
) -> dict[str, Any]:
    extraction_path = embeddings_path.parent / "embedding_manifest.json"
    extraction = read_json(extraction_path)
    if extraction["output"]["sha256"] != sha256_file(embeddings_path):
        raise FacetRouteBenchError(
            "embedding cache SHA does not match extraction manifest"
        )
    config_path = ROOT / "configs/embedding-router.v1.json"
    config = read_json(config_path)
    expected_config = {
        "router_family": "embedding_similarity",
        "model_id": "litert-community/embeddinggemma-300m-seq256-mixed-precision",
        "model_revision": "870cbe05ef460385363c6b574c851ae5d8989ce3",
        "sequence_length": 256,
        "dimension": 768,
        "prefix": "task: classification | query: ",
        "similarity": "cosine",
        "prototype_aggregation": "max_similarity",
        "decision_rules": [
            "single_global_top1_threshold",
            "specialist_vs_general_top1",
        ],
        "general_prototype_count": 240,
        "top1_top2_margin_enabled": False,
    }
    if config != expected_config:
        raise FacetRouteBenchError(
            "Embedding config violates the locked router contract"
        )
    model = extraction["model"]
    runtime = extraction["runtime"]
    benchmark_version = load_benchmark_contract()["benchmark_version"]
    return {
        "benchmark_id": "facetroutebench",
        "benchmark_version": benchmark_version,
        "run_id": run_id,
        "status": "completed",
        "git_commit": git_commit(),
        "started_at": started_at,
        "ended_at": utc_now(),
        "track": track,
        "candidate": {
            "candidate_id": candidate_id,
            "router_family": "embedding_similarity",
            "config_path": str(config_path.resolve()),
            "config_sha256": sha256_file(config_path),
        },
        "dataset": {
            "path": str(dataset_path.resolve()),
            "version": dataset_version,
            "record_count": record_count,
            "sha256": sha256_file(dataset_path),
        },
        "contracts": [
            {
                "path": str((CONTRACTS_DIR / "routes.v1.json").resolve()),
                "sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
            },
            {
                "path": str((CONTRACTS_DIR / "benchmark.v1.json").resolve()),
                "sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
            },
        ],
        "models": [
            {
                "role": "embedder",
                "model_id": model["id"],
                "artifact_sha256": model["sha256"],
                "checkpoint_lineage": model["revision"],
                "quantization": "mixed-precision-tflite-registry-artifact",
            }
        ],
        "runtime": {
            "name": runtime["name"],
            "version": runtime["version"],
            "backend": runtime["backend"].lower(),
        },
        "hardware": {
            "platform": "macos",
            "device_model": platform.machine(),
            "os_version": platform.mac_ver()[0] or platform.platform(),
        },
        "result": {
            "path": str(result_path.resolve()),
            "sha256": sha256_file(result_path),
        },
        "notes": notes,
    }
