from __future__ import annotations

import hashlib
import math
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .common import (
    ToolRouteBenchError,
    git_commit,
    iter_jsonl,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)

SPLITS = ("train", "validation", "test")
EXPECTED_DIMENSION = 768


def _stable_rank(seed: int, *values: str) -> str:
    payload = "\x1f".join((str(seed), *values)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _canonical_utterance(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def _stratum(row: dict[str, Any]) -> str:
    if row["call"]:
        tool_ids = row.get("agreed_tool_ids")
        if not isinstance(tool_ids, list) or not tool_ids:
            raise ToolRouteBenchError("CALL row has no agreed Tool ID")
        return f"CALL:{'+'.join(sorted(str(tool_id) for tool_id in tool_ids))}"
    return (
        f"NO_CALL:{row.get('labeling_partition', 'unknown')}:"
        f"{row.get('source_label_name', 'unknown')}"
    )


def _split_targets(total: int) -> dict[str, int]:
    fractions = {"train": 0.8, "validation": 0.1, "test": 0.1}
    targets = {name: math.floor(total * fraction) for name, fraction in fractions.items()}
    remaining = total - sum(targets.values())
    priorities = sorted(
        SPLITS,
        key=lambda name: (-(total * fractions[name] - targets[name]), SPLITS.index(name)),
    )
    for name in priorities[:remaining]:
        targets[name] += 1
    return targets


def _initial_stratum_counts(total: int) -> dict[str, int]:
    if total == 1:
        return {"train": 1, "validation": 0, "test": 0}
    if total == 2:
        return {"train": 1, "validation": 0, "test": 1}
    validation = max(1, round(total * 0.1))
    test = max(1, round(total * 0.1))
    return {
        "train": total - validation - test,
        "validation": validation,
        "test": test,
    }


def _deduplicate_and_balance(
    rows: list[dict[str, Any]],
    *,
    seed: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    seen_ids: set[str] = set()
    canonical_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        case_id = row.get("case_id")
        utterance = row.get("utterance")
        call = row.get("call")
        training_label = row.get("training_label")
        if (
            not isinstance(case_id, str)
            or not isinstance(utterance, str)
            or not isinstance(call, bool)
            or training_label != ("CALL" if call else "NO_CALL")
        ):
            raise ToolRouteBenchError("balanced pool row violates label contract")
        if case_id in seen_ids:
            raise ToolRouteBenchError(f"duplicate balanced pool case ID: {case_id}")
        seen_ids.add(case_id)
        canonical = _canonical_utterance(utterance)
        if not canonical:
            raise ToolRouteBenchError(f"empty canonical utterance: {case_id}")
        canonical_groups[canonical].append(row)

    kept: list[dict[str, Any]] = []
    exclusions: list[dict[str, Any]] = []
    for canonical, group in sorted(canonical_groups.items()):
        labels = {row["training_label"] for row in group}
        if len(labels) != 1:
            raise ToolRouteBenchError(
                f"canonical duplicate has conflicting labels: {canonical}"
            )
        ordered = sorted(
            group,
            key=lambda row: _stable_rank(seed, "canonical", row["case_id"]),
        )
        kept.append(ordered[0])
        exclusions.extend(
            {
                "case_id": row["case_id"],
                "kept_case_id": ordered[0]["case_id"],
                "reason": "canonical_duplicate",
            }
            for row in ordered[1:]
        )

    by_label: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in kept:
        by_label[row["training_label"]].append(row)
    if set(by_label) != {"CALL", "NO_CALL"}:
        raise ToolRouteBenchError("deduplicated pool must contain both binary labels")
    balanced_count = min(len(by_label["CALL"]), len(by_label["NO_CALL"]))
    balanced: list[dict[str, Any]] = []
    for label in ("CALL", "NO_CALL"):
        ordered = sorted(
            by_label[label],
            key=lambda row: _stable_rank(seed, "class-balance", label, row["case_id"]),
        )
        balanced.extend(ordered[:balanced_count])
        exclusions.extend(
            {
                "case_id": row["case_id"],
                "kept_case_id": None,
                "reason": "post_dedup_class_balance",
            }
            for row in ordered[balanced_count:]
        )
    return balanced, sorted(exclusions, key=lambda row: row["case_id"])


def _assign_label_rows(
    rows: list[dict[str, Any]],
    *,
    seed: int,
    label: str,
) -> dict[str, str]:
    strata: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        strata[_stratum(row)].append(row)
    assignments: dict[str, str] = {}
    for stratum, stratum_rows in sorted(strata.items()):
        ordered = sorted(
            stratum_rows,
            key=lambda row: _stable_rank(seed, "split", label, stratum, row["case_id"]),
        )
        counts = _initial_stratum_counts(len(ordered))
        start = 0
        for split in SPLITS:
            stop = start + counts[split]
            for row in ordered[start:stop]:
                assignments[row["case_id"]] = split
            start = stop

    targets = _split_targets(len(rows))
    row_by_id = {row["case_id"]: row for row in rows}
    while True:
        counts = Counter(assignments.values())
        excess = [split for split in SPLITS if counts[split] > targets[split]]
        deficit = [split for split in SPLITS if counts[split] < targets[split]]
        if not excess and not deficit:
            break
        if not excess or not deficit:
            raise ToolRouteBenchError(f"could not rebalance {label} split counts")
        source = max(excess, key=lambda split: counts[split] - targets[split])
        destination = max(deficit, key=lambda split: targets[split] - counts[split])
        stratum_split_counts = Counter(
            (_stratum(row_by_id[case_id]), split)
            for case_id, split in assignments.items()
        )
        stratum_totals = Counter(_stratum(row) for row in rows)
        candidates = []
        for case_id, split in assignments.items():
            if split != source:
                continue
            stratum = _stratum(row_by_id[case_id])
            source_count = stratum_split_counts[(stratum, source)]
            stratum_total = stratum_totals[stratum]
            minimum = 0
            if stratum_total >= 3:
                minimum = 1
            elif stratum_total == 2 and source in {"train", "test"}:
                minimum = 1
            elif stratum_total == 1 and source == "train":
                minimum = 1
            if source_count <= minimum:
                continue
            candidates.append(case_id)
        if not candidates:
            raise ToolRouteBenchError(f"could not preserve strata while balancing {label}")
        chosen = min(
            candidates,
            key=lambda case_id: (
                0
                if stratum_split_counts[(_stratum(row_by_id[case_id]), destination)]
                else 1,
                -stratum_totals[_stratum(row_by_id[case_id])],
                _stable_rank(seed, "rebalance", source, destination, case_id),
            ),
        )
        assignments[chosen] = destination
    return assignments


def build_labeled_actionability_splits(
    *,
    rows: list[dict[str, Any]],
    seed: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    balanced, exclusions = _deduplicate_and_balance(rows, seed=seed)
    assignments: dict[str, str] = {}
    for label in ("CALL", "NO_CALL"):
        label_rows = [row for row in balanced if row["training_label"] == label]
        assignments.update(_assign_label_rows(label_rows, seed=seed, label=label))
    split_rows = [
        {
            **row,
            "split": assignments[row["case_id"]],
            "label": row["training_label"],
            "dataset_status": "experimental_user_authorized_provisional_labels",
        }
        for row in balanced
    ]
    split_order = {name: index for index, name in enumerate(SPLITS)}
    return (
        sorted(split_rows, key=lambda row: (split_order[row["split"]], row["case_id"])),
        exclusions,
    )


def prepare_labeled_3i4k_actionability_dataset(
    *,
    balanced_pool_manifest_path: Path,
    source_embeddings_path: Path,
    source_embedding_manifest_path: Path,
    output_dir: Path,
    seed: int,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    pool_manifest = read_json(balanced_pool_manifest_path)
    if (
        pool_manifest.get("schema_version")
        != "toolroutebench-balanced-3i4k-actionability-pool-v1"
        or pool_manifest.get("status")
        != "provisional_balanced_pool_pending_human_approval"
    ):
        raise ToolRouteBenchError("unexpected balanced pool manifest")
    pool_artifact = pool_manifest.get("artifacts", {}).get("balanced_pool", {})
    pool_path = balanced_pool_manifest_path.parent / str(pool_artifact.get("path", ""))
    if pool_artifact.get("sha256") != sha256_file(pool_path):
        raise ToolRouteBenchError("balanced pool differs from its manifest")
    pool_rows = read_jsonl(pool_path)
    if pool_artifact.get("records") != len(pool_rows):
        raise ToolRouteBenchError("balanced pool count differs from its manifest")
    split_rows, exclusions = build_labeled_actionability_splits(rows=pool_rows, seed=seed)

    embedding_manifest = read_json(source_embedding_manifest_path)
    if embedding_manifest.get("output", {}).get("sha256") != sha256_file(
        source_embeddings_path
    ):
        raise ToolRouteBenchError("source embeddings differ from their manifest")
    required_ids = {row["case_id"] for row in split_rows}
    source_vectors: dict[str, dict[str, Any]] = {}
    for row in iter_jsonl(source_embeddings_path):
        case_id = row.get("case_id")
        if case_id not in required_ids:
            continue
        if case_id in source_vectors:
            raise ToolRouteBenchError(f"duplicate source embedding: {case_id}")
        source_vectors[case_id] = row
    missing = required_ids - source_vectors.keys()
    if missing:
        raise ToolRouteBenchError(f"missing source embeddings: {sorted(missing)[:3]}")

    derived_embeddings: list[dict[str, Any]] = []
    for row in split_rows:
        source = source_vectors[row["case_id"]]
        vector = source.get("embedding")
        if source.get("text") != row["utterance"]:
            raise ToolRouteBenchError(f"embedding text mismatch: {row['case_id']}")
        if (
            not isinstance(vector, list)
            or len(vector) != EXPECTED_DIMENSION
            or not all(
                isinstance(value, (int, float)) and math.isfinite(value)
                for value in vector
            )
        ):
            raise ToolRouteBenchError(f"invalid embedding vector: {row['case_id']}")
        derived_embeddings.append(
            {
                "embedding_id": f"actionability-labeled:{row['case_id']}",
                "kind": "actionability_example",
                "case_id": row["case_id"],
                "split": row["split"],
                "text": row["utterance"],
                "call": row["call"],
                "label": row["training_label"],
                "source": row["source"],
                "source_label": row["source_label"],
                "source_label_name": row["source_label_name"],
                "tool_ids": row["agreed_tool_ids"],
                "labeling_partition": row["labeling_partition"],
                "embedding": vector,
            }
        )

    output_dir.mkdir(parents=True)
    dataset_path = output_dir / "dataset.jsonl"
    embeddings_path = output_dir / "embeddings.jsonl"
    exclusions_path = output_dir / "exclusions.jsonl"
    write_jsonl(dataset_path, split_rows)
    write_jsonl(embeddings_path, derived_embeddings)
    write_jsonl(exclusions_path, exclusions)

    counts_by_split = Counter(row["split"] for row in split_rows)
    counts_by_label = {
        split: Counter(
            row["training_label"] for row in split_rows if row["split"] == split
        )
        for split in SPLITS
    }
    tool_counts = {
        split: Counter(
            tool_id
            for row in split_rows
            if row["split"] == split and row["call"]
            for tool_id in row["agreed_tool_ids"]
        )
        for split in SPLITS
    }
    derived_embedding_manifest = {
        "schema_version": "toolroutebench-derived-embedding-run-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "derivation": {
            "source_embedding_manifest": str(source_embedding_manifest_path.resolve()),
            "source_embedding_sha256": sha256_file(source_embeddings_path),
            "inference_reused": True,
        },
        "model": embedding_manifest.get("model"),
        "runtime": embedding_manifest.get("runtime"),
        "output": {
            "path": embeddings_path.name,
            "records": len(derived_embeddings),
            "sha256": sha256_file(embeddings_path),
        },
    }
    derived_embedding_manifest_path = output_dir / "embedding_manifest.json"
    write_json(derived_embedding_manifest_path, derived_embedding_manifest)

    manifest = {
        "schema_version": "toolroutebench-labeled-actionability-dataset-v1",
        "experiment_id": "3i4k-petai-contract-actionability-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "status": "experimental_user_authorized_provisional_labels",
        "split_contract": {
            "seed": seed,
            "fractions": {"train": 0.8, "validation": 0.1, "test": 0.1},
            "stratification": "binary label then Tool signature or NO_CALL source type",
            "canonical_deduplication": "NFKC casefold and remove non-alphanumeric",
            "threshold_selection": "configured by the downstream trainer",
            "holdout_policy": "test and PetAI holdout are forbidden for threshold selection",
        },
        "counts": {
            "records": len(split_rows),
            "excluded": len(exclusions),
            "by_split": dict(counts_by_split),
            "by_split_and_label": {
                split: dict(counts) for split, counts in counts_by_label.items()
            },
            "CALL_tool_ids_by_split": {
                split: dict(sorted(counts.items())) for split, counts in tool_counts.items()
            },
            "exclusion_reasons": dict(
                Counter(row["reason"] for row in exclusions)
            ),
        },
        "inputs": {
            "balanced_pool_manifest": {
                "path": str(balanced_pool_manifest_path.resolve()),
                "sha256": sha256_file(balanced_pool_manifest_path),
            },
            "balanced_pool": {
                "path": str(pool_path.resolve()),
                "sha256": sha256_file(pool_path),
            },
            "source_embedding_manifest": {
                "path": str(source_embedding_manifest_path.resolve()),
                "sha256": sha256_file(source_embedding_manifest_path),
            },
        },
        "artifacts": {
            "dataset": {"path": dataset_path.name, "sha256": sha256_file(dataset_path)},
            "embeddings": {
                "path": embeddings_path.name,
                "sha256": sha256_file(embeddings_path),
            },
            "embedding_manifest": {
                "path": derived_embedding_manifest_path.name,
                "sha256": sha256_file(derived_embedding_manifest_path),
            },
            "exclusions": {
                "path": exclusions_path.name,
                "records": len(exclusions),
                "sha256": sha256_file(exclusions_path),
            },
        },
    }
    manifest_path = output_dir / "dataset_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()
