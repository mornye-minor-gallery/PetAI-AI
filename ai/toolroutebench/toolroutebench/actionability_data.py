from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .common import ToolRouteBenchError, read_jsonl

EXPECTED_DIMENSION = 768


@dataclass(frozen=True)
class BinarySplit:
    name: str
    ids: list[str]
    utterances: list[str]
    features: Any
    targets: Any
    metadata: list[dict[str, Any]]
    exclusions: list[dict[str, Any]] = field(default_factory=list)


def _validated_identity_vector(
    row: dict[str, Any],
    *,
    context: str,
) -> tuple[str, str, list[float]]:
    case_id = row.get("case_id")
    utterance = row.get("text")
    vector = row.get("embedding")
    if not isinstance(case_id, str) or not isinstance(utterance, str):
        raise ToolRouteBenchError(f"{context} row has invalid identity")
    if (
        not isinstance(vector, list)
        or len(vector) != EXPECTED_DIMENSION
        or not all(
            isinstance(value, (int, float)) and math.isfinite(value)
            for value in vector
        )
    ):
        raise ToolRouteBenchError(f"{context} row has invalid vector")
    return case_id, utterance, vector


def _validated_embedding_fields(
    row: dict[str, Any],
    *,
    context: str,
) -> tuple[str, str, list[float], bool]:
    case_id, utterance, vector = _validated_identity_vector(
        row,
        context=context,
    )
    call = row.get("call")
    if not isinstance(call, bool):
        raise ToolRouteBenchError(f"{context} row has invalid binary label")
    return case_id, utterance, vector, call


def _load_public_splits(embeddings_path: Path) -> dict[str, BinarySplit]:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in read_jsonl(embeddings_path):
        if row.get("kind") != "actionability_example":
            continue
        grouped[row["split"]].append(row)
    splits: dict[str, BinarySplit] = {}
    seen_ids: set[str] = set()
    seen_utterances: set[str] = set()
    for split_name in ("train", "validation", "test"):
        rows = grouped.get(split_name, [])
        if not rows:
            raise ToolRouteBenchError(f"actionability embedding split is empty: {split_name}")
        ids: list[str] = []
        utterances: list[str] = []
        features: list[list[float]] = []
        targets: list[int] = []
        metadata: list[dict[str, Any]] = []
        for row in rows:
            case_id, utterance, vector, call = _validated_embedding_fields(
                row,
                context="actionability embedding",
            )
            if case_id in seen_ids or utterance in seen_utterances:
                raise ToolRouteBenchError("actionability embedding rows cross split boundaries")
            seen_ids.add(case_id)
            seen_utterances.add(utterance)
            ids.append(case_id)
            utterances.append(utterance)
            features.append(vector)
            targets.append(int(call))
            metadata.append(
                {
                    "source": row.get("source"),
                    "source_label": row.get("source_label"),
                    "source_label_name": row.get("source_label_name"),
                    "tool_ids": row.get("tool_ids"),
                }
            )
        splits[split_name] = BinarySplit(
            name=split_name,
            ids=ids,
            utterances=utterances,
            features=np.asarray(features, dtype=np.float32),
            targets=np.asarray(targets, dtype=np.int64),
            metadata=metadata,
        )
    return splits


def _load_auxiliary_train(embeddings_path: Path) -> BinarySplit:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    rows = [
        row
        for row in read_jsonl(embeddings_path)
        if row.get("kind") == "actionability_auxiliary"
    ]
    if not rows:
        raise ToolRouteBenchError("actionability auxiliary embedding set is empty")
    ids: list[str] = []
    utterances: list[str] = []
    features: list[list[float]] = []
    targets: list[int] = []
    metadata: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_utterances: set[str] = set()
    for row in rows:
        if row.get("split") != "train":
            raise ToolRouteBenchError("actionability auxiliary rows must be train-only")
        case_id, utterance, vector, call = _validated_embedding_fields(
            row,
            context="actionability auxiliary",
        )
        if case_id in seen_ids or utterance in seen_utterances:
            raise ToolRouteBenchError("actionability auxiliary rows are duplicated")
        if call:
            raise ToolRouteBenchError(
                "actionability hard-negative auxiliary rows must be NO_CALL"
            )
        seen_ids.add(case_id)
        seen_utterances.add(utterance)
        ids.append(case_id)
        utterances.append(utterance)
        features.append(vector)
        targets.append(0)
        metadata.append(
            {
                "source": row.get("source"),
                "source_dataset": row.get("source_dataset"),
                "source_label": row.get("source_label"),
                "source_label_name": row.get("source_label_name"),
            }
        )
    return BinarySplit(
        name="auxiliary_train",
        ids=ids,
        utterances=utterances,
        features=np.asarray(features, dtype=np.float32),
        targets=np.asarray(targets, dtype=np.int64),
        metadata=metadata,
    )


def _load_petai_track(
    *,
    name: str,
    dataset_path: Path,
    embeddings_path: Path,
) -> BinarySplit:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    embedding_rows = {
        row["case_id"]: row
        for row in read_jsonl(embeddings_path)
        if row.get("kind") == "query" and isinstance(row.get("case_id"), str)
    }
    ids: list[str] = []
    utterances: list[str] = []
    features: list[list[float]] = []
    targets: list[int] = []
    metadata: list[dict[str, Any]] = []
    for row in read_jsonl(dataset_path):
        case_id = row.get("case_id")
        utterance = row.get("utterance")
        if not isinstance(case_id, str) or not isinstance(utterance, str):
            raise ToolRouteBenchError(f"{name} has an invalid dataset row")
        embedded = embedding_rows.get(case_id)
        if embedded is None or embedded.get("text") != utterance:
            raise ToolRouteBenchError(f"{name} is missing matching embedding for {case_id}")
        vector = embedded.get("embedding")
        if not isinstance(vector, list) or len(vector) != EXPECTED_DIMENSION:
            raise ToolRouteBenchError(f"{name} has an invalid embedding for {case_id}")
        ids.append(case_id)
        utterances.append(utterance)
        features.append(vector)
        targets.append(int(bool(row.get("gold_tool_ids"))))
        metadata.append(
            {
                "difficulty": row.get("difficulty"),
                "contrast_tool_id": row.get("contrast_tool_id"),
                "expression_family_id": row.get("expression_family_id"),
                "tool_ids": row.get("gold_tool_ids"),
            }
        )
    if not ids:
        raise ToolRouteBenchError(f"{name} is empty")
    return BinarySplit(
        name=name,
        ids=ids,
        utterances=utterances,
        features=np.asarray(features, dtype=np.float32),
        targets=np.asarray(targets, dtype=np.int64),
        metadata=metadata,
    )


def _load_petai_authoring_train(
    *,
    dataset_path: Path,
    embeddings_path: Path,
    mode: str,
) -> BinarySplit:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    if mode not in {"call-only", "all"}:
        raise ToolRouteBenchError(f"unsupported PetAI authoring mode: {mode}")
    embedding_rows = {
        row["case_id"]: row
        for row in read_jsonl(embeddings_path)
        if row.get("kind") in {"positive_prototype", "normal_prototype"}
        and isinstance(row.get("case_id"), str)
    }
    ids: list[str] = []
    utterances: list[str] = []
    features: list[list[float]] = []
    targets: list[int] = []
    metadata: list[dict[str, Any]] = []
    source = f"petai_authoring_{mode.replace('-', '_')}"
    for row in read_jsonl(dataset_path):
        if row.get("split") != "authoring" or row.get("track") != "single_tool":
            raise ToolRouteBenchError(
                "PetAI actionability training accepts only authoring/single_tool rows"
            )
        call = bool(row.get("gold_tool_ids"))
        if mode == "call-only" and not call:
            continue
        case_id = row.get("case_id")
        utterance = row.get("utterance")
        if not isinstance(case_id, str) or not isinstance(utterance, str):
            raise ToolRouteBenchError("PetAI authoring has an invalid dataset row")
        embedded = embedding_rows.get(case_id)
        expected_kind = "positive_prototype" if call else "normal_prototype"
        if (
            embedded is None
            or embedded.get("kind") != expected_kind
            or embedded.get("text") != utterance
        ):
            raise ToolRouteBenchError(
                f"PetAI authoring is missing matching {expected_kind} for {case_id}"
            )
        embedded_id, embedded_text, vector = _validated_identity_vector(
            embedded,
            context="PetAI authoring embedding",
        )
        if embedded_id != case_id or embedded_text != utterance:
            raise ToolRouteBenchError(
                f"PetAI authoring embedding identity differs for {case_id}"
            )
        ids.append(case_id)
        utterances.append(utterance)
        features.append(vector)
        targets.append(int(call))
        metadata.append(
            {
                "source": source,
                "source_dataset": "toolroutebench-pilot-v0.1.0-authoring",
                "source_label": "CALL" if call else "NO_CALL",
                "source_label_name": row.get("difficulty"),
                "difficulty": row.get("difficulty"),
                "tool_ids": row.get("gold_tool_ids"),
                "expression_family_id": row.get("expression_family_id"),
            }
        )
    if not ids:
        raise ToolRouteBenchError("PetAI authoring training set is empty")
    return BinarySplit(
        name=f"petai_authoring_train_{mode.replace('-', '_')}",
        ids=ids,
        utterances=utterances,
        features=np.asarray(features, dtype=np.float32),
        targets=np.asarray(targets, dtype=np.int64),
        metadata=metadata,
    )


def _assert_splits_disjoint(splits: list[BinarySplit]) -> None:
    seen_ids: dict[str, str] = {}
    seen_utterances: dict[str, str] = {}
    seen_expression_families: dict[str, str] = {}
    for split in splits:
        for case_id, utterance, metadata in zip(
            split.ids,
            split.utterances,
            split.metadata,
            strict=True,
        ):
            prior_id_split = seen_ids.get(case_id)
            if prior_id_split is not None:
                raise ToolRouteBenchError(
                    f"{split.name} case ID overlaps {prior_id_split}: {case_id}"
                )
            prior_utterance_split = seen_utterances.get(utterance)
            if prior_utterance_split is not None:
                raise ToolRouteBenchError(
                    f"{split.name} utterance overlaps {prior_utterance_split}: {utterance}"
                )
            seen_ids[case_id] = split.name
            seen_utterances[utterance] = split.name
            expression_family_id = metadata.get("expression_family_id")
            if not isinstance(expression_family_id, str):
                continue
            prior_family_split = seen_expression_families.get(expression_family_id)
            if prior_family_split is not None and prior_family_split != split.name:
                raise ToolRouteBenchError(
                    f"{split.name} expression family overlaps "
                    f"{prior_family_split}: {expression_family_id}"
                )
            seen_expression_families[expression_family_id] = split.name


def _exclude_reference_overlaps(
    split: BinarySplit,
    references: list[BinarySplit],
) -> BinarySplit:
    reference_ids: dict[str, set[str]] = defaultdict(set)
    reference_utterances: dict[str, set[str]] = defaultdict(set)
    reference_families: dict[str, set[str]] = defaultdict(set)
    for reference in references:
        for case_id, utterance, metadata in zip(
            reference.ids,
            reference.utterances,
            reference.metadata,
            strict=True,
        ):
            reference_ids[case_id].add(reference.name)
            reference_utterances[utterance].add(reference.name)
            expression_family_id = metadata.get("expression_family_id")
            if isinstance(expression_family_id, str):
                reference_families[expression_family_id].add(reference.name)

    kept_indices: list[int] = []
    exclusions: list[dict[str, Any]] = []
    for index, (case_id, utterance, metadata) in enumerate(
        zip(split.ids, split.utterances, split.metadata, strict=True)
    ):
        overlaps: dict[str, list[str]] = {}
        if case_id in reference_ids:
            overlaps["case_id"] = sorted(reference_ids[case_id])
        if utterance in reference_utterances:
            overlaps["utterance"] = sorted(reference_utterances[utterance])
        expression_family_id = metadata.get("expression_family_id")
        if (
            isinstance(expression_family_id, str)
            and expression_family_id in reference_families
        ):
            overlaps["expression_family_id"] = sorted(
                reference_families[expression_family_id]
            )
        if overlaps:
            exclusions.append({"case_id": case_id, "overlaps": overlaps})
        else:
            kept_indices.append(index)
    if not kept_indices:
        raise ToolRouteBenchError(
            f"{split.name} is empty after evaluation-overlap exclusion"
        )
    return BinarySplit(
        name=split.name,
        ids=[split.ids[index] for index in kept_indices],
        utterances=[split.utterances[index] for index in kept_indices],
        features=split.features[kept_indices],
        targets=split.targets[kept_indices],
        metadata=[split.metadata[index] for index in kept_indices],
        exclusions=exclusions,
    )
