from __future__ import annotations

import platform
import uuid
from pathlib import Path
from typing import Any

from .common import (
    CONFIGS_DIR,
    CONTRACTS_DIR,
    ToolRouteBenchError,
    git_commit,
    read_json,
    sha256_file,
    utc_now,
    write_json,
)
from .contracts import load_benchmark_contract, validate_run_manifest


def write_run_manifest(
    *,
    output_path: Path,
    track: str,
    candidate_id: str,
    dataset_path: Path,
    embeddings_path: Path,
    result_path: Path,
    holdout_lock: bool = False,
) -> Path:
    extraction_path = embeddings_path.parent / "embedding_manifest.json"
    if not extraction_path.is_file():
        raise ToolRouteBenchError("embedding extraction manifest is missing")
    extraction = read_json(extraction_path)
    if extraction["output"]["sha256"] != sha256_file(embeddings_path):
        raise ToolRouteBenchError("embedding cache differs from extraction manifest")
    model = extraction["model"]
    tokenizer = extraction["tokenizer"]
    config_path = CONFIGS_DIR / "embedding-router.pilot.v1.json"
    manifest: dict[str, Any] = {
        "benchmark_id": "toolroutebench",
        "benchmark_version": load_benchmark_contract()["benchmark_version"],
        "run_id": str(uuid.uuid4()),
        "status": "completed",
        "git_commit": git_commit(require_clean=True),
        "started_at": extraction["created_at"],
        "ended_at": utc_now(),
        "track": track,
        "candidate": {
            "candidate_id": candidate_id,
            "router_family": "embedding_similarity_multilabel",
            "config_sha256": sha256_file(config_path),
        },
        "dataset": {
            "path": str(dataset_path.resolve()),
            "sha256": sha256_file(dataset_path),
        },
        "contracts": [
            {
                "path": str((CONTRACTS_DIR / "benchmark.v1.json").resolve()),
                "sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
            },
            {
                "path": str((CONTRACTS_DIR / "tools.v1.json").resolve()),
                "sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
            },
        ],
        "models": [
            {
                "role": "embedder",
                "model_id": model["id"],
                "artifact_sha256": model["sha256"],
            },
            {
                "role": "tokenizer",
                "model_id": tokenizer["id"],
                "artifact_sha256": tokenizer["sha256"],
            },
        ],
        "runtime": {
            "name": extraction["runtime"]["name"],
            "version": extraction["runtime"]["version"],
            "backend": extraction["runtime"]["backend"],
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
    }
    if holdout_lock:
        manifest["holdout_lock"] = {
            "candidate_locked": True,
            "dataset_sha256_locked": True,
            "reused_after_tuning": False,
        }
    write_json(output_path, manifest)
    validate_run_manifest(output_path)
    return output_path.resolve()
