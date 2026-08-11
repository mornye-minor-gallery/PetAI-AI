from __future__ import annotations

import hashlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .authoring import build_validator_prompt
from .codex_adapter import MODEL, REASONING_EFFORT, complete_json
from .common import (
    CONTRACTS_DIR,
    PROMPTS_DIR,
    REPOSITORY_ROOT,
    SCHEMAS_DIR,
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
from .contracts import load_tool_contract


def _stable_rank(seed: int, *values: str) -> str:
    payload = "\x1f".join((str(seed), *values)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _verified_artifact_rows(
    *, manifest: dict[str, Any], manifest_dir: Path, artifact_key: str
) -> tuple[list[dict[str, Any]], Path]:
    artifact = manifest.get("artifacts", {}).get(artifact_key)
    if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str):
        raise ToolRouteBenchError(f"manifest has no {artifact_key} artifact")
    path = manifest_dir / artifact["path"]
    if artifact.get("sha256") != sha256_file(path):
        raise ToolRouteBenchError(f"{artifact_key} differs from its manifest")
    rows = read_jsonl(path)
    if artifact.get("records") != len(rows):
        raise ToolRouteBenchError(f"{artifact_key} record count differs from manifest")
    return rows, path


def prepare_3i4k_petai_labeling_queue(
    *, mining_manifest_path: Path, output_dir: Path
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    mining_manifest = read_json(mining_manifest_path)
    if (
        mining_manifest.get("schema_version")
        != "toolroutebench-3i4k-petai-candidate-mining-v1"
        or mining_manifest.get("status") != "candidate_search_only_unlabeled"
    ):
        raise ToolRouteBenchError("unexpected 3i4K mining manifest")
    candidates, candidates_path = _verified_artifact_rows(
        manifest=mining_manifest,
        manifest_dir=mining_manifest_path.parent,
        artifact_key="candidates",
    )
    rejected, rejected_path = _verified_artifact_rows(
        manifest=mining_manifest,
        manifest_dir=mining_manifest_path.parent,
        artifact_key="rejected_audit_sample",
    )
    queue: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for partition, rows in (
        ("candidate", candidates),
        ("rejected_audit", rejected),
    ):
        for row in rows:
            case_id = row.get("case_id")
            if (
                not isinstance(case_id, str)
                or case_id in seen_ids
                or not isinstance(row.get("utterance"), str)
                or not row["utterance"].strip()
                or "gold_tool_ids" in row
                or "call" in row
            ):
                raise ToolRouteBenchError("invalid unlabeled mining row")
            seen_ids.add(case_id)
            queue.append({**row, "labeling_partition": partition})
    queue_path = output_dir / "labeling_queue.jsonl"
    output_dir.mkdir(parents=True)
    write_jsonl(queue_path, queue)
    partition_counts = Counter(row["labeling_partition"] for row in queue)
    manifest = {
        "schema_version": "toolroutebench-3i4k-petai-labeling-queue-v1",
        "experiment_id": "3i4k-petai-labeling-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "role": "unlabeled_petai_contract_audit_queue",
        "label_policy": (
            "router evidence selects audit targets but is hidden from validators "
            "and never becomes a PetAI label"
        ),
        "counts": {
            "records": len(queue),
            "by_partition": dict(sorted(partition_counts.items())),
        },
        "inputs": {
            "mining_manifest": {
                "path": str(mining_manifest_path.resolve()),
                "sha256": sha256_file(mining_manifest_path),
            },
            "candidates": {
                "path": str(candidates_path.resolve()),
                "sha256": sha256_file(candidates_path),
            },
            "rejected_audit_sample": {
                "path": str(rejected_path.resolve()),
                "sha256": sha256_file(rejected_path),
            },
        },
        "artifacts": {
            "labeling_queue": {
                "path": queue_path.name,
                "records": len(queue),
                "sha256": sha256_file(queue_path),
            }
        },
    }
    manifest_path = output_dir / "labeling_queue_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()


def _load_labeling_queue(
    *, queue_path: Path, queue_manifest_path: Path
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest = read_json(queue_manifest_path)
    if (
        manifest.get("schema_version")
        != "toolroutebench-3i4k-petai-labeling-queue-v1"
        or manifest.get("role") != "unlabeled_petai_contract_audit_queue"
    ):
        raise ToolRouteBenchError("unexpected 3i4K labeling queue manifest")
    artifact = manifest.get("artifacts", {}).get("labeling_queue", {})
    if artifact.get("sha256") != sha256_file(queue_path):
        raise ToolRouteBenchError("labeling queue differs from its manifest")
    rows = read_jsonl(queue_path)
    if artifact.get("records") != len(rows):
        raise ToolRouteBenchError("labeling queue record count differs from manifest")
    case_ids = [row.get("case_id") for row in rows]
    if (
        not all(isinstance(case_id, str) for case_id in case_ids)
        or len(set(case_ids)) != len(case_ids)
    ):
        raise ToolRouteBenchError("labeling queue contains invalid case IDs")
    return rows, manifest


def _validate_prediction(
    prediction: dict[str, Any], *, valid_tools: set[str]
) -> tuple[list[str], bool]:
    predicted = prediction.get("predicted_tool_ids")
    ambiguous = prediction.get("ambiguous")
    if (
        not isinstance(predicted, list)
        or len(predicted) > 2
        or len(set(predicted)) != len(predicted)
        or not all(isinstance(tool, str) and tool in valid_tools for tool in predicted)
        or not isinstance(ambiguous, bool)
    ):
        raise ToolRouteBenchError("validator returned an invalid PetAI prediction")
    return predicted, ambiguous


def run_3i4k_petai_labeling_stage(
    *,
    queue_path: Path,
    queue_manifest_path: Path,
    output_dir: Path,
    stage: str,
    codex_bin: str,
    batch_size: int,
    timeout_seconds: float,
) -> Path:
    if stage not in {"contract", "blind"}:
        raise ToolRouteBenchError("labeling stage must be contract or blind")
    if batch_size <= 0:
        raise ToolRouteBenchError("labeling batch size must be positive")
    commit = git_commit(require_clean=True)
    queue, _ = _load_labeling_queue(
        queue_path=queue_path,
        queue_manifest_path=queue_manifest_path,
    )
    template = PROMPTS_DIR / f"validate_{stage}.md"
    schema = SCHEMAS_DIR / "validator-output.schema.json"
    request = {
        "schema_version": "toolroutebench-3i4k-petai-labeling-request-v1",
        "git_commit": commit,
        "stage": stage,
        "queue_sha256": sha256_file(queue_path),
        "queue_manifest_sha256": sha256_file(queue_manifest_path),
        "tool_contract_sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
        "prompt_sha256": sha256_file(template),
        "output_schema_sha256": sha256_file(schema),
        "model": MODEL,
        "reasoning_effort": REASONING_EFFORT,
        "batch_size": batch_size,
    }
    request_path = output_dir / "run_request.json"
    predictions_path = output_dir / "predictions.jsonl"
    calls_path = output_dir / "calls.jsonl"
    final_manifest_path = output_dir / "labeling_manifest.json"
    if output_dir.exists():
        if final_manifest_path.exists():
            raise ToolRouteBenchError(f"labeling stage is already complete: {output_dir}")
        if not request_path.is_file() or read_json(request_path).get("request") != request:
            raise ToolRouteBenchError("labeling checkpoint does not match request")
        predictions = read_jsonl(predictions_path) if predictions_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        write_json(request_path, {"created_at": utc_now(), "request": request})
        predictions = []
    tool_order = load_tool_contract()["tool_order"]
    valid_tools = set(tool_order)
    queue_ids = {row["case_id"] for row in queue}
    completed: set[str] = set()
    for row in predictions:
        case_id = row.get("case_id")
        _validate_prediction(row, valid_tools=valid_tools)
        if not isinstance(case_id, str) or case_id not in queue_ids or case_id in completed:
            raise ToolRouteBenchError("labeling checkpoint contains invalid case IDs")
        completed.add(case_id)
    pending = [row for row in queue if row["case_id"] not in completed]
    for offset in range(0, len(pending), batch_size):
        batch = pending[offset : offset + batch_size]
        prompt_rows = [
            {"candidate_id": row["case_id"], "utterance": row["utterance"]}
            for row in batch
        ]
        result, invocation = complete_json(
            prompt=build_validator_prompt(prompt_rows, stage=stage),
            prompt_template=template,
            output_schema=schema,
            codex_bin=codex_bin,
            working_directory=REPOSITORY_ROOT,
            timeout_seconds=timeout_seconds,
        )
        raw_predictions = result.get("predictions")
        if not isinstance(raw_predictions, list):
            raise ToolRouteBenchError("validator returned no predictions")
        by_id = {row.get("candidate_id"): row for row in raw_predictions}
        requested_ids = {row["case_id"] for row in batch}
        if len(by_id) != len(raw_predictions) or set(by_id) != requested_ids:
            raise ToolRouteBenchError("validator candidate IDs differ from request")
        for source in batch:
            raw = by_id[source["case_id"]]
            predicted, ambiguous = _validate_prediction(
                raw, valid_tools=valid_tools
            )
            canonical = [tool for tool in tool_order if tool in set(predicted)]
            append_jsonl(
                predictions_path,
                {
                    "case_id": source["case_id"],
                    "predicted_tool_ids": canonical,
                    "ambiguous": ambiguous,
                    "validator": invocation.provenance(),
                },
            )
            completed.add(source["case_id"])
        append_jsonl(
            calls_path,
            {
                "stage": stage,
                "batch_offset": len(completed) - len(batch),
                "candidate_count": len(batch),
                "case_ids_sha256": hashlib.sha256(
                    "\n".join(row["case_id"] for row in batch).encode("utf-8")
                ).hexdigest(),
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "provenance": invocation.provenance(),
            },
        )
    if completed != queue_ids:
        raise ToolRouteBenchError("labeling stage ended before every case completed")
    predictions = read_jsonl(predictions_path)
    manifest = {
        "schema_version": "toolroutebench-3i4k-petai-labeling-stage-v1",
        "experiment_id": "3i4k-petai-labeling-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "stage": stage,
        "status": "complete_independent_contract_predictions",
        "validator_visibility": "utterance_and_tool_contract_only",
        "model": MODEL,
        "reasoning_effort": REASONING_EFFORT,
        "counts": {"records": len(predictions)},
        "inputs": {
            "queue": {"path": str(queue_path.resolve()), "sha256": sha256_file(queue_path)},
            "queue_manifest": {
                "path": str(queue_manifest_path.resolve()),
                "sha256": sha256_file(queue_manifest_path),
            },
            "prompt": {"path": str(template.resolve()), "sha256": sha256_file(template)},
            "output_schema": {"path": str(schema.resolve()), "sha256": sha256_file(schema)},
        },
        "artifacts": {
            "predictions": {
                "path": predictions_path.name,
                "records": len(predictions),
                "sha256": sha256_file(predictions_path),
            },
            "calls": {
                "path": calls_path.name,
                "records": len(read_jsonl(calls_path)),
                "sha256": sha256_file(calls_path),
            },
        },
    }
    write_json(final_manifest_path, manifest)
    return final_manifest_path.resolve()


def reconcile_prediction_rows(
    *,
    queue: list[dict[str, Any]],
    contract_predictions: list[dict[str, Any]],
    blind_predictions: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    tool_order = load_tool_contract()["tool_order"]
    valid_tools = set(tool_order)
    queue_ids = {row["case_id"] for row in queue}

    def index(rows: list[dict[str, Any]], stage: str) -> dict[str, dict[str, Any]]:
        result: dict[str, dict[str, Any]] = {}
        for row in rows:
            case_id = row.get("case_id")
            _validate_prediction(row, valid_tools=valid_tools)
            if not isinstance(case_id, str) or case_id in result:
                raise ToolRouteBenchError(f"{stage} predictions contain invalid IDs")
            result[case_id] = row
        if set(result) != queue_ids:
            raise ToolRouteBenchError(f"{stage} predictions do not cover labeling queue")
        return result

    contract_by_id = index(contract_predictions, "contract")
    blind_by_id = index(blind_predictions, "blind")
    accepted: list[dict[str, Any]] = []
    unresolved: list[dict[str, Any]] = []
    for source in queue:
        case_id = source["case_id"]
        contract = contract_by_id[case_id]
        blind = blind_by_id[case_id]
        contract_tools = set(contract["predicted_tool_ids"])
        blind_tools = set(blind["predicted_tool_ids"])
        contract_validator = contract.get("validator")
        blind_validator = blind.get("validator")
        if not isinstance(contract_validator, dict) or not isinstance(
            blind_validator, dict
        ):
            raise ToolRouteBenchError("labeling prediction has no validator provenance")
        sessions = {
            contract_validator.get("session_id"),
            blind_validator.get("session_id"),
        }
        if None in sessions or len(sessions) != 2:
            raise ToolRouteBenchError("labeling stages must use distinct sessions")
        agreement = (
            contract["ambiguous"] is False
            and blind["ambiguous"] is False
            and contract_tools == blind_tools
        )
        common = {
            **source,
            "contract_prediction": {
                "predicted_tool_ids": contract["predicted_tool_ids"],
                "ambiguous": contract["ambiguous"],
            },
            "blind_prediction": {
                "predicted_tool_ids": blind["predicted_tool_ids"],
                "ambiguous": blind["ambiguous"],
            },
            "label_provenance": {
                "contract_validator": contract_validator,
                "blind_validator": blind_validator,
            },
        }
        if agreement:
            agreed = [tool for tool in tool_order if tool in contract_tools]
            accepted.append(
                {
                    **common,
                    "agreed_tool_ids": agreed,
                    "call": bool(agreed),
                    "label_status": (
                        "dual_session_agreement_pending_human_audit"
                    ),
                }
            )
        else:
            reasons = []
            if contract["ambiguous"]:
                reasons.append("contract_ambiguous")
            if blind["ambiguous"]:
                reasons.append("blind_ambiguous")
            if contract_tools != blind_tools:
                reasons.append("label_disagreement")
            unresolved.append(
                {
                    **common,
                    "unresolved_reasons": reasons,
                    "label_status": "unresolved_excluded_from_training",
                }
            )
    return accepted, unresolved


def _verified_stage_predictions(
    *, manifest_path: Path, expected_stage: str, expected_queue_sha: str
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest = read_json(manifest_path)
    if (
        manifest.get("schema_version")
        != "toolroutebench-3i4k-petai-labeling-stage-v1"
        or manifest.get("stage") != expected_stage
        or manifest.get("status") != "complete_independent_contract_predictions"
        or manifest.get("inputs", {}).get("queue", {}).get("sha256")
        != expected_queue_sha
    ):
        raise ToolRouteBenchError(f"unexpected {expected_stage} labeling manifest")
    artifact = manifest.get("artifacts", {}).get("predictions", {})
    path = manifest_path.parent / artifact.get("path", "")
    if artifact.get("sha256") != sha256_file(path):
        raise ToolRouteBenchError(f"{expected_stage} predictions differ from manifest")
    rows = read_jsonl(path)
    if artifact.get("records") != len(rows):
        raise ToolRouteBenchError(f"{expected_stage} prediction count differs")
    return rows, manifest


def reconcile_3i4k_petai_labels(
    *,
    queue_path: Path,
    queue_manifest_path: Path,
    contract_manifest_path: Path,
    blind_manifest_path: Path,
    output_dir: Path,
    audit_per_partition_label: int,
    seed: int,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    if audit_per_partition_label <= 0:
        raise ToolRouteBenchError("human audit quota must be positive")
    commit = git_commit(require_clean=True)
    queue, _ = _load_labeling_queue(
        queue_path=queue_path,
        queue_manifest_path=queue_manifest_path,
    )
    queue_sha = sha256_file(queue_path)
    contract_rows, contract_manifest = _verified_stage_predictions(
        manifest_path=contract_manifest_path,
        expected_stage="contract",
        expected_queue_sha=queue_sha,
    )
    blind_rows, blind_manifest = _verified_stage_predictions(
        manifest_path=blind_manifest_path,
        expected_stage="blind",
        expected_queue_sha=queue_sha,
    )
    accepted, unresolved = reconcile_prediction_rows(
        queue=queue,
        contract_predictions=contract_rows,
        blind_predictions=blind_rows,
    )
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in accepted:
        label = "CALL" if row["call"] else "NO_CALL"
        grouped[(row["labeling_partition"], label)].append(row)
    human_audit: list[dict[str, Any]] = []
    for key in (
        ("candidate", "CALL"),
        ("candidate", "NO_CALL"),
        ("rejected_audit", "CALL"),
        ("rejected_audit", "NO_CALL"),
    ):
        ranked = sorted(
            grouped.get(key, []),
            key=lambda row: _stable_rank(
                seed, "human-audit", key[0], key[1], row["case_id"]
            ),
        )
        human_audit.extend(ranked[:audit_per_partition_label])
    human_audit = sorted(human_audit, key=lambda row: row["case_id"])
    output_dir.mkdir(parents=True)
    accepted_path = output_dir / "agreed_labels.jsonl"
    unresolved_path = output_dir / "unresolved.jsonl"
    human_audit_path = output_dir / "human_audit_sample.jsonl"
    write_jsonl(accepted_path, accepted)
    write_jsonl(unresolved_path, unresolved)
    write_jsonl(human_audit_path, human_audit)
    label_counts = Counter("CALL" if row["call"] else "NO_CALL" for row in accepted)
    partition_label_counts = Counter(
        (row["labeling_partition"], "CALL" if row["call"] else "NO_CALL")
        for row in accepted
    )
    tool_counts = Counter(tool for row in accepted for tool in row["agreed_tool_ids"])
    unresolved_reasons = Counter(
        reason for row in unresolved for reason in row["unresolved_reasons"]
    )
    manifest = {
        "schema_version": "toolroutebench-3i4k-petai-label-reconciliation-v1",
        "experiment_id": "3i4k-petai-labeling-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "status": "provisional_dual_session_labels_pending_human_audit",
        "selection_rule": (
            "accept only exact Tool-set agreement from distinct contract and blind "
            "sessions when both mark ambiguous=false"
        ),
        "counts": {
            "queue": len(queue),
            "agreed": len(accepted),
            "unresolved": len(unresolved),
            "agreed_labels": dict(sorted(label_counts.items())),
            "agreed_by_partition_and_label": {
                f"{partition}:{label}": count
                for (partition, label), count in sorted(partition_label_counts.items())
            },
            "agreed_tool_ids": dict(sorted(tool_counts.items())),
            "unresolved_reasons": dict(sorted(unresolved_reasons.items())),
            "human_audit_sample": len(human_audit),
        },
        "human_audit": {
            "seed": seed,
            "quota_per_partition_label": audit_per_partition_label,
            "status": "pending",
        },
        "inputs": {
            "queue": {"path": str(queue_path.resolve()), "sha256": queue_sha},
            "queue_manifest": {
                "path": str(queue_manifest_path.resolve()),
                "sha256": sha256_file(queue_manifest_path),
            },
            "contract_stage": {
                "path": str(contract_manifest_path.resolve()),
                "sha256": sha256_file(contract_manifest_path),
                "git_commit": contract_manifest.get("git_commit"),
            },
            "blind_stage": {
                "path": str(blind_manifest_path.resolve()),
                "sha256": sha256_file(blind_manifest_path),
                "git_commit": blind_manifest.get("git_commit"),
            },
        },
        "artifacts": {
            "agreed_labels": {
                "path": accepted_path.name,
                "records": len(accepted),
                "sha256": sha256_file(accepted_path),
            },
            "unresolved": {
                "path": unresolved_path.name,
                "records": len(unresolved),
                "sha256": sha256_file(unresolved_path),
            },
            "human_audit_sample": {
                "path": human_audit_path.name,
                "records": len(human_audit),
                "sha256": sha256_file(human_audit_path),
            },
        },
    }
    manifest_path = output_dir / "reconciliation_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()


def build_balanced_actionability_rows(
    *,
    agreed_rows: list[dict[str, Any]],
    candidate_no_call_fraction: float,
    seed: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, int]]:
    if not 0.0 <= candidate_no_call_fraction <= 1.0:
        raise ToolRouteBenchError("candidate NO_CALL fraction must be in [0, 1]")
    call_rows = [row for row in agreed_rows if row.get("call") is True]
    candidate_no_call = [
        row
        for row in agreed_rows
        if row.get("call") is False and row.get("labeling_partition") == "candidate"
    ]
    rejected_no_call = [
        row
        for row in agreed_rows
        if row.get("call") is False
        and row.get("labeling_partition") == "rejected_audit"
    ]
    if not call_rows:
        raise ToolRouteBenchError("balanced pool has no agreed CALL rows")
    target = len(call_rows)
    candidate_quota = min(
        len(candidate_no_call), round(target * candidate_no_call_fraction)
    )
    rejected_quota = min(len(rejected_no_call), target - candidate_quota)
    remaining = target - candidate_quota - rejected_quota
    if remaining:
        extra_candidate = min(
            len(candidate_no_call) - candidate_quota,
            remaining,
        )
        candidate_quota += extra_candidate
        remaining -= extra_candidate
    if remaining:
        extra_rejected = min(
            len(rejected_no_call) - rejected_quota,
            remaining,
        )
        rejected_quota += extra_rejected
        remaining -= extra_rejected
    if remaining:
        raise ToolRouteBenchError("not enough agreed NO_CALL rows to balance CALL")

    def choose(rows: list[dict[str, Any]], quota: int, bucket: str) -> list[dict[str, Any]]:
        return sorted(
            rows,
            key=lambda row: _stable_rank(seed, "balanced-pool", bucket, row["case_id"]),
        )[:quota]

    selected_no_call = [
        *choose(candidate_no_call, candidate_quota, "candidate-no-call"),
        *choose(rejected_no_call, rejected_quota, "rejected-no-call"),
    ]
    selected_ids = {row["case_id"] for row in selected_no_call}
    excluded_no_call = [
        row
        for row in (*candidate_no_call, *rejected_no_call)
        if row["case_id"] not in selected_ids
    ]
    balanced = [
        {
            **row,
            "training_label": "CALL" if row["call"] else "NO_CALL",
            "pool_status": "provisional_pending_human_approval",
        }
        for row in (*call_rows, *selected_no_call)
    ]
    balanced = sorted(balanced, key=lambda row: row["case_id"])
    return (
        balanced,
        sorted(excluded_no_call, key=lambda row: row["case_id"]),
        {
            "CALL": len(call_rows),
            "NO_CALL": len(selected_no_call),
            "NO_CALL_candidate": candidate_quota,
            "NO_CALL_rejected_audit": rejected_quota,
        },
    )


def prepare_balanced_3i4k_actionability_pool(
    *,
    reconciliation_manifest_path: Path,
    output_dir: Path,
    candidate_no_call_fraction: float,
    seed: int,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    reconciliation = read_json(reconciliation_manifest_path)
    if (
        reconciliation.get("schema_version")
        != "toolroutebench-3i4k-petai-label-reconciliation-v1"
        or reconciliation.get("status")
        != "provisional_dual_session_labels_pending_human_audit"
    ):
        raise ToolRouteBenchError("unexpected label reconciliation manifest")
    artifact = reconciliation.get("artifacts", {}).get("agreed_labels", {})
    agreed_path = reconciliation_manifest_path.parent / artifact.get("path", "")
    if artifact.get("sha256") != sha256_file(agreed_path):
        raise ToolRouteBenchError("agreed labels differ from reconciliation manifest")
    agreed_rows = read_jsonl(agreed_path)
    if artifact.get("records") != len(agreed_rows):
        raise ToolRouteBenchError("agreed label count differs from manifest")
    case_ids = [row.get("case_id") for row in agreed_rows]
    if (
        not all(isinstance(case_id, str) for case_id in case_ids)
        or len(set(case_ids)) != len(case_ids)
        or any(
            row.get("label_status")
            != "dual_session_agreement_pending_human_audit"
            for row in agreed_rows
        )
    ):
        raise ToolRouteBenchError("agreed labels violate provisional pool contract")
    balanced, excluded_no_call, counts = build_balanced_actionability_rows(
        agreed_rows=agreed_rows,
        candidate_no_call_fraction=candidate_no_call_fraction,
        seed=seed,
    )
    output_dir.mkdir(parents=True)
    pool_path = output_dir / "balanced_pool.jsonl"
    excluded_path = output_dir / "excluded_agreed_no_call.jsonl"
    write_jsonl(pool_path, balanced)
    write_jsonl(excluded_path, excluded_no_call)
    source_label_counts = Counter(
        (row["training_label"], row["source_label_name"]) for row in balanced
    )
    tool_counts = Counter(
        tool for row in balanced if row["call"] for tool in row["agreed_tool_ids"]
    )
    manifest = {
        "schema_version": "toolroutebench-balanced-3i4k-actionability-pool-v1",
        "experiment_id": "3i4k-petai-labeling-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "status": "provisional_balanced_pool_pending_human_approval",
        "selection": {
            "seed": seed,
            "call_policy": "all dual-session agreed CALL rows",
            "no_call_policy": "deterministic sample exactly matching CALL count",
            "candidate_no_call_fraction": candidate_no_call_fraction,
        },
        "counts": {
            "records": len(balanced),
            **counts,
            "excluded_agreed_NO_CALL": len(excluded_no_call),
            "by_label_and_source_type": {
                f"{label}:{source_label}": count
                for (label, source_label), count in sorted(source_label_counts.items())
            },
            "CALL_tool_ids": dict(sorted(tool_counts.items())),
        },
        "inputs": {
            "reconciliation_manifest": {
                "path": str(reconciliation_manifest_path.resolve()),
                "sha256": sha256_file(reconciliation_manifest_path),
            },
            "agreed_labels": {
                "path": str(agreed_path.resolve()),
                "sha256": sha256_file(agreed_path),
            },
        },
        "artifacts": {
            "balanced_pool": {
                "path": pool_path.name,
                "records": len(balanced),
                "sha256": sha256_file(pool_path),
            },
            "excluded_agreed_no_call": {
                "path": excluded_path.name,
                "records": len(excluded_no_call),
                "sha256": sha256_file(excluded_path),
            },
        },
    }
    manifest_path = output_dir / "balanced_pool_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()
