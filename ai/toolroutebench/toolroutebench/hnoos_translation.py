from __future__ import annotations

import hashlib
import json
import re
import statistics
from pathlib import Path
from typing import Any

from .actionability import normalize_utterance
from .common import (
    CONFIGS_DIR,
    PROMPTS_DIR,
    ToolRouteBenchError,
    append_jsonl,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .gemma_runner import (
    ChatGeneration,
    LiteRTLMOpenAIClient,
    require_loopback_base_url,
    verify_gemma_artifact,
)

HNOOS_TRANSLATION_CONFIG = CONFIGS_DIR / "actionability-hnoos-ko-translation.v1.json"
HNOOS_TRANSLATION_PROMPT = PROMPTS_DIR / "hnoos-en-to-ko-v1.md"
HANGUL_PATTERN = re.compile(r"[가-힣]")


def parse_korean_translation(raw_text: str) -> str:
    normalized = raw_text.strip()
    if normalized.startswith("```"):
        lines = normalized.splitlines()
        if len(lines) < 3 or lines[0] not in {"```", "```json"} or lines[-1] != "```":
            raise ToolRouteBenchError("translation output has malformed code fences")
        normalized = "\n".join(lines[1:-1]).strip()
    elif "```" in normalized:
        raise ToolRouteBenchError("translation output has unexpected code fences")
    try:
        value = json.loads(normalized)
    except json.JSONDecodeError as error:
        raise ToolRouteBenchError("translation output is not strict JSON") from error
    if not isinstance(value, dict) or set(value) != {"ko"}:
        raise ToolRouteBenchError("translation JSON must contain only the ko field")
    translated = value["ko"]
    if not isinstance(translated, str):
        raise ToolRouteBenchError("translation ko field must be text")
    translated = normalize_utterance(translated)
    if not translated or not HANGUL_PATTERN.search(translated):
        raise ToolRouteBenchError("translation output contains no Korean text")
    return translated


def _load_translation_config(config_path: Path, prompt_path: Path) -> dict[str, Any]:
    config = read_json(config_path)
    expected = {
        "experiment_id": "hnoos-en-to-ko-gemma4-e2b-v1",
        "model_registry_id": "gemma-e2b-it",
        "server_model_id": "gemma4-e2b",
        "temperature": 0.0,
        "top_p": 1.0,
        "max_tokens": 96,
    }
    if any(config.get(key) != value for key, value in expected.items()):
        raise ToolRouteBenchError("HN-OOS translation config violates its contract")
    configured_prompt = (config_path.parent / config["system_prompt"]).resolve()
    if configured_prompt != prompt_path.resolve() or not prompt_path.is_file():
        raise ToolRouteBenchError("HN-OOS translation prompt differs from its config")
    return config


def _load_source_rows(
    dataset_path: Path,
    dataset_manifest_path: Path,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest = read_json(dataset_manifest_path)
    expected_sha256 = manifest.get("artifacts", {}).get("dataset", {}).get("sha256")
    if expected_sha256 != sha256_file(dataset_path):
        raise ToolRouteBenchError("HN-OOS source dataset differs from its manifest")
    if manifest.get("role") != "train_only_no_call_auxiliary":
        raise ToolRouteBenchError("HN-OOS source manifest has an unexpected role")
    rows = read_jsonl(dataset_path)
    ids: set[str] = set()
    utterances: set[str] = set()
    for row in rows:
        case_id = row.get("case_id")
        utterance = row.get("utterance")
        if (
            not isinstance(case_id, str)
            or not isinstance(utterance, str)
            or row.get("split") != "train"
            or row.get("call") is not False
            or row.get("source") != "hnoos_en"
        ):
            raise ToolRouteBenchError("HN-OOS source dataset contains an invalid row")
        if case_id in ids or utterance in utterances:
            raise ToolRouteBenchError("HN-OOS source dataset contains duplicates")
        ids.add(case_id)
        utterances.add(utterance)
    if not rows:
        raise ToolRouteBenchError("HN-OOS source dataset is empty")
    return rows, manifest


def run_hnoos_korean_translation(
    *,
    dataset_path: Path,
    dataset_manifest_path: Path,
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
        raise ToolRouteBenchError("translation backend must be cpu or gpu")
    commit = git_commit(require_clean=True)
    config = _load_translation_config(config_path, prompt_path)
    expected_model = verify_gemma_artifact(
        model_artifact_path, config["model_registry_id"]
    )
    rows, source_manifest = _load_source_rows(dataset_path, dataset_manifest_path)
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    http_client = client or LiteRTLMOpenAIClient(
        base_url=base_url,
        timeout_seconds=timeout_seconds,
    )
    if config["server_model_id"] not in http_client.model_ids():
        raise ToolRouteBenchError(
            f"LiteRT-LM server has no model: {config['server_model_id']}"
        )

    request_contract = {
        "schema_version": "toolroutebench-hnoos-translation-request-v1",
        "git_commit": commit,
        "dataset_sha256": sha256_file(dataset_path),
        "dataset_manifest_sha256": sha256_file(dataset_manifest_path),
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
    checkpoint_path = output_dir / "translations.jsonl"
    if output_dir.exists():
        if (output_dir / "dataset_manifest.json").exists():
            raise ToolRouteBenchError(f"translation run already completed: {output_dir}")
        if not request_path.is_file():
            raise ToolRouteBenchError("translation output has no resumable request")
        checkpoint = read_json(request_path)
        if checkpoint.get("request") != request_contract:
            raise ToolRouteBenchError("translation checkpoint belongs to another run")
        started_at = checkpoint["started_at"]
        results = read_jsonl(checkpoint_path) if checkpoint_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        started_at = utc_now()
        results = []
        write_json(
            request_path,
            {"started_at": started_at, "request": request_contract},
        )
    case_ids = {row["case_id"] for row in rows}
    completed = {row.get("case_id") for row in results}
    if len(completed) != len(results) or not completed <= case_ids:
        raise ToolRouteBenchError("translation checkpoint contains invalid case IDs")

    for index, row in enumerate(rows, start=1):
        if row["case_id"] in completed:
            continue
        generation = ChatGeneration(
            "",
            0.0,
            config["server_model_id"],
            None,
            None,
        )
        generation = http_client.generate(
            model_id=config["server_model_id"],
            system_prompt=system_prompt,
            user_message=row["utterance"],
            temperature=config["temperature"],
            top_p=config["top_p"],
            max_tokens=config["max_tokens"],
        )
        if generation.response_model_id != config["server_model_id"]:
            raise ToolRouteBenchError("LiteRT-LM responded with another model ID")
        translated = parse_korean_translation(generation.text)
        result = {
            "case_id": row["case_id"],
            "original": row["utterance"],
            "translated": translated,
            "raw_output": generation.text,
            "elapsed_ms": generation.elapsed_ms,
            "prompt_tokens": generation.prompt_tokens,
            "completion_tokens": generation.completion_tokens,
        }
        append_jsonl(checkpoint_path, result)
        results.append(result)
        if index == 1 or index % 10 == 0:
            print(f"HN-OOS Korean translation: {index}/{len(rows)}", flush=True)

    if {row["case_id"] for row in results} != case_ids:
        raise ToolRouteBenchError("translation run ended without every source row")
    translation_by_case = {row["case_id"]: row for row in results}
    translated_rows: list[dict[str, Any]] = []
    duplicate_translations: list[str] = []
    seen_translations: set[str] = set()
    for source_row in rows:
        translated = translation_by_case[source_row["case_id"]]["translated"]
        if translated in seen_translations:
            duplicate_translations.append(source_row["case_id"])
            continue
        seen_translations.add(translated)
        case_hash = hashlib.sha256(
            f"{source_row['case_id']}\x1f{translated}".encode("utf-8")
        ).hexdigest()[:16]
        translated_rows.append(
            {
                **source_row,
                "case_id": f"hnoos-ko-train-{case_hash}",
                "utterance": translated,
                "source": "hnoos_ko_machine_translation",
                "source_label_name": f"hnoos_ko:{source_row['source_label']}",
                "original_case_id": source_row["case_id"],
                "original_utterance": source_row["utterance"],
            }
        )
    dataset_output_path = output_dir / "dataset.jsonl"
    embedding_inputs_path = output_dir / "embedding_inputs.jsonl"
    write_jsonl(dataset_output_path, translated_rows)
    write_jsonl(
        embedding_inputs_path,
        [
            {
                "embedding_id": f"actionability-aux:{row['case_id']}",
                "kind": "actionability_auxiliary",
                "case_id": row["case_id"],
                "split": "train",
                "text": row["utterance"],
                "call": False,
                "label": "NO_CALL",
                "source": row["source"],
                "source_dataset": row["source_dataset"],
                "source_label": row["source_label"],
                "source_label_name": row["source_label_name"],
            }
            for row in translated_rows
        ],
    )
    elapsed_values = [float(row["elapsed_ms"]) for row in results]
    manifest = {
        "schema_version": "toolroutebench-actionability-aux-dataset-v1",
        "experiment_id": config["experiment_id"],
        "created_at": utc_now(),
        "started_at": started_at,
        "language": "ko",
        "role": "train_only_no_call_auxiliary",
        "quality_status": "machine_translated_format_validated_not_human_reviewed",
        "license": source_manifest["license"],
        "source_repository": source_manifest["source_repository"],
        "source_dataset": {
            "path": str(dataset_path.resolve()),
            "sha256": sha256_file(dataset_path),
            "manifest_path": str(dataset_manifest_path.resolve()),
            "manifest_sha256": sha256_file(dataset_manifest_path),
        },
        "translation": {
            "model_registry_id": config["model_registry_id"],
            "model_revision": expected_model["revision"],
            "model_sha256": sha256_file(model_artifact_path),
            "prompt_sha256": sha256_file(prompt_path),
            "config_sha256": sha256_file(config_path),
            "runtime_version": runtime_version,
            "backend": backend,
            "temperature": config["temperature"],
            "mean_elapsed_ms": statistics.mean(elapsed_values),
            "median_elapsed_ms": statistics.median(elapsed_values),
        },
        "counts": {
            "source_records": len(rows),
            "translated_records": len(translated_rows),
            "duplicate_translations_removed": len(duplicate_translations),
            "duplicate_translation_source_case_ids": duplicate_translations,
        },
        "artifacts": {
            "dataset": {
                "path": dataset_output_path.name,
                "sha256": sha256_file(dataset_output_path),
            },
            "embedding_inputs": {
                "path": embedding_inputs_path.name,
                "sha256": sha256_file(embedding_inputs_path),
            },
            "translations": {
                "path": checkpoint_path.name,
                "sha256": sha256_file(checkpoint_path),
            },
        },
    }
    manifest_path = output_dir / "dataset_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()
