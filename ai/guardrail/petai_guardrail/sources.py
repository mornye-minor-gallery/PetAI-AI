from __future__ import annotations

import urllib.request
from pathlib import Path
from typing import Any

from huggingface_hub import snapshot_download

from .common import (
    ARTIFACTS_ROOT,
    CONTRACTS_ROOT,
    GuardrailError,
    read_json,
    sha256_file,
)


def source_lock() -> dict[str, Any]:
    return read_json(CONTRACTS_ROOT / "sources.lock.json")


def dataset_path(name: str) -> Path:
    lock = source_lock()
    record = lock["datasets"].get(name)
    if record is None:
        raise GuardrailError(f"Unknown dataset: {name}")
    return ARTIFACTS_ROOT / "sources" / name / Path(record["path"]).name


def fetch_datasets() -> dict[str, Path]:
    lock = source_lock()
    resolved: dict[str, Path] = {}
    for name, record in lock["datasets"].items():
        destination = dataset_path(name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_file() and sha256_file(destination) == record["sha256"]:
            resolved[name] = destination
            continue
        temporary = destination.with_suffix(destination.suffix + ".download")
        if temporary.exists():
            temporary.unlink()
        try:
            with urllib.request.urlopen(record["url"], timeout=60) as response:
                temporary.write_bytes(response.read())
        except Exception as error:
            temporary.unlink(missing_ok=True)
            raise GuardrailError(f"Could not download {name}: {error}") from error
        actual = sha256_file(temporary)
        if actual != record["sha256"]:
            temporary.unlink(missing_ok=True)
            raise GuardrailError(
                f"{name} hash mismatch: expected {record['sha256']}, got {actual}."
            )
        temporary.replace(destination)
        resolved[name] = destination
    return resolved


def qwen_snapshot_path() -> Path:
    return ARTIFACTS_ROOT / "models" / "qwen3guard-gen-0.6b"


def fetch_qwen3guard() -> Path:
    record = source_lock()["scorers"]["qwen3guard"]
    destination = qwen_snapshot_path()
    snapshot_download(
        repo_id=record["model_id"],
        revision=record["revision"],
        local_dir=destination,
    )
    return destination


def input_guard_snapshot_path() -> Path:
    return ARTIFACTS_ROOT / "models" / "guardrail-ko-11class"


def fetch_input_guard() -> Path:
    record = source_lock()["candidate_guards"]["guardrail-ko-11class"]
    destination = input_guard_snapshot_path()
    snapshot_download(
        repo_id=record["model_id"],
        revision=record["revision"],
        local_dir=destination,
    )
    return destination


def verify_dataset_sources() -> dict[str, dict[str, Any]]:
    lock = source_lock()
    evidence: dict[str, dict[str, Any]] = {}
    for name, record in lock["datasets"].items():
        path = dataset_path(name)
        actual = sha256_file(path) if path.is_file() else None
        evidence[name] = {
            "path": str(path),
            "present": path.is_file(),
            "expected_sha256": record["sha256"],
            "actual_sha256": actual,
            "valid": actual == record["sha256"],
        }
    return evidence
