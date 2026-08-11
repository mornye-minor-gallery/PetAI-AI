from __future__ import annotations

import importlib.metadata
import math
import platform
import warnings
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .common import (
    CONFIGS_DIR,
    ToolRouteBenchError,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)

ACTIONABILITY_CONFIG = CONFIGS_DIR / "actionability-3i4k-mlp-smoke.v1.json"
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


def select_threshold(targets: Any, probabilities: Any) -> float:
    try:
        import numpy as np
        from sklearn.metrics import f1_score
    except ImportError as error:
        raise ToolRouteBenchError("scikit-learn is required; run through uv") from error
    best_threshold = 0.5
    best_macro_f1 = -1.0
    for threshold in np.linspace(0.05, 0.95, 91):
        predictions = (probabilities >= threshold).astype(np.int64)
        score = float(f1_score(targets, predictions, average="macro", zero_division=0))
        if score > best_macro_f1 + 1e-12:
            best_macro_f1 = score
            best_threshold = float(threshold)
        elif abs(score - best_macro_f1) <= 1e-12:
            if abs(float(threshold) - 0.5) < abs(best_threshold - 0.5):
                best_threshold = float(threshold)
    return best_threshold


def binary_metrics(targets: Any, probabilities: Any, threshold: float) -> dict[str, Any]:
    try:
        import numpy as np
        from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score
    except ImportError as error:
        raise ToolRouteBenchError("scikit-learn is required; run through uv") from error
    predictions = (probabilities >= threshold).astype(np.int64)
    tn = int(np.sum((targets == 0) & (predictions == 0)))
    fp = int(np.sum((targets == 0) & (predictions == 1)))
    fn = int(np.sum((targets == 1) & (predictions == 0)))
    tp = int(np.sum((targets == 1) & (predictions == 1)))
    no_call = tn + fp
    call = tp + fn
    return {
        "records": int(len(targets)),
        "threshold": float(threshold),
        "accuracy": float(accuracy_score(targets, predictions)),
        "macro_f1": float(f1_score(targets, predictions, average="macro", zero_division=0)),
        "call_precision": float(precision_score(targets, predictions, zero_division=0)),
        "call_recall": float(recall_score(targets, predictions, zero_division=0)),
        "call_f1": float(f1_score(targets, predictions, zero_division=0)),
        "normal_false_activation_count": fp,
        "normal_false_activation_rate": float(fp / no_call) if no_call else 0.0,
        "call_miss_count": fn,
        "call_miss_rate": float(fn / call) if call else 0.0,
        "confusion": {"tn": tn, "fp": fp, "fn": fn, "tp": tp},
    }


def _slice_metrics(split: BinarySplit, probabilities: Any, threshold: float) -> dict[str, Any]:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    keys = sorted(
        {
            str(metadata.get("source_label_name") or metadata.get("difficulty") or "unknown")
            for metadata in split.metadata
        }
    )
    result: dict[str, Any] = {}
    for key in keys:
        indices = [
            index
            for index, metadata in enumerate(split.metadata)
            if str(metadata.get("source_label_name") or metadata.get("difficulty") or "unknown") == key
        ]
        result[key] = binary_metrics(
            split.targets[indices],
            np.asarray(probabilities)[indices],
            threshold,
        )
    return result


def _tool_slice_metrics(
    split: BinarySplit,
    probabilities: Any,
    threshold: float,
) -> dict[str, Any]:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    tool_ids = sorted(
        {
            str(tool_id)
            for metadata in split.metadata
            for tool_id in (metadata.get("tool_ids") or [])
        }
    )
    result: dict[str, Any] = {}
    for tool_id in tool_ids:
        indices = [
            index
            for index, metadata in enumerate(split.metadata)
            if tool_id in (metadata.get("tool_ids") or [])
        ]
        result[tool_id] = binary_metrics(
            split.targets[indices],
            np.asarray(probabilities)[indices],
            threshold,
        )
    return result


def _write_predictions(
    path: Path,
    split: BinarySplit,
    probabilities: Any,
    threshold: float,
) -> None:
    predictions = (probabilities >= threshold).astype("int64")
    write_jsonl(
        path,
        [
            {
                "case_id": split.ids[index],
                "split": split.name,
                "utterance": split.utterances[index],
                "gold": "CALL" if split.targets[index] else "NO_CALL",
                "probability_call": float(probabilities[index]),
                "prediction": "CALL" if predictions[index] else "NO_CALL",
                "metadata": split.metadata[index],
            }
            for index in range(len(split.ids))
        ],
    )


def _input_evidence(path: Path | None) -> dict[str, str] | None:
    if path is None:
        return None
    return {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
    }


def train_actionability_mlp(
    *,
    public_embeddings_path: Path,
    public_embedding_manifest_path: Path,
    output_dir: Path,
    auxiliary_train_embeddings_path: Path | None = None,
    auxiliary_train_embedding_manifest_path: Path | None = None,
    petai_train_dataset_path: Path | None = None,
    petai_train_embeddings_path: Path | None = None,
    petai_train_embedding_manifest_path: Path | None = None,
    petai_train_mode: str = "all",
    petai_dev_dataset_path: Path | None = None,
    petai_dev_embeddings_path: Path | None = None,
    petai_holdout_dataset_path: Path | None = None,
    petai_holdout_embeddings_path: Path | None = None,
    config_path: Path = ACTIONABILITY_CONFIG,
) -> Path:
    try:
        import numpy as np
        import sklearn
        from sklearn.exceptions import ConvergenceWarning
        from sklearn.neural_network import MLPClassifier
    except ImportError as error:
        raise ToolRouteBenchError("scikit-learn is required; run through uv") from error
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    commit = git_commit(require_clean=True)
    config = read_json(config_path)
    manifest = read_json(public_embedding_manifest_path)
    if manifest.get("output", {}).get("sha256") != sha256_file(public_embeddings_path):
        raise ToolRouteBenchError("public embedding cache differs from its manifest")
    public = _load_public_splits(public_embeddings_path)
    supplements: list[BinarySplit] = []
    auxiliary: BinarySplit | None = None
    if (
        auxiliary_train_embeddings_path is None
        and auxiliary_train_embedding_manifest_path is not None
    ) or (
        auxiliary_train_embeddings_path is not None
        and auxiliary_train_embedding_manifest_path is None
    ):
        raise ToolRouteBenchError(
            "auxiliary train embeddings and manifest must be provided together"
        )
    if auxiliary_train_embeddings_path is not None:
        auxiliary_manifest = read_json(auxiliary_train_embedding_manifest_path)
        if auxiliary_manifest.get("output", {}).get("sha256") != sha256_file(
            auxiliary_train_embeddings_path
        ):
            raise ToolRouteBenchError(
                "auxiliary embedding cache differs from its manifest"
            )
        auxiliary = _load_auxiliary_train(auxiliary_train_embeddings_path)
        supplements.append(auxiliary)
    petai_train_paths = (
        petai_train_dataset_path,
        petai_train_embeddings_path,
        petai_train_embedding_manifest_path,
    )
    if any(path is not None for path in petai_train_paths) and not all(
        path is not None for path in petai_train_paths
    ):
        raise ToolRouteBenchError(
            "PetAI train dataset, embeddings, and manifest must be provided together"
        )
    petai_authoring: BinarySplit | None = None
    if petai_train_dataset_path is not None:
        petai_train_manifest = read_json(petai_train_embedding_manifest_path)
        if petai_train_manifest.get("output", {}).get("sha256") != sha256_file(
            petai_train_embeddings_path
        ):
            raise ToolRouteBenchError(
                "PetAI train embedding cache differs from its manifest"
            )
        petai_authoring = _load_petai_authoring_train(
            dataset_path=petai_train_dataset_path,
            embeddings_path=petai_train_embeddings_path,
            mode=petai_train_mode,
        )

    evaluation_tracks: dict[str, BinarySplit] = {}
    optional_pairs = (
        ("petai_dev", petai_dev_dataset_path, petai_dev_embeddings_path),
        (
            "petai_holdout_retrospective",
            petai_holdout_dataset_path,
            petai_holdout_embeddings_path,
        ),
    )
    for name, dataset_path, embeddings_path in optional_pairs:
        if dataset_path is None and embeddings_path is None:
            continue
        if dataset_path is None or embeddings_path is None:
            raise ToolRouteBenchError(f"{name} requires dataset and embeddings together")
        evaluation_tracks[name] = _load_petai_track(
            name=name,
            dataset_path=dataset_path,
            embeddings_path=embeddings_path,
        )
    evaluation_splits = [
        public["validation"],
        public["test"],
        *evaluation_tracks.values(),
    ]
    if petai_authoring is not None:
        supplements.append(
            _exclude_reference_overlaps(petai_authoring, evaluation_splits)
        )
    training_splits = [public["train"], *supplements]
    _assert_splits_disjoint(training_splits)
    for training_split in training_splits:
        for evaluation_split in evaluation_splits:
            _assert_splits_disjoint([training_split, evaluation_split])

    training_features = np.concatenate(
        [split.features for split in training_splits],
        axis=0,
    )
    training_targets = np.concatenate(
        [split.targets for split in training_splits],
        axis=0,
    )
    mlp = config["mlp"]
    model = MLPClassifier(
        hidden_layer_sizes=(int(mlp["hidden_units"]),),
        activation=mlp["activation"],
        solver=mlp["solver"],
        alpha=float(mlp["alpha"]),
        batch_size=int(mlp["batch_size"]),
        learning_rate_init=float(mlp["learning_rate_init"]),
        max_iter=int(mlp["max_iter"]),
        shuffle=True,
        random_state=int(config["seed"]),
        tol=1e-5,
        n_iter_no_change=30,
        early_stopping=False,
    )
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always", ConvergenceWarning)
        model.fit(training_features, training_targets)
    convergence_warnings = [
        str(item.message)
        for item in caught
        if issubclass(item.category, ConvergenceWarning)
    ]

    probabilities: dict[str, Any] = {
        name: np.asarray(model.predict_proba(split.features)[:, 1], dtype=np.float32)
        for name, split in public.items()
    }
    tracks: dict[str, BinarySplit] = dict(public)
    for supplement in supplements:
        tracks[supplement.name] = supplement
        probabilities[supplement.name] = np.asarray(
            model.predict_proba(supplement.features)[:, 1], dtype=np.float32
        )
    for name, split in evaluation_tracks.items():
        tracks[name] = split
        probabilities[name] = np.asarray(
            model.predict_proba(split.features)[:, 1], dtype=np.float32
        )
    threshold_track = config.get("threshold_selection_track", "validation")
    if threshold_track not in tracks or threshold_track in {
        "test",
        "petai_holdout_retrospective",
    }:
        raise ToolRouteBenchError(
            f"invalid threshold selection track: {threshold_track}"
        )
    threshold = select_threshold(
        tracks[threshold_track].targets,
        probabilities[threshold_track],
    )

    output_dir.mkdir(parents=True)
    weights_path = output_dir / "model_weights.npz"
    np.savez_compressed(
        weights_path,
        dense_0_weight=np.asarray(model.coefs_[0], dtype=np.float32),
        dense_0_bias=np.asarray(model.intercepts_[0], dtype=np.float32),
        dense_1_weight=np.asarray(model.coefs_[1], dtype=np.float32),
        dense_1_bias=np.asarray(model.intercepts_[1], dtype=np.float32),
        threshold=np.asarray([threshold], dtype=np.float32),
    )
    metrics: dict[str, Any] = {}
    prediction_artifacts: dict[str, Any] = {}
    for name, split in tracks.items():
        metrics[name] = {
            **binary_metrics(split.targets, probabilities[name], threshold),
            "by_slice": _slice_metrics(split, probabilities[name], threshold),
            "by_tool": _tool_slice_metrics(split, probabilities[name], threshold),
        }
        prediction_path = output_dir / f"{name}_predictions.jsonl"
        _write_predictions(prediction_path, split, probabilities[name], threshold)
        prediction_artifacts[name] = {
            "path": prediction_path.name,
            "sha256": sha256_file(prediction_path),
        }

    train_counts = Counter(int(value) for value in training_targets)
    auxiliary_sources = sorted(
        {
            str(metadata["source"])
            for supplement in supplements
            for metadata in supplement.metadata
            if metadata.get("source")
        }
    )
    auxiliary_suffix = "+".join(auxiliary_sources)
    auxiliary_breakdown = {
        supplement.name: {
            "records": len(supplement.ids),
            "original_records": len(supplement.ids) + len(supplement.exclusions),
            "excluded_records": len(supplement.exclusions),
            "call": int(sum(supplement.targets)),
            "no_call": int(len(supplement.targets) - sum(supplement.targets)),
        }
        for supplement in supplements
    }
    auxiliary_exclusions = {
        supplement.name: supplement.exclusions
        for supplement in supplements
        if supplement.exclusions
    }
    result = {
        "schema_version": "toolroutebench-actionability-mlp-result-v1",
        "experiment_id": (
            config["experiment_id"]
            if not supplements
            else f"{config['experiment_id']}+{auxiliary_suffix}-aux"
        ),
        "created_at": utc_now(),
        "git_commit": commit,
        "interpretation": {
            "CALL": config.get("interpretation", {}).get(
                "CALL",
                "question or command; candidate for downstream tool routing",
            ),
            "NO_CALL": config.get("interpretation", {}).get(
                "NO_CALL",
                (
                    "fragment, statement, rhetorical act, intonation-dependent, or "
                    "train-only hard-negative OOS auxiliary"
                ),
            ),
            "training_label_status": config.get("training_label_status", "unspecified"),
            "threshold_selection_track": threshold_track,
            "product_status": "research_only",
            "petai_holdout_status": "retrospective_already_opened",
        },
        "model": {
            "type": "sklearn.neural_network.MLPClassifier",
            "input_dimension": EXPECTED_DIMENSION,
            "hidden_units": int(mlp["hidden_units"]),
            "output_dimension": 1,
            "iterations": int(model.n_iter_),
            "final_loss": float(model.loss_),
            "converged": not convergence_warnings,
            "convergence_warnings": convergence_warnings,
            "threshold": threshold,
            "weights_bytes": weights_path.stat().st_size,
        },
        "training": {
            "records": len(training_targets),
            "base_records": len(public["train"].ids),
            "auxiliary_records": sum(len(split.ids) for split in supplements),
            "auxiliary_sources": auxiliary_sources,
            "auxiliary_breakdown": auxiliary_breakdown,
            "auxiliary_exclusions": auxiliary_exclusions,
            "no_call": train_counts[0],
            "call": train_counts[1],
            "seed": int(config["seed"]),
            "config_sha256": sha256_file(config_path),
        },
        "runtime": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "numpy": np.__version__,
            "scikit_learn": sklearn.__version__,
            "ai_edge_litert": importlib.metadata.version("ai-edge-litert"),
        },
        "inputs": {
            "public_embeddings": {
                "path": str(public_embeddings_path.resolve()),
                "sha256": sha256_file(public_embeddings_path),
            },
            "public_embedding_manifest": {
                "path": str(public_embedding_manifest_path.resolve()),
                "sha256": sha256_file(public_embedding_manifest_path),
            },
            "auxiliary_train_embeddings": (
                {
                    "path": str(auxiliary_train_embeddings_path.resolve()),
                    "sha256": sha256_file(auxiliary_train_embeddings_path),
                }
                if auxiliary_train_embeddings_path is not None
                else None
            ),
            "auxiliary_train_embedding_manifest": (
                {
                    "path": str(auxiliary_train_embedding_manifest_path.resolve()),
                    "sha256": sha256_file(auxiliary_train_embedding_manifest_path),
                }
                if auxiliary_train_embedding_manifest_path is not None
                else None
            ),
            "petai_train_dataset": (
                {
                    "path": str(petai_train_dataset_path.resolve()),
                    "sha256": sha256_file(petai_train_dataset_path),
                    "mode": petai_train_mode,
                }
                if petai_train_dataset_path is not None
                else None
            ),
            "petai_train_embeddings": (
                {
                    "path": str(petai_train_embeddings_path.resolve()),
                    "sha256": sha256_file(petai_train_embeddings_path),
                }
                if petai_train_embeddings_path is not None
                else None
            ),
            "petai_train_embedding_manifest": (
                {
                    "path": str(petai_train_embedding_manifest_path.resolve()),
                    "sha256": sha256_file(petai_train_embedding_manifest_path),
                }
                if petai_train_embedding_manifest_path is not None
                else None
            ),
            "petai_evaluation": {
                "dev_dataset": _input_evidence(petai_dev_dataset_path),
                "dev_embeddings": _input_evidence(petai_dev_embeddings_path),
                "holdout_dataset": _input_evidence(petai_holdout_dataset_path),
                "holdout_embeddings": _input_evidence(
                    petai_holdout_embeddings_path
                ),
            },
        },
        "artifacts": {
            "weights": {
                "path": weights_path.name,
                "sha256": sha256_file(weights_path),
            },
            "predictions": prediction_artifacts,
        },
        "metrics": metrics,
    }
    result_path = output_dir / "result.json"
    write_json(result_path, result)
    return result_path.resolve()
