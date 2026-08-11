from __future__ import annotations

import json
import platform
import statistics
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .common import (
    CONTRACTS_DIR,
    REPOSITORY_ROOT,
    ToolRouteBenchError,
    append_jsonl,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
)
from .contracts import (
    load_benchmark_contract,
    load_tool_contract,
    validate_holdout_dataset,
    validate_run_manifest,
)
from .evaluation import multilabel_metrics


NORMAL_LABEL = "NORMAL"


@dataclass(frozen=True)
class ChatGeneration:
    text: str
    elapsed_ms: float
    response_model_id: str
    prompt_tokens: int | None
    completion_tokens: int | None


def require_loopback_base_url(base_url: str) -> str:
    parsed = urlparse(base_url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"}:
        raise ToolRouteBenchError(
            "Gemma evaluation only permits a loopback HTTP LiteRT-LM server"
        )
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ToolRouteBenchError("Gemma server URL must not contain a path or query")
    return base_url.rstrip("/")


class LiteRTLMOpenAIClient:
    def __init__(self, *, base_url: str, timeout_seconds: float) -> None:
        if timeout_seconds <= 0:
            raise ToolRouteBenchError("Gemma request timeout must be positive")
        self._base_url = require_loopback_base_url(base_url)
        self._timeout_seconds = timeout_seconds

    def model_ids(self) -> set[str]:
        request = urllib.request.Request(f"{self._base_url}/v1/models")
        response = self._request_json(request)
        rows = response.get("data")
        if not isinstance(rows, list):
            raise ToolRouteBenchError("LiteRT-LM model response has no data array")
        model_ids = {
            row.get("id")
            for row in rows
            if isinstance(row, dict) and isinstance(row.get("id"), str)
        }
        if not model_ids:
            raise ToolRouteBenchError("LiteRT-LM server returned no models")
        return model_ids

    def generate(
        self,
        *,
        model_id: str,
        system_prompt: str,
        user_message: str,
        temperature: float,
        top_p: float,
        max_tokens: int,
    ) -> ChatGeneration:
        payload = json.dumps(
            {
                "model": model_id,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                "temperature": temperature,
                "top_p": top_p,
                "max_tokens": max_tokens,
                "stream": False,
            },
            ensure_ascii=False,
            allow_nan=False,
        ).encode()
        request = urllib.request.Request(
            f"{self._base_url}/v1/chat/completions",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        started = time.perf_counter()
        response = self._request_json(request)
        elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
        try:
            text = response["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as error:
            raise ToolRouteBenchError(
                "LiteRT-LM chat response has no assistant content"
            ) from error
        if not isinstance(text, str):
            raise ToolRouteBenchError("LiteRT-LM assistant content is not text")
        response_model_id = response.get("model")
        if not isinstance(response_model_id, str):
            raise ToolRouteBenchError("LiteRT-LM chat response has no model ID")
        usage = response.get("usage")
        prompt_tokens = (
            usage.get("prompt_tokens") if isinstance(usage, dict) else None
        )
        completion_tokens = (
            usage.get("completion_tokens") if isinstance(usage, dict) else None
        )
        return ChatGeneration(
            text=text,
            elapsed_ms=elapsed_ms,
            response_model_id=response_model_id,
            prompt_tokens=prompt_tokens if isinstance(prompt_tokens, int) else None,
            completion_tokens=(
                completion_tokens if isinstance(completion_tokens, int) else None
            ),
        )

    def _request_json(self, request: urllib.request.Request) -> dict[str, Any]:
        try:
            with urllib.request.urlopen(
                request, timeout=self._timeout_seconds
            ) as response:
                value = json.loads(response.read().decode())
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            raise ToolRouteBenchError(f"LiteRT-LM HTTP request failed: {error}") from error
        if not isinstance(value, dict):
            raise ToolRouteBenchError("LiteRT-LM HTTP response must be a JSON object")
        return value


def parse_prompt_route(raw_text: str, tool_ids: list[str]) -> tuple[list[str], str]:
    labels = [NORMAL_LABEL, *tool_ids]
    normalized = raw_text.strip()
    strict_match = next(
        (label for label in labels if normalized.casefold() == label.casefold()),
        None,
    )
    if strict_match is not None:
        return ([] if strict_match == NORMAL_LABEL else [strict_match], "strict")

    return [], "fallback"


def verify_gemma_artifact(model_path: Path, registry_id: str) -> dict[str, Any]:
    registry = read_json(REPOSITORY_ROOT / "ai/models/runtime-models.json")
    expected = next(
        (item for item in registry["artifacts"] if item["id"] == registry_id),
        None,
    )
    if expected is None:
        raise ToolRouteBenchError(f"runtime registry has no model: {registry_id}")
    resolved = model_path.expanduser().resolve()
    if not resolved.is_file():
        raise ToolRouteBenchError(f"Gemma artifact was not found: {resolved}")
    if resolved.stat().st_size != expected["bytes"]:
        raise ToolRouteBenchError("Gemma artifact byte length differs from registry")
    if sha256_file(resolved) != expected["sha256"]:
        raise ToolRouteBenchError("Gemma artifact SHA-256 differs from registry")
    return expected


def _load_locked_config(config_path: Path, prompt_path: Path) -> dict[str, Any]:
    config = read_json(config_path)
    expected = {
        "candidate_id": "gemma-e2b-prompt-router-retrospective-v1",
        "router_family": "gemma_prompt_classifier",
        "model_registry_id": "gemma-e2b-it",
        "server_model_id": "gemma4-e2b",
        "temperature": 0.0,
        "top_p": 1.0,
        "max_tokens": 32,
        "invalid_or_multiple_label_fallback": NORMAL_LABEL,
        "evaluation_scope": "pilot_holdout_retrospective",
    }
    if any(config.get(key) != value for key, value in expected.items()):
        raise ToolRouteBenchError("Gemma config violates the retrospective contract")
    configured_prompt = (config_path.parent / config["system_prompt"]).resolve()
    if configured_prompt != prompt_path.resolve():
        raise ToolRouteBenchError("Gemma prompt differs from configured system_prompt")
    if not prompt_path.is_file():
        raise ToolRouteBenchError(f"Gemma prompt was not found: {prompt_path}")
    return config


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * percentile) - 1))
    return round(ordered[index], 3)


def _quality_slices(
    records: list[dict[str, Any]], predictions: dict[str, list[str]]
) -> dict[str, dict[str, Any]]:
    slices: dict[str, dict[str, Any]] = {}
    for difficulty in sorted({record["difficulty"] for record in records}):
        rows = [record for record in records if record["difficulty"] == difficulty]
        exact = sum(
            set(record["gold_tool_ids"]) == set(predictions[record["case_id"]])
            for record in rows
        )
        normal_rows = [record for record in rows if not record["gold_tool_ids"]]
        false_activations = sum(
            bool(predictions[record["case_id"]]) for record in normal_rows
        )
        slices[difficulty] = {
            "record_count": len(rows),
            "exact_match": exact / len(rows),
            "normal_count": len(normal_rows),
            "normal_false_activation_count": false_activations,
            "normal_false_activation_rate": (
                false_activations / len(normal_rows) if normal_rows else None
            ),
        }
    return slices


def run_gemma_prompt_router(
    *,
    dataset_path: Path,
    model_artifact_path: Path,
    prompt_path: Path,
    config_path: Path,
    output_dir: Path,
    base_url: str,
    runtime_version: str,
    backend: str,
    timeout_seconds: float,
    client: LiteRTLMOpenAIClient | None = None,
) -> Path:
    if backend not in {"cpu", "gpu"}:
        raise ToolRouteBenchError("Gemma router backend must be cpu or gpu")
    run_commit = git_commit(require_clean=True)
    config = _load_locked_config(config_path, prompt_path)
    expected_model = verify_gemma_artifact(
        model_artifact_path, config["model_registry_id"]
    )
    records = read_jsonl(dataset_path)
    validate_holdout_dataset(records)
    tool_ids = load_tool_contract()["tool_order"]
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    http_client = client or LiteRTLMOpenAIClient(
        base_url=base_url, timeout_seconds=timeout_seconds
    )
    if config["server_model_id"] not in http_client.model_ids():
        raise ToolRouteBenchError(
            f"LiteRT-LM server has no model: {config['server_model_id']}"
        )

    request_contract = {
        "schema_version": "toolroutebench-gemma-request-v1",
        "git_commit": run_commit,
        "dataset_sha256": sha256_file(dataset_path),
        "model_sha256": sha256_file(model_artifact_path),
        "prompt_sha256": sha256_file(prompt_path),
        "config_sha256": sha256_file(config_path),
        "server_model_id": config["server_model_id"],
        "base_url": require_loopback_base_url(base_url),
        "runtime_version": runtime_version,
        "backend": backend,
        "timeout_seconds": timeout_seconds,
    }
    request_path = output_dir / "run_request.json"
    predictions_path = output_dir / "predictions.jsonl"
    if output_dir.exists():
        if (output_dir / "run_manifest.json").exists():
            raise ToolRouteBenchError(f"Gemma run is already complete: {output_dir}")
        if not request_path.is_file():
            raise ToolRouteBenchError("Gemma output has no resumable request")
        checkpoint = read_json(request_path)
        if checkpoint.get("request") != request_contract:
            raise ToolRouteBenchError("Gemma checkpoint belongs to another run")
        started_at = checkpoint["started_at"]
        results = read_jsonl(predictions_path) if predictions_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        started_at = utc_now()
        results = []
        write_json(
            request_path,
            {"started_at": started_at, "request": request_contract},
        )

    case_ids = [record["case_id"] for record in records]
    completed = {row["case_id"] for row in results}
    if len(completed) != len(results) or not completed <= set(case_ids):
        raise ToolRouteBenchError("Gemma checkpoint contains invalid case IDs")

    for index, record in enumerate(records, start=1):
        if record["case_id"] in completed:
            continue
        raw_output = ""
        error_text: str | None = None
        generation = ChatGeneration("", 0.0, config["server_model_id"], None, None)
        try:
            generation = http_client.generate(
                model_id=config["server_model_id"],
                system_prompt=system_prompt,
                user_message=record["utterance"],
                temperature=config["temperature"],
                top_p=config["top_p"],
                max_tokens=config["max_tokens"],
            )
            if generation.response_model_id != config["server_model_id"]:
                raise ToolRouteBenchError("LiteRT-LM responded with another model ID")
            raw_output = generation.text
            predicted, parse_status = parse_prompt_route(raw_output, tool_ids)
        except Exception as error:  # noqa: BLE001 - fail closed and preserve evidence
            predicted, parse_status = [], "error_fallback"
            error_text = f"{type(error).__name__}: {error}"
        result = {
            "case_id": record["case_id"],
            "predicted_tool_ids": predicted,
            "raw_output": raw_output,
            "parse_status": parse_status,
            "error": error_text,
            "route_elapsed_ms": generation.elapsed_ms,
            "prompt_tokens": generation.prompt_tokens,
            "completion_tokens": generation.completion_tokens,
        }
        append_jsonl(predictions_path, result)
        results.append(result)
        if index == 1 or index % 10 == 0:
            print(f"Gemma prompt router: {index}/{len(records)}", flush=True)

    if {row["case_id"] for row in results} != set(case_ids):
        raise ToolRouteBenchError("Gemma run ended without every prediction")
    by_case = {row["case_id"]: row["predicted_tool_ids"] for row in results}
    metrics = multilabel_metrics(
        [record["gold_tool_ids"] for record in records],
        [by_case[case_id] for case_id in case_ids],
        tool_ids,
    )
    elapsed = [float(row["route_elapsed_ms"]) for row in results]
    strict_count = sum(row["parse_status"] == "strict" for row in results)
    error_count = sum(row["error"] is not None for row in results)
    result_summary = {
        "schema_version": "toolroutebench-gemma-router-result-v1",
        "candidate_id": config["candidate_id"],
        "evaluation_scope": config["evaluation_scope"],
        "dataset_sha256": sha256_file(dataset_path),
        "metrics": metrics,
        "quality_by_difficulty": _quality_slices(records, by_case),
        "output_contract": {
            "strict_count": strict_count,
            "strict_rate": strict_count / len(results),
            "fallback_count": len(results) - strict_count,
            "error_count": error_count,
        },
        "latency_ms": {
            "count": len(elapsed),
            "mean": round(statistics.fmean(elapsed), 3),
            "median": round(statistics.median(elapsed), 3),
            "p95": _percentile(elapsed, 0.95),
            "min": round(min(elapsed), 3),
            "max": round(max(elapsed), 3),
            "first_output": None,
        },
        "token_usage_available": all(
            row["prompt_tokens"] is not None and row["completion_tokens"] is not None
            for row in results
        ),
        "predictions": predictions_path.name,
        "predictions_sha256": sha256_file(predictions_path),
    }
    result_path = output_dir / "result.json"
    write_json(result_path, result_summary)
    manifest = {
        "benchmark_id": "toolroutebench",
        "benchmark_version": load_benchmark_contract()["benchmark_version"],
        "run_id": output_dir.name,
        "status": "completed",
        "git_commit": run_commit,
        "started_at": started_at,
        "ended_at": utc_now(),
        "track": "holdout",
        "candidate": {
            "candidate_id": config["candidate_id"],
            "router_family": config["router_family"],
            "config_sha256": sha256_file(config_path),
            "prompt_sha256": sha256_file(prompt_path),
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
                "role": "router",
                "model_id": expected_model["id"],
                "artifact_sha256": expected_model["sha256"],
            }
        ],
        "runtime": {
            "name": "LiteRT-LM OpenAI-compatible server",
            "version": runtime_version,
            "backend": backend,
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
        "notes": (
            "Retrospective comparison on the already-opened Pilot Holdout; "
            "not eligible for confirmatory candidate selection. Non-streaming HTTP "
            "does not expose first-output latency."
        ),
    }
    manifest_path = output_dir / "run_manifest.json"
    write_json(manifest_path, manifest)
    validate_run_manifest(manifest_path)
    return manifest_path.resolve()
