from __future__ import annotations

import subprocess
from typing import Any

from .common import REPOSITORY_ROOT, expand_path, read_json, sha256_file
from .config import RunConfig
from .contracts import validate_static_contracts
from .prompt_adapter import prompt_snapshot
from .server import server_ready
from .sources import (
    input_guard_snapshot_path,
    qwen_snapshot_path,
    verify_dataset_sources,
)


def _check(name: str, ok: bool, detail: Any) -> dict[str, Any]:
    return {"name": name, "ok": ok, "detail": detail}


def run_doctor(config: RunConfig) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    try:
        validate_static_contracts()
        checks.append(_check("contracts", True, "v1 contracts valid"))
    except Exception as error:  # noqa: BLE001 - diagnostic collector
        checks.append(_check("contracts", False, str(error)))

    model_registry = read_json(REPOSITORY_ROOT / "ai/models/runtime-models.json")
    artifact = next(
        item
        for item in model_registry["artifacts"]
        if item["id"] == config.target.model_artifact_id
    )
    model_path = expand_path(config.target.model_path)
    model_hash = sha256_file(model_path) if model_path.is_file() else None
    checks.append(
        _check(
            "target_model",
            model_hash == artifact["sha256"],
            {
                "path": str(model_path),
                "expected_sha256": artifact["sha256"],
                "actual_sha256": model_hash,
            },
        )
    )
    guard_path = input_guard_snapshot_path()
    checks.append(
        _check(
            "input_guard",
            (guard_path / "model.safetensors").is_file(),
            {
                "path": str(guard_path),
                "downloaded": (guard_path / "model.safetensors").is_file(),
            },
        )
    )

    cli = expand_path(config.target.litert_lm_cli)
    version = None
    if cli.is_file():
        result = subprocess.run(
            [str(cli), "--version"], text=True, capture_output=True, check=False
        )
        version = result.stdout.strip()
    checks.append(
        _check(
            "litert_lm_cli",
            version is not None and config.target.expected_runtime_version in version,
            {"path": str(cli), "version": version},
        )
    )

    try:
        snapshot = prompt_snapshot()
        checks.append(
            _check(
                "product_prompt_adapter",
                snapshot["topK"] == config.target.top_k
                and snapshot["topP"] == config.target.top_p,
                {
                    "configuration_id": snapshot["configurationID"],
                    "top_k": snapshot["topK"],
                    "top_p": snapshot["topP"],
                },
            )
        )
    except Exception as error:  # noqa: BLE001 - diagnostic collector
        checks.append(_check("product_prompt_adapter", False, str(error)))

    sources = verify_dataset_sources()
    checks.append(
        _check("datasets", all(v["valid"] for v in sources.values()), sources)
    )
    qwen_path = qwen_snapshot_path()
    checks.append(
        _check(
            "qwen3guard",
            (qwen_path / "config.json").is_file(),
            {
                "path": str(qwen_path),
                "downloaded": (qwen_path / "config.json").is_file(),
            },
        )
    )
    checks.append(
        _check(
            "runtime_equivalence",
            config.target.expected_runtime_version == config.target.ios_runtime_version,
            {
                "mac": config.target.expected_runtime_version,
                "ios": config.target.ios_runtime_version,
                "note": "A mismatch does not block Mac quality evaluation.",
            },
        )
    )
    checks.append(_check("server", server_ready(config.target), config.target.base_url))
    blocking = {
        "contracts",
        "target_model",
        "litert_lm_cli",
        "product_prompt_adapter",
    }
    ok = all(check["ok"] for check in checks if check["name"] in blocking)
    return {"ok": ok, "checks": checks}
