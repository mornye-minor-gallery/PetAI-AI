#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import random
import statistics
import tempfile
from collections import Counter, defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np

from hybrid_memory_harness import (
    HeaderSyntax,
    HybridMemoryHarness,
    IdempotentCommitLedger,
    MemoryDecision,
    MemoryDecisionParser,
    MemoryHeaderFormat,
    contains_control_leak,
)
from litert_chat_client import LiteRTChatClient
from mlp_fallback import (
    EmbeddingIndex,
    EmbeddingMLPFallbackClassifier,
)


class HybridEvaluationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_dataset(path: Path, *, split: str) -> list[dict[str, Any]]:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise HybridEvaluationError(f"Dataset split not found: {path}")

    rows: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: invalid JSON."
                ) from error
            if row.get("split") != split:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: expected split "
                    f"{split!r}."
                )
            record_id = row.get("id")
            utterance = row.get("utterance")
            if not isinstance(record_id, str) or not record_id:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: invalid id."
                )
            if record_id in seen_ids:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: duplicate id."
                )
            if not isinstance(utterance, str) or not utterance.strip():
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: invalid utterance."
                )
            if type(row.get("preference")) is not bool:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: preference must be bool."
                )
            if type(row.get("event")) is not bool:
                raise HybridEvaluationError(
                    f"{path.name}:{line_number}: event must be bool."
                )
            seen_ids.add(record_id)
            rows.append(row)
    if not rows:
        raise HybridEvaluationError(f"{path.name}: split is empty.")
    return rows


def select_balanced_rows(
    rows: list[dict[str, Any]],
    *,
    total: int,
    seed: int,
) -> list[dict[str, Any]]:
    if total <= 0 or total % 4 != 0:
        raise HybridEvaluationError(
            "Balanced record limit must be positive and divisible by four."
        )
    per_label = total // 4
    groups: dict[tuple[bool, bool], list[dict[str, Any]]] = defaultdict(
        list
    )
    for row in rows:
        groups[(row["preference"], row["event"])].append(row)

    expected_labels = {
        (False, False),
        (True, False),
        (False, True),
        (True, True),
    }
    if set(groups) != expected_labels:
        raise HybridEvaluationError(
            "Dataset does not contain all four memory label combinations."
        )

    selection: list[dict[str, Any]] = []
    for index, label in enumerate(sorted(groups)):
        candidates = sorted(groups[label], key=lambda row: row["id"])
        if len(candidates) < per_label:
            raise HybridEvaluationError(
                f"Label {label} has {len(candidates)} records, "
                f"but {per_label} are required."
            )
        label_random = random.Random(seed + index)
        label_random.shuffle(candidates)
        selection.extend(candidates[:per_label])

    final_random = random.Random(seed)
    final_random.shuffle(selection)
    return selection


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def ratio(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else numerator / denominator


def summarize_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(rows)
    primary_seconds = [row["outcome"]["primary_seconds"] for row in rows]
    retry_seconds = [
        row["outcome"]["retry_seconds"]
        for row in rows
        if row["outcome"]["retry_attempted"]
    ]
    fallback_seconds = [
        row["outcome"]["fallback_seconds"]
        for row in rows
        if row["outcome"]["fallback_attempted"]
    ]
    total_seconds = [row["outcome"]["total_seconds"] for row in rows]

    exact_primary = sum(
        row["outcome"]["primary_syntax"]
        == HeaderSyntax.CANONICAL.value
        for row in rows
    )
    recovered_primary = sum(
        row["outcome"]["primary_syntax"]
        == HeaderSyntax.RECOVERED.value
        for row in rows
    )
    primary_resolved = exact_primary + recovered_primary
    retry_attempted = sum(
        row["outcome"]["retry_attempted"] for row in rows
    )
    retry_succeeded = sum(
        row["outcome"]["retry_succeeded"] for row in rows
    )
    fallback_attempted = sum(
        row["outcome"]["fallback_attempted"] for row in rows
    )
    fallback_succeeded = sum(
        row["outcome"]["fallback_succeeded"] for row in rows
    )
    chat_delivered = sum(
        bool(row["outcome"]["visible_text"]) for row in rows
    )
    control_leaks = sum(row["control_leak"] for row in rows)
    hybrid_correct = sum(row["hybrid_label_correct"] for row in rows)
    strict_correct = sum(row["strict_label_correct"] for row in rows)
    tolerant_correct = sum(row["tolerant_label_correct"] for row in rows)
    mlp_correct = sum(row["mlp_label_correct"] for row in rows)
    unsafe_commits = sum(row["unsafe_commit"] for row in rows)
    duplicate_commits = sum(row["duplicate_commit"] for row in rows)

    return {
        "records": total,
        "protocol": {
            "exact_primary_rate": ratio(exact_primary, total),
            "recovered_primary_rate": ratio(
                recovered_primary,
                total,
            ),
            "primary_resolution_rate": ratio(
                primary_resolved,
                total,
            ),
            "body_retry_rate": ratio(retry_attempted, total),
            "body_retry_success_rate": ratio(
                retry_succeeded,
                retry_attempted,
            ),
            "mlp_fallback_rate": ratio(fallback_attempted, total),
            "mlp_fallback_success_rate": ratio(
                fallback_succeeded,
                fallback_attempted,
            ),
            "chat_delivery_rate": ratio(chat_delivered, total),
            "control_leak_rate": ratio(control_leaks, total),
            "unsafe_commit_rate": ratio(unsafe_commits, total),
            "duplicate_commit_count": duplicate_commits,
        },
        "label_exact_match": {
            "gemma_strict": ratio(strict_correct, total),
            "gemma_tolerant_parser": ratio(
                tolerant_correct,
                total,
            ),
            "hybrid": ratio(hybrid_correct, total),
            "mlp_only": ratio(mlp_correct, total),
        },
        "latency_seconds": {
            "primary": latency_summary(primary_seconds),
            "retry_when_used": latency_summary(retry_seconds),
            "fallback_when_used": latency_summary(fallback_seconds),
            "end_to_end": latency_summary(total_seconds),
        },
        "errors": dict(
            sorted(
                Counter(
                    error.split(":", maxsplit=1)[0]
                    for row in rows
                    for error in row["outcome"]["errors"]
                ).items()
            )
        ),
    }


def latency_summary(values: list[float]) -> dict[str, float]:
    if not values:
        return {
            "count": 0,
            "mean": 0.0,
            "p50": 0.0,
            "p95": 0.0,
            "max": 0.0,
        }
    return {
        "count": len(values),
        "mean": statistics.fmean(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def summarize_breakdown(
    rows: list[dict[str, Any]],
    *,
    key: str,
) -> dict[str, Any]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        value = row.get(key)
        groups[str(value) if value is not None else "unknown"].append(row)
    return {
        group: {
            "records": len(group_rows),
            "chat_delivery_rate": ratio(
                sum(
                    bool(item["outcome"]["visible_text"])
                    for item in group_rows
                ),
                len(group_rows),
            ),
            "hybrid_label_exact_match": ratio(
                sum(
                    item["hybrid_label_correct"]
                    for item in group_rows
                ),
                len(group_rows),
            ),
            "fallback_rate": ratio(
                sum(
                    item["outcome"]["fallback_attempted"]
                    for item in group_rows
                ),
                len(group_rows),
            ),
        }
        for group, group_rows in sorted(groups.items())
    }


def evaluate(
    *,
    dataset_dir: Path,
    embeddings_dir: Path,
    splits: list[str],
    weights_path: Path,
    prompt_path: Path,
    output_dir: Path,
    model_artifact_path: Path,
    runtime_version: str,
    base_url: str,
    model: str,
    repeats: int,
    temperature: float,
    top_p: float,
    max_tokens: int,
    timeout_seconds: float,
    balanced_limit_per_split: int | None,
    selection_seed: int,
    header_format: MemoryHeaderFormat,
) -> Path:
    if repeats <= 0:
        raise HybridEvaluationError("repeats must be greater than zero.")
    output_dir = output_dir.expanduser().resolve()
    if output_dir.exists():
        raise HybridEvaluationError(
            f"Output directory already exists: {output_dir}"
        )

    prompt_path = prompt_path.expanduser().resolve()
    model_artifact_path = model_artifact_path.expanduser().resolve()
    weights_path = weights_path.expanduser().resolve()
    for required_path in (
        prompt_path,
        model_artifact_path,
        weights_path,
    ):
        if not required_path.is_file():
            raise HybridEvaluationError(
                f"Required file not found: {required_path}"
            )
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    if not system_prompt:
        raise HybridEvaluationError("System prompt is empty.")

    datasets: dict[str, list[dict[str, Any]]] = {}
    dataset_paths: dict[str, Path] = {}
    embedding_paths: dict[str, Path] = {}
    embedding_index = EmbeddingIndex()
    for split in splits:
        dataset_path = (dataset_dir / f"{split}.jsonl").resolve()
        embedding_path = (
            embeddings_dir / f"{split}.embeddings.jsonl"
        ).resolve()
        loaded_rows = load_dataset(dataset_path, split=split)
        datasets[split] = (
            select_balanced_rows(
                loaded_rows,
                total=balanced_limit_per_split,
                seed=selection_seed,
            )
            if balanced_limit_per_split is not None
            else loaded_rows
        )
        embedding_index.add_file(embedding_path)
        dataset_paths[split] = dataset_path
        embedding_paths[split] = embedding_path

    fallback = EmbeddingMLPFallbackClassifier(
        weights_path=weights_path,
        embeddings=embedding_index,
    )
    client = LiteRTChatClient(
        base_url=base_url,
        model=model,
        system_prompt=system_prompt,
        temperature=temperature,
        top_p=top_p,
        max_tokens=max_tokens,
        timeout_seconds=timeout_seconds,
    )
    harness = HybridMemoryHarness(
        parser=MemoryDecisionParser(header_format=header_format)
    )
    ledger = IdempotentCommitLedger()

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}.",
            dir=output_dir.parent,
        )
    )
    started_at = datetime.now(UTC)
    state_path = temporary_dir / "run_state.json"
    results_path = temporary_dir / "results.jsonl"
    rows: list[dict[str, Any]] = []
    state_path.write_text(
        json.dumps(
            {
                "phase": "hybrid_evaluation_running",
                "started_at": started_at.isoformat(),
                "completed_records": 0,
                "expected_records": sum(
                    len(split_rows) for split_rows in datasets.values()
                )
                * repeats,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    with results_path.open("w", encoding="utf-8", newline="\n") as handle:
        for repeat in range(repeats):
            for split in splits:
                for source in datasets[split]:
                    record_id = source["id"]
                    utterance = source["utterance"]
                    request_id = f"{split}:{record_id}:repeat-{repeat}"
                    expected = MemoryDecision.from_flags(
                        preference=source["preference"],
                        event=source["event"],
                    )
                    mlp_decision = fallback.classify(
                        record_id=record_id,
                        utterance=utterance,
                    )
                    outcome = harness.run(
                        request_id=request_id,
                        record_id=record_id,
                        user_message=utterance,
                        primary_generation=lambda message=utterance: (
                            client.stream_primary(message)
                        ),
                        retry_generation=(
                            lambda previous, message=utterance: (
                                client.stream_retry(
                                    user_message=message,
                                    previous_output=previous,
                                )
                            )
                        ),
                        fallback_classifier=fallback,
                    )
                    accepted_commit = False
                    duplicate_commit = False
                    if outcome.should_commit:
                        accepted_commit = ledger.commit(
                            request_id=request_id,
                            decision=outcome.decision,
                        )
                        duplicate_commit = not accepted_commit

                    strict_label_correct = (
                        outcome.primary_syntax
                        is HeaderSyntax.CANONICAL
                        and outcome.decision_source.value == "primary"
                        and outcome.decision is expected
                        and bool(outcome.visible_text)
                    )
                    tolerant_label_correct = (
                        outcome.primary_syntax
                        in {
                            HeaderSyntax.CANONICAL,
                            HeaderSyntax.RECOVERED,
                        }
                        and outcome.decision_source.value == "primary"
                        and outcome.decision is expected
                    )
                    unsafe_commit = (
                        outcome.should_commit
                        and outcome.decision_source.value == "unresolved"
                    )
                    row = {
                        "request_id": request_id,
                        "record_id": record_id,
                        "split": split,
                        "repeat": repeat,
                        "utterance": utterance,
                        "expected": expected.value,
                        "challenge_type": source.get("challenge_type"),
                        "expression_pattern": source.get(
                            "expression_pattern"
                        ),
                        "surface_style": source.get("surface_style"),
                        "mlp_baseline_decision": mlp_decision.value,
                        "strict_label_correct": strict_label_correct,
                        "tolerant_label_correct": tolerant_label_correct,
                        "hybrid_label_correct": (
                            outcome.decision is expected
                        ),
                        "mlp_label_correct": mlp_decision is expected,
                        "control_leak": contains_control_leak(
                            outcome.visible_text
                        ),
                        "unsafe_commit": unsafe_commit,
                        "accepted_commit": accepted_commit,
                        "duplicate_commit": duplicate_commit,
                        "outcome": outcome.to_dict(),
                    }
                    rows.append(row)
                    handle.write(
                        json.dumps(
                            row,
                            ensure_ascii=False,
                            allow_nan=False,
                        )
                        + "\n"
                    )
                    handle.flush()
                    state_path.write_text(
                        json.dumps(
                            {
                                "phase": "hybrid_evaluation_running",
                                "started_at": started_at.isoformat(),
                                "completed_records": len(rows),
                                "expected_records": sum(
                                    len(split_rows)
                                    for split_rows in datasets.values()
                                )
                                * repeats,
                            },
                            ensure_ascii=False,
                            indent=2,
                        )
                        + "\n",
                        encoding="utf-8",
                    )

    split_metrics = {
        split: summarize_rows(
            [row for row in rows if row["split"] == split]
        )
        for split in splits
    }
    manifest = {
        "phase": "hybrid_evaluation_complete",
        "created_at": datetime.now(UTC).isoformat(),
        "started_at": started_at.isoformat(),
        "configuration": {
            "model": model,
            "runtime_version": runtime_version,
            "base_url": base_url,
            "temperature": temperature,
            "top_p": top_p,
            "max_tokens": max_tokens,
            "timeout_seconds": timeout_seconds,
            "repeats": repeats,
            "splits": splits,
            "selection": {
                "balanced_limit_per_split": balanced_limit_per_split,
                "seed": selection_seed,
            },
            "header_format": header_format.value,
            "policy": {
                "primary": "Gemma memory header plus visible reply",
                "missing_body": "one answer-only Gemma retry",
                "missing_or_malformed_header": (
                    "EmbeddingGemma MLP fallback"
                ),
                "unresolved": "MemoryDecision.NONE with explicit error",
                "commit": "once per request id after visible body exists",
            },
        },
        "provenance": {
            "prompt": {
                "path": str(prompt_path),
                "sha256": sha256_file(prompt_path),
            },
            "model_artifact": {
                "path": str(model_artifact_path),
                "sha256": sha256_file(model_artifact_path),
            },
            "classifier_weights": {
                "path": str(weights_path),
                "sha256": sha256_file(weights_path),
            },
            "datasets": {
                split: {
                    "path": str(dataset_paths[split]),
                    "sha256": sha256_file(dataset_paths[split]),
                    "records": len(datasets[split]),
                }
                for split in splits
            },
            "embeddings": {
                split: {
                    "path": str(embedding_paths[split]),
                    "sha256": sha256_file(embedding_paths[split]),
                }
                for split in splits
            },
            "runtime": {
                "python": platform.python_version(),
                "platform": platform.platform(),
                "machine": platform.machine(),
                "numpy": np.__version__,
            },
        },
        "metrics": {
            "overall": summarize_rows(rows),
            "by_split": split_metrics,
            "by_expected_label": summarize_breakdown(
                rows,
                key="expected",
            ),
            "by_challenge_type": summarize_breakdown(
                rows,
                key="challenge_type",
            ),
            "by_surface_style": summarize_breakdown(
                rows,
                key="surface_style",
            ),
        },
        "commit_ledger": {
            "attempts": ledger.attempts,
            "accepted": ledger.accepted,
            "duplicates": ledger.duplicates,
        },
        "artifacts": {
            "results": {
                "path": results_path.name,
                "sha256": sha256_file(results_path),
                "records": len(rows),
            }
        },
        "verification_scope": {
            "quality": (
                "Exact deployment LiteRT-LM artifact on macOS."
            ),
            "not_proven": [
                "iPhone latency",
                "iPhone memory",
                "iPhone thermal behavior",
                "iPhone battery behavior",
                "Swift port parity",
                "multi-turn memory behavior",
            ],
        },
    }
    manifest_path = temporary_dir / "evaluation_manifest.json"
    manifest_path.write_text(
        json.dumps(
            manifest,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    state_path.write_text(
        json.dumps(
            {
                "phase": "hybrid_evaluation_complete",
                "started_at": started_at.isoformat(),
                "completed_at": manifest["created_at"],
                "completed_records": len(rows),
                "expected_records": len(rows),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    os.replace(temporary_dir, output_dir)
    return output_dir / manifest_path.name


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate the deterministic Gemma header/retry/MLP fallback "
            "memory harness against fixed PetAI splits."
        )
    )
    parser.add_argument("--dataset-dir", required=True, type=Path)
    parser.add_argument("--embeddings-dir", required=True, type=Path)
    parser.add_argument(
        "--splits",
        nargs="+",
        default=["test", "synthetic_challenge"],
    )
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--prompt", required=True, type=Path)
    parser.add_argument("--model-artifact", required=True, type=Path)
    parser.add_argument("--runtime-version", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:9379/v1",
    )
    parser.add_argument(
        "--model",
        default="gemma4-e2b,gpu,4096",
    )
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top-p", type=float, default=1.0)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--timeout-seconds", type=float, default=120.0)
    parser.add_argument(
        "--balanced-limit-per-split",
        type=int,
        help=(
            "Deterministically select an equal number of N/P/E/B records "
            "from each split."
        ),
    )
    parser.add_argument("--selection-seed", type=int, default=42)
    parser.add_argument(
        "--header-format",
        choices=[item.value for item in MemoryHeaderFormat],
        default=MemoryHeaderFormat.LABEL.value,
    )
    return parser


def main() -> None:
    arguments = build_parser().parse_args()
    manifest_path = evaluate(
        dataset_dir=arguments.dataset_dir,
        embeddings_dir=arguments.embeddings_dir,
        splits=arguments.splits,
        weights_path=arguments.weights,
        prompt_path=arguments.prompt,
        output_dir=arguments.output_dir,
        model_artifact_path=arguments.model_artifact,
        runtime_version=arguments.runtime_version,
        base_url=arguments.base_url,
        model=arguments.model,
        repeats=arguments.repeats,
        temperature=arguments.temperature,
        top_p=arguments.top_p,
        max_tokens=arguments.max_tokens,
        timeout_seconds=arguments.timeout_seconds,
        balanced_limit_per_split=(
            arguments.balanced_limit_per_split
        ),
        selection_seed=arguments.selection_seed,
        header_format=MemoryHeaderFormat(arguments.header_format),
    )
    print(f"Evaluation manifest: {manifest_path}")


if __name__ == "__main__":
    main()
