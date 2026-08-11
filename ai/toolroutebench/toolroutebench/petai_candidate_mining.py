from __future__ import annotations

import hashlib
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from .actionability import ACTIONABILITY_CONFIG, load_full_3i4k_splits
from .common import (
    CONFIGS_DIR,
    CONTRACTS_DIR,
    ToolRouteBenchError,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import load_tool_contract
from .regex_baseline import PythonKoreanNativeToolRouter, validate_regex_source


PETAI_MINING_CONFIG = CONFIGS_DIR / "3i4k-petai-candidate-mining.v1.json"
EXPECTED_DIMENSION = 768
EXPECTED_EMBEDDING_CANDIDATE = {
    "candidate_id": "embedding-09",
    "representation": "utterance_prototype",
    "aggregation": "max_similarity",
    "normal_decision": "absolute_tool_threshold",
    "threshold_structure": "cv_shrunk_per_tool",
}


def _stable_rank(seed: int, *values: str) -> str:
    payload = "\x1f".join((str(seed), *values)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def build_mining_pool_rows(
    rows: Iterable[dict[str, Any]], *, seed: int
) -> list[dict[str, Any]]:
    """Preserve 3i4K speech-act metadata without deriving PetAI labels."""
    result: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_utterances: set[str] = set()
    for row in rows:
        utterance = row["utterance"]
        label = int(row["source_label"])
        case_hash = _stable_rank(
            seed,
            "petai-mining",
            str(label),
            utterance,
        )[:16]
        case_id = f"3i4k-mining-train-{label}-{case_hash}"
        if case_id in seen_ids or utterance in seen_utterances:
            raise ToolRouteBenchError("3i4K mining pool contains duplicate identities")
        seen_ids.add(case_id)
        seen_utterances.add(utterance)
        result.append(
            {
                "case_id": case_id,
                "split": "train",
                "utterance": utterance,
                "source": "3i4k",
                "source_split": row["source_split"],
                "source_line": int(row["source_line"]),
                "source_label": label,
                "source_label_name": row["source_label_name"],
            }
        )
    return sorted(result, key=lambda item: item["case_id"])


def prepare_3i4k_petai_mining_pool(
    *,
    source_cache_dir: Path,
    output_dir: Path,
    source_config_path: Path = ACTIONABILITY_CONFIG,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    (
        source_config,
        train_source,
        test_source,
        source_splits,
        source_overlap_removed,
    ) = load_full_3i4k_splits(
        source_cache_dir=source_cache_dir,
        config_path=source_config_path,
    )
    seed = int(source_config["seed"])
    rows = build_mining_pool_rows(source_splits["train"], seed=seed)
    dataset_path = output_dir / "pool.jsonl"
    embedding_inputs_path = output_dir / "embedding_inputs.jsonl"
    output_dir.mkdir(parents=True)
    write_jsonl(dataset_path, rows)
    write_jsonl(
        embedding_inputs_path,
        [
            {
                "embedding_id": f"3i4k-mining:{row['case_id']}",
                "kind": "3i4k_mining_query",
                "case_id": row["case_id"],
                "split": row["split"],
                "text": row["utterance"],
                "source": row["source"],
                "source_label": row["source_label"],
                "source_label_name": row["source_label_name"],
            }
            for row in rows
        ],
    )
    label_counts = Counter(row["source_label_name"] for row in rows)
    source_config_sha = sha256_file(source_config_path)
    manifest = {
        "schema_version": "toolroutebench-3i4k-petai-mining-pool-v1",
        "experiment_id": "3i4k-petai-candidate-mining-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "role": "unlabeled_petai_candidate_pool",
        "split": "train",
        "label_policy": (
            "3i4K speech-act labels are provenance only; this pool contains no "
            "derived PetAI CALL or NO_CALL labels"
        ),
        "seed": seed,
        "sources": {
            "train_validation": {
                **source_config["sources"]["train_validation"],
                "cached_path": str(train_source.resolve()),
            },
            "test": {
                **source_config["sources"]["test"],
                "cached_path": str(test_source.resolve()),
            },
            "official_test_overlap_removed": source_overlap_removed,
        },
        "counts": {
            "records": len(rows),
            "by_source_label": dict(sorted(label_counts.items())),
        },
        "artifacts": {
            "pool": {
                "path": dataset_path.name,
                "sha256": sha256_file(dataset_path),
            },
            "embedding_inputs": {
                "path": embedding_inputs_path.name,
                "sha256": sha256_file(embedding_inputs_path),
            },
            "source_config": {
                "path": str(source_config_path.resolve()),
                "sha256": source_config_sha,
            },
        },
    }
    manifest_path = output_dir / "pool_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()


def select_candidate_evidence(
    *,
    case_ids: list[str],
    scores: dict[str, list[float]],
    tool_order: list[str],
    thresholds: dict[str, float],
    top_k_per_tool: int,
    relaxed_threshold_margin: float,
    regex_predictions: dict[str, list[str]],
    gemma_predictions: dict[str, list[str]] | None = None,
) -> dict[str, dict[str, list[str]]]:
    if top_k_per_tool <= 0:
        raise ToolRouteBenchError("top_k_per_tool must be positive")
    if not 0.0 <= relaxed_threshold_margin < 1.0:
        raise ToolRouteBenchError("relaxed threshold margin must be in [0, 1)")
    expected_ids = set(case_ids)
    if set(scores) != set(tool_order):
        raise ToolRouteBenchError("score matrix differs from Tool order")
    if set(regex_predictions) != expected_ids:
        raise ToolRouteBenchError("Regex predictions differ from mining pool")
    if gemma_predictions is not None and not set(gemma_predictions) <= expected_ids:
        raise ToolRouteBenchError("Gemma predictions contain unknown mining cases")
    evidence: dict[str, dict[str, list[str]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for tool in tool_order:
        values = scores[tool]
        if len(values) != len(case_ids):
            raise ToolRouteBenchError("score vector length differs from mining pool")
        ranked = sorted(
            range(len(case_ids)),
            key=lambda index: (-values[index], case_ids[index]),
        )
        for index in ranked[: min(top_k_per_tool, len(ranked))]:
            evidence[case_ids[index]][tool].append("embedding_top_k")
        relaxed = float(thresholds[tool]) - relaxed_threshold_margin
        for index, value in enumerate(values):
            if value >= relaxed - 1e-12:
                evidence[case_ids[index]][tool].append("relaxed_threshold")
    for case_id, tools in regex_predictions.items():
        for tool in tools:
            if tool not in tool_order:
                raise ToolRouteBenchError("Regex prediction contains an unknown Tool")
            evidence[case_id][tool].append("regex")
    if gemma_predictions is not None:
        for case_id, tools in gemma_predictions.items():
            for tool in tools:
                if tool not in tool_order:
                    raise ToolRouteBenchError(
                        "Gemma prediction contains an unknown Tool"
                    )
                evidence[case_id][tool].append("gemma_prompt_router")
    return {
        case_id: {
            tool: sorted(set(reasons))
            for tool, reasons in sorted(
                tools.items(), key=lambda item: tool_order.index(item[0])
            )
        }
        for case_id, tools in evidence.items()
    }


def select_rejected_audit_sample(
    *,
    pool_rows: list[dict[str, Any]],
    selected_case_ids: set[str],
    per_source_label: int,
    seed: int,
) -> list[dict[str, Any]]:
    if per_source_label <= 0:
        raise ToolRouteBenchError("rejected audit quota must be positive")
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in pool_rows:
        if row["case_id"] not in selected_case_ids:
            grouped[int(row["source_label"])].append(row)
    sample: list[dict[str, Any]] = []
    for label in range(7):
        candidates = sorted(
            grouped.get(label, []),
            key=lambda row: _stable_rank(
                seed,
                "rejected-audit",
                str(label),
                row["case_id"],
            ),
        )
        if len(candidates) < per_source_label:
            raise ToolRouteBenchError(
                f"rejected source label {label} has {len(candidates)} rows, "
                f"needs {per_source_label}"
            )
        sample.extend(candidates[:per_source_label])
    return sorted(sample, key=lambda row: row["case_id"])


def _verified_manifest_rows(
    *, path: Path, manifest_path: Path, artifact_key: str
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest = read_json(manifest_path)
    expected = manifest.get("artifacts", {}).get(artifact_key, {}).get("sha256")
    if expected != sha256_file(path):
        raise ToolRouteBenchError(f"{artifact_key} differs from its manifest")
    return read_jsonl(path), manifest


def _verified_embedding_rows(
    *, path: Path, manifest_path: Path, label: str
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    manifest = read_json(manifest_path)
    if manifest.get("output", {}).get("sha256") != sha256_file(path):
        raise ToolRouteBenchError(f"{label} embeddings differ from their manifest")
    return read_jsonl(path), manifest


def _validate_vector(value: Any, *, context: str) -> list[float]:
    if (
        not isinstance(value, list)
        or len(value) != EXPECTED_DIMENSION
        or not all(
            isinstance(item, (int, float)) and math.isfinite(item)
            for item in value
        )
    ):
        raise ToolRouteBenchError(f"{context} has an invalid embedding")
    return [float(item) for item in value]


def _validate_selection_config(selection: Any) -> dict[str, Any]:
    if not isinstance(selection, dict):
        raise ToolRouteBenchError("3i4K mining selection config is invalid")
    required = {
        "top_k_per_tool",
        "relaxed_threshold_margin",
        "include_regex",
        "include_optional_gemma_predictions",
        "rejected_audit_per_source_label",
    }
    if set(selection) != required:
        raise ToolRouteBenchError("3i4K mining selection keys violate the contract")
    if not isinstance(selection["include_regex"], bool) or not isinstance(
        selection["include_optional_gemma_predictions"], bool
    ):
        raise ToolRouteBenchError("3i4K mining selection flags must be Boolean")
    return selection


def _embedding_model_identity(manifest: dict[str, Any]) -> tuple[Any, ...]:
    model = manifest.get("model")
    if not isinstance(model, dict):
        raise ToolRouteBenchError("embedding manifest has no model identity")
    return (
        model.get("id"),
        model.get("revision"),
        model.get("sha256"),
        model.get("sequence_length"),
        model.get("dimension"),
        model.get("prefix"),
    )


def _load_optional_gemma_predictions(
    path: Path | None, *, valid_case_ids: set[str]
) -> dict[str, list[str]] | None:
    if path is None:
        return None
    predictions: dict[str, list[str]] = {}
    tools = set(load_tool_contract()["tool_order"])
    for row in read_jsonl(path):
        case_id = row.get("case_id")
        predicted = row.get("predicted_tool_ids")
        if (
            not isinstance(case_id, str)
            or case_id not in valid_case_ids
            or case_id in predictions
            or not isinstance(predicted, list)
            or not all(isinstance(tool, str) and tool in tools for tool in predicted)
        ):
            raise ToolRouteBenchError("Gemma mining predictions are invalid")
        predictions[case_id] = predicted
    return predictions


def mine_3i4k_petai_candidates(
    *,
    pool_path: Path,
    pool_manifest_path: Path,
    query_embeddings_path: Path,
    query_embedding_manifest_path: Path,
    prototype_embeddings_path: Path,
    prototype_embedding_manifest_path: Path,
    selected_candidate_path: Path,
    output_dir: Path,
    config_path: Path = PETAI_MINING_CONFIG,
    gemma_predictions_path: Path | None = None,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    config = read_json(config_path)
    expected_config = {
        "schema_version": "toolroutebench-3i4k-petai-mining-config-v1",
        "experiment_id": "3i4k-petai-candidate-mining-v1",
        "source_split": "train",
    }
    if any(config.get(key) != value for key, value in expected_config.items()):
        raise ToolRouteBenchError("3i4K PetAI mining config violates its contract")
    pool_rows, pool_manifest = _verified_manifest_rows(
        path=pool_path,
        manifest_path=pool_manifest_path,
        artifact_key="pool",
    )
    if (
        pool_manifest.get("role") != "unlabeled_petai_candidate_pool"
        or pool_manifest.get("split") != "train"
    ):
        raise ToolRouteBenchError("3i4K mining pool has an unexpected role")
    query_rows, query_manifest = _verified_embedding_rows(
        path=query_embeddings_path,
        manifest_path=query_embedding_manifest_path,
        label="query",
    )
    prototype_rows, prototype_manifest = _verified_embedding_rows(
        path=prototype_embeddings_path,
        manifest_path=prototype_embedding_manifest_path,
        label="prototype",
    )
    if _embedding_model_identity(query_manifest) != _embedding_model_identity(
        prototype_manifest
    ):
        raise ToolRouteBenchError(
            "query and prototype embeddings use different model identities"
        )
    selected_candidate = read_json(selected_candidate_path)
    if any(
        selected_candidate.get(key) != value
        for key, value in EXPECTED_EMBEDDING_CANDIDATE.items()
    ):
        raise ToolRouteBenchError("selected Embedding candidate is not embedding-09")
    tool_order = load_tool_contract()["tool_order"]
    thresholds = selected_candidate.get("thresholds")
    if not isinstance(thresholds, dict) or set(thresholds) != set(tool_order):
        raise ToolRouteBenchError("selected candidate thresholds differ from Tool contract")
    pool_by_case = {row["case_id"]: row for row in pool_rows}
    if len(pool_by_case) != len(pool_rows):
        raise ToolRouteBenchError("3i4K mining pool contains duplicate case IDs")
    query_by_case: dict[str, list[float]] = {}
    for row in query_rows:
        if row.get("kind") != "3i4k_mining_query":
            continue
        case_id = row.get("case_id")
        if (
            not isinstance(case_id, str)
            or case_id in query_by_case
            or row.get("text") != pool_by_case.get(case_id, {}).get("utterance")
        ):
            raise ToolRouteBenchError("query embeddings differ from mining pool")
        query_by_case[case_id] = _validate_vector(
            row.get("embedding"), context=f"query {case_id}"
        )
    if set(query_by_case) != set(pool_by_case):
        raise ToolRouteBenchError("query embeddings do not cover the mining pool")
    positive_vectors: dict[str, list[list[float]]] = defaultdict(list)
    for row in prototype_rows:
        if row.get("kind") == "positive_prototype":
            tool = row.get("tool_id")
            if tool in tool_order:
                positive_vectors[tool].append(
                    _validate_vector(
                        row.get("embedding"), context=f"prototype {tool}"
                    )
                )
    if any(not positive_vectors.get(tool) for tool in tool_order):
        raise ToolRouteBenchError("prototype embeddings are missing a Tool")
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    ordered_pool = sorted(pool_rows, key=lambda row: row["case_id"])
    case_ids = [row["case_id"] for row in ordered_pool]
    query_matrix = np.asarray(
        [query_by_case[case_id] for case_id in case_ids], dtype=np.float32
    )
    scores: dict[str, list[float]] = {}
    for tool in tool_order:
        prototypes = np.asarray(positive_vectors[tool], dtype=np.float32)
        values = np.max(query_matrix @ prototypes.T, axis=1)
        scores[tool] = [float(value) for value in values]
    selection = _validate_selection_config(config.get("selection"))
    if selection["include_regex"]:
        regex_router = PythonKoreanNativeToolRouter()
        regex_predictions = {
            row["case_id"]: regex_router.route(row["utterance"])
            for row in ordered_pool
        }
    else:
        regex_predictions = {row["case_id"]: [] for row in ordered_pool}
    if gemma_predictions_path is not None and not selection[
        "include_optional_gemma_predictions"
    ]:
        raise ToolRouteBenchError("Gemma predictions are disabled by mining config")
    gemma_predictions = _load_optional_gemma_predictions(
        gemma_predictions_path,
        valid_case_ids=set(case_ids),
    )
    evidence = select_candidate_evidence(
        case_ids=case_ids,
        scores=scores,
        tool_order=tool_order,
        thresholds={tool: float(thresholds[tool]) for tool in tool_order},
        top_k_per_tool=int(selection["top_k_per_tool"]),
        relaxed_threshold_margin=float(selection["relaxed_threshold_margin"]),
        regex_predictions=regex_predictions,
        gemma_predictions=gemma_predictions,
    )
    score_rows: list[dict[str, Any]] = []
    candidates: list[dict[str, Any]] = []
    score_by_case: dict[str, dict[str, float]] = {}
    for index, row in enumerate(ordered_pool):
        case_id = row["case_id"]
        tool_scores = {tool: scores[tool][index] for tool in tool_order}
        score_by_case[case_id] = tool_scores
        margins = {
            tool: tool_scores[tool] - float(thresholds[tool])
            for tool in tool_order
        }
        score_row = {
            **row,
            "router_scores": tool_scores,
            "router_margins": margins,
            "regex_tool_ids": regex_predictions[case_id],
            "gemma_tool_ids": (
                gemma_predictions.get(case_id, [])
                if gemma_predictions is not None
                else []
            ),
        }
        score_rows.append(score_row)
        tool_evidence = evidence.get(case_id)
        if tool_evidence:
            candidates.append(
                {
                    **score_row,
                    "candidate_tool_ids": [
                        tool for tool in tool_order if tool in tool_evidence
                    ],
                    "selection_evidence": tool_evidence,
                    "audit_status": "pending",
                }
            )
    selected_ids = {row["case_id"] for row in candidates}
    rejected_sample_base = select_rejected_audit_sample(
        pool_rows=ordered_pool,
        selected_case_ids=selected_ids,
        per_source_label=int(selection["rejected_audit_per_source_label"]),
        seed=int(config["seed"]),
    )
    rejected_sample = [
        {
            **row,
            "router_scores": score_by_case[row["case_id"]],
            "router_margins": {
                tool: score_by_case[row["case_id"]][tool]
                - float(thresholds[tool])
                for tool in tool_order
            },
            "selection_reason": "rejected_random_audit",
            "audit_status": "pending",
        }
        for row in rejected_sample_base
    ]
    output_dir.mkdir(parents=True)
    scores_path = output_dir / "scores.jsonl"
    candidates_path = output_dir / "candidates.jsonl"
    rejected_path = output_dir / "rejected_audit_sample.jsonl"
    write_jsonl(scores_path, score_rows)
    write_jsonl(candidates_path, candidates)
    write_jsonl(rejected_path, rejected_sample)
    candidate_label_counts = Counter(
        row["source_label_name"] for row in candidates
    )
    candidate_tool_counts = Counter(
        tool for row in candidates for tool in row["candidate_tool_ids"]
    )
    reason_counts = Counter(
        reason
        for row in candidates
        for reasons in row["selection_evidence"].values()
        for reason in reasons
    )
    manifest = {
        "schema_version": "toolroutebench-3i4k-petai-candidate-mining-v1",
        "experiment_id": config["experiment_id"],
        "created_at": utc_now(),
        "git_commit": commit,
        "status": "candidate_search_only_unlabeled",
        "selection": selection,
        "counts": {
            "pool": len(ordered_pool),
            "candidates": len(candidates),
            "rejected": len(ordered_pool) - len(candidates),
            "rejected_audit_sample": len(rejected_sample),
            "candidates_by_source_label": dict(
                sorted(candidate_label_counts.items())
            ),
            "candidate_tool_ids": dict(sorted(candidate_tool_counts.items())),
            "selection_reasons": dict(sorted(reason_counts.items())),
        },
        "inputs": {
            "pool": {
                "path": str(pool_path.resolve()),
                "sha256": sha256_file(pool_path),
                "manifest_path": str(pool_manifest_path.resolve()),
                "manifest_sha256": sha256_file(pool_manifest_path),
            },
            "query_embeddings": {
                "path": str(query_embeddings_path.resolve()),
                "sha256": sha256_file(query_embeddings_path),
                "manifest_path": str(query_embedding_manifest_path.resolve()),
                "manifest_sha256": sha256_file(query_embedding_manifest_path),
                "model": query_manifest.get("model"),
            },
            "prototype_embeddings": {
                "path": str(prototype_embeddings_path.resolve()),
                "sha256": sha256_file(prototype_embeddings_path),
                "manifest_path": str(prototype_embedding_manifest_path.resolve()),
                "manifest_sha256": sha256_file(prototype_embedding_manifest_path),
                "model": prototype_manifest.get("model"),
            },
            "embedding_candidate": {
                "path": str(selected_candidate_path.resolve()),
                "sha256": sha256_file(selected_candidate_path),
            },
            "gemma_predictions": (
                {
                    "path": str(gemma_predictions_path.resolve()),
                    "sha256": sha256_file(gemma_predictions_path),
                    "records": len(gemma_predictions or {}),
                }
                if gemma_predictions_path is not None
                else None
            ),
            "config": {
                "path": str(config_path.resolve()),
                "sha256": sha256_file(config_path),
            },
            "tool_contract": {
                "path": str((CONTRACTS_DIR / "tools.v1.json").resolve()),
                "sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
            },
            "regex_source": validate_regex_source(),
        },
        "artifacts": {
            "scores": {
                "path": scores_path.name,
                "records": len(score_rows),
                "sha256": sha256_file(scores_path),
            },
            "candidates": {
                "path": candidates_path.name,
                "records": len(candidates),
                "sha256": sha256_file(candidates_path),
            },
            "rejected_audit_sample": {
                "path": rejected_path.name,
                "records": len(rejected_sample),
                "sha256": sha256_file(rejected_path),
            },
        },
    }
    manifest_path = output_dir / "mining_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()
