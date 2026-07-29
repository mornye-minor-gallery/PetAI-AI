#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import tempfile
import time
import warnings
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import sklearn
from sklearn.exceptions import ConvergenceWarning
from sklearn.metrics import (
    accuracy_score,
    f1_score,
    hamming_loss,
    precision_recall_fscore_support,
)
from sklearn.neural_network import MLPClassifier

LABELS = ("preference", "event")
EXPECTED_DIMENSION = 768
HIDDEN_UNITS = 64


class ClassifierTrainingError(RuntimeError):
    pass


@dataclass(frozen=True)
class EmbeddingSplit:
    name: str
    ids: list[str]
    utterances: list[str]
    features: np.ndarray
    targets: np.ndarray


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_embedding_split(
    path: Path,
    *,
    split_name: str,
    expected_dimension: int = EXPECTED_DIMENSION,
) -> EmbeddingSplit:
    ids: list[str] = []
    utterances: list[str] = []
    features: list[list[float]] = []
    targets: list[list[int]] = []

    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: invalid JSON."
                ) from error

            row_id = row.get("id")
            utterance = row.get("utterance")
            embedding = row.get("embedding")
            if not isinstance(row_id, str) or not row_id:
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: invalid id."
                )
            if not isinstance(utterance, str) or not utterance.strip():
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: invalid utterance."
                )
            if row.get("split") != split_name:
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: expected split {split_name!r}."
                )
            if not isinstance(embedding, list) or len(embedding) != expected_dimension:
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: expected a "
                    f"{expected_dimension}-value embedding."
                )
            if not all(
                isinstance(value, (int, float)) and math.isfinite(value)
                for value in embedding
            ):
                raise ClassifierTrainingError(
                    f"{path.name}:{line_number}: embedding is not finite."
                )

            label_values: list[int] = []
            for label in LABELS:
                value = row.get(label)
                if not isinstance(value, bool):
                    raise ClassifierTrainingError(
                        f"{path.name}:{line_number}: {label} must be boolean."
                    )
                label_values.append(int(value))

            ids.append(row_id)
            utterances.append(utterance)
            features.append(embedding)
            targets.append(label_values)

    if not ids:
        raise ClassifierTrainingError(f"{path.name}: split is empty.")
    if len(set(ids)) != len(ids):
        raise ClassifierTrainingError(f"{path.name}: duplicate ids.")
    if len(set(utterances)) != len(utterances):
        raise ClassifierTrainingError(f"{path.name}: duplicate utterances.")

    feature_array = np.asarray(features, dtype=np.float32)
    target_array = np.asarray(targets, dtype=np.int64)
    if feature_array.shape != (len(ids), expected_dimension):
        raise ClassifierTrainingError(
            f"{path.name}: unexpected feature shape {feature_array.shape}."
        )
    if target_array.shape != (len(ids), len(LABELS)):
        raise ClassifierTrainingError(
            f"{path.name}: unexpected target shape {target_array.shape}."
        )

    return EmbeddingSplit(
        name=split_name,
        ids=ids,
        utterances=utterances,
        features=feature_array,
        targets=target_array,
    )


def validate_split_boundaries(splits: list[EmbeddingSplit]) -> None:
    seen_ids: set[str] = set()
    seen_utterances: set[str] = set()
    for split in splits:
        duplicate_ids = seen_ids.intersection(split.ids)
        duplicate_utterances = seen_utterances.intersection(split.utterances)
        if duplicate_ids:
            raise ClassifierTrainingError(
                f"{split.name}: ids overlap another split."
            )
        if duplicate_utterances:
            raise ClassifierTrainingError(
                f"{split.name}: utterances overlap another split."
            )
        seen_ids.update(split.ids)
        seen_utterances.update(split.utterances)


def select_threshold(targets: np.ndarray, probabilities: np.ndarray) -> float:
    best_threshold = 0.5
    best_score = -1.0
    for threshold in np.linspace(0.05, 0.95, 91):
        predictions = (probabilities >= threshold).astype(np.int64)
        score = f1_score(targets, predictions, zero_division=0)
        if score > best_score + 1e-12:
            best_score = float(score)
            best_threshold = float(threshold)
        elif abs(score - best_score) <= 1e-12:
            if abs(float(threshold) - 0.5) < abs(best_threshold - 0.5):
                best_threshold = float(threshold)
    return best_threshold


def select_thresholds(
    targets: np.ndarray,
    probabilities: np.ndarray,
) -> np.ndarray:
    return np.asarray(
        [
            select_threshold(targets[:, index], probabilities[:, index])
            for index in range(len(LABELS))
        ],
        dtype=np.float32,
    )


def calculate_metrics(
    targets: np.ndarray,
    probabilities: np.ndarray,
    thresholds: np.ndarray,
) -> dict[str, Any]:
    predictions = (probabilities >= thresholds).astype(np.int64)
    precision, recall, f1, support = precision_recall_fscore_support(
        targets,
        predictions,
        average=None,
        zero_division=0,
    )
    return {
        "records": int(targets.shape[0]),
        "exact_match_accuracy": float(accuracy_score(targets, predictions)),
        "hamming_accuracy": float(1.0 - hamming_loss(targets, predictions)),
        "micro_f1": float(
            f1_score(targets, predictions, average="micro", zero_division=0)
        ),
        "macro_f1": float(
            f1_score(targets, predictions, average="macro", zero_division=0)
        ),
        "per_label": {
            label: {
                "threshold": float(thresholds[index]),
                "precision": float(precision[index]),
                "recall": float(recall[index]),
                "f1": float(f1[index]),
                "positive_support": int(support[index]),
            }
            for index, label in enumerate(LABELS)
        },
    }


def write_predictions(
    path: Path,
    split: EmbeddingSplit,
    probabilities: np.ndarray,
    thresholds: np.ndarray,
) -> None:
    predictions = (probabilities >= thresholds).astype(np.int64)
    with path.open("w", encoding="utf-8") as handle:
        for index, row_id in enumerate(split.ids):
            record = {
                "id": row_id,
                "utterance": split.utterances[index],
                "split": split.name,
                "targets": {
                    label: bool(split.targets[index, label_index])
                    for label_index, label in enumerate(LABELS)
                },
                "probabilities": {
                    label: float(probabilities[index, label_index])
                    for label_index, label in enumerate(LABELS)
                },
                "predictions": {
                    label: bool(predictions[index, label_index])
                    for label_index, label in enumerate(LABELS)
                },
            }
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def train_classifier(
    *,
    train_path: Path,
    validation_path: Path,
    test_path: Path,
    challenge_path: Path | None,
    embedding_manifest_path: Path,
    output_dir: Path,
    seed: int,
) -> Path:
    if output_dir.exists():
        raise ClassifierTrainingError(
            f"Output directory already exists: {output_dir}"
        )

    required_paths = [
        train_path,
        validation_path,
        test_path,
        embedding_manifest_path,
    ]
    if challenge_path is not None:
        required_paths.append(challenge_path)
    for path in required_paths:
        if not path.is_file():
            raise ClassifierTrainingError(f"Required file not found: {path}")

    embedding_manifest = json.loads(
        embedding_manifest_path.read_text(encoding="utf-8")
    )
    if embedding_manifest.get("phase") != "feature_extraction_complete":
        raise ClassifierTrainingError(
            "Embedding manifest does not describe completed feature extraction."
        )
    if embedding_manifest.get("training_started") is not False:
        raise ClassifierTrainingError(
            "Embedding manifest has an unexpected training state."
        )
    if embedding_manifest.get("model", {}).get("dimension") != EXPECTED_DIMENSION:
        raise ClassifierTrainingError(
            "Embedding manifest dimension does not match the classifier."
        )

    train = load_embedding_split(train_path, split_name="train")
    validation = load_embedding_split(
        validation_path,
        split_name="validation",
    )
    test = load_embedding_split(test_path, split_name="test")
    challenge = (
        load_embedding_split(
            challenge_path,
            split_name="synthetic_challenge",
        )
        if challenge_path is not None
        else None
    )
    all_splits = [train, validation, test]
    if challenge is not None:
        all_splits.append(challenge)
    validate_split_boundaries(all_splits)

    started_at = datetime.now(UTC)
    started_clock = time.perf_counter()
    model = MLPClassifier(
        hidden_layer_sizes=(HIDDEN_UNITS,),
        activation="relu",
        solver="adam",
        alpha=0.01,
        batch_size=32,
        learning_rate_init=0.001,
        max_iter=500,
        shuffle=True,
        random_state=seed,
        tol=1e-5,
        n_iter_no_change=50,
        early_stopping=False,
    )
    with warnings.catch_warnings(record=True) as caught_warnings:
        warnings.simplefilter("always", ConvergenceWarning)
        model.fit(train.features, train.targets)
    convergence_warnings = [
        str(item.message)
        for item in caught_warnings
        if issubclass(item.category, ConvergenceWarning)
    ]

    validation_probabilities = np.asarray(
        model.predict_proba(validation.features),
        dtype=np.float32,
    )
    thresholds = select_thresholds(
        validation.targets,
        validation_probabilities,
    )
    validation_metrics = calculate_metrics(
        validation.targets,
        validation_probabilities,
        thresholds,
    )

    test_probabilities = np.asarray(
        model.predict_proba(test.features),
        dtype=np.float32,
    )
    test_metrics = calculate_metrics(
        test.targets,
        test_probabilities,
        thresholds,
    )
    challenge_probabilities = (
        np.asarray(
            model.predict_proba(challenge.features),
            dtype=np.float32,
        )
        if challenge is not None
        else None
    )
    challenge_metrics = (
        calculate_metrics(
            challenge.targets,
            challenge_probabilities,
            thresholds,
        )
        if challenge is not None
        and challenge_probabilities is not None
        else None
    )
    elapsed_seconds = time.perf_counter() - started_clock

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}.",
            dir=output_dir.parent,
        )
    )
    try:
        weights_path = temporary_dir / "model_weights.npz"
        np.savez_compressed(
            weights_path,
            dense_0_weight=np.asarray(model.coefs_[0], dtype=np.float32),
            dense_0_bias=np.asarray(model.intercepts_[0], dtype=np.float32),
            dense_1_weight=np.asarray(model.coefs_[1], dtype=np.float32),
            dense_1_bias=np.asarray(model.intercepts_[1], dtype=np.float32),
            thresholds=thresholds,
        )

        validation_predictions_path = (
            temporary_dir / "validation_predictions.jsonl"
        )
        test_predictions_path = temporary_dir / "test_predictions.jsonl"
        write_predictions(
            validation_predictions_path,
            validation,
            validation_probabilities,
            thresholds,
        )
        write_predictions(
            test_predictions_path,
            test,
            test_probabilities,
            thresholds,
        )
        challenge_predictions_path: Path | None = None
        if challenge is not None and challenge_probabilities is not None:
            challenge_predictions_path = (
                temporary_dir
                / "synthetic_challenge_predictions.jsonl"
            )
            write_predictions(
                challenge_predictions_path,
                challenge,
                challenge_probabilities,
                thresholds,
            )

        manifest = {
            "phase": "baseline_training_complete",
            "training_started": True,
            "created_at": datetime.now(UTC).isoformat(),
            "started_at": started_at.isoformat(),
            "elapsed_seconds": elapsed_seconds,
            "seed": seed,
            "architecture": {
                "input_dimension": EXPECTED_DIMENSION,
                "hidden_units": HIDDEN_UNITS,
                "hidden_activation": "relu",
                "output_labels": list(LABELS),
                "output_activation": "sigmoid",
                "layer_shapes": [
                    list(model.coefs_[0].shape),
                    list(model.coefs_[1].shape),
                ],
            },
            "training": {
                "algorithm": "sklearn.neural_network.MLPClassifier",
                "solver": "adam",
                "loss": "binary_cross_entropy",
                "alpha": 0.01,
                "batch_size": 32,
                "learning_rate_init": 0.001,
                "max_iter": 500,
                "iterations": int(model.n_iter_),
                "final_loss": float(model.loss_),
                "converged": not convergence_warnings,
                "convergence_warnings": convergence_warnings,
            },
            "runtime": {
                "python": platform.python_version(),
                "platform": platform.platform(),
                "machine": platform.machine(),
                "numpy": np.__version__,
                "scikit_learn": sklearn.__version__,
            },
            "inputs": {
                "embedding_manifest": {
                    "path": str(embedding_manifest_path.resolve()),
                    "sha256": sha256_file(embedding_manifest_path),
                },
                "train": {
                    "path": str(train_path.resolve()),
                    "sha256": sha256_file(train_path),
                    "records": len(train.ids),
                },
                "validation": {
                    "path": str(validation_path.resolve()),
                    "sha256": sha256_file(validation_path),
                    "records": len(validation.ids),
                },
                "test": {
                    "path": str(test_path.resolve()),
                    "sha256": sha256_file(test_path),
                    "records": len(test.ids),
                },
            },
            "artifacts": {
                "weights": {
                    "path": weights_path.name,
                    "sha256": sha256_file(weights_path),
                },
                "validation_predictions": {
                    "path": validation_predictions_path.name,
                    "sha256": sha256_file(validation_predictions_path),
                },
                "test_predictions": {
                    "path": test_predictions_path.name,
                    "sha256": sha256_file(test_predictions_path),
                },
            },
            "metrics": {
                "validation": validation_metrics,
                "test": test_metrics,
            },
            "deployment_status": "not_converted",
        }
        if challenge is not None and challenge_path is not None:
            manifest["inputs"]["synthetic_challenge"] = {
                "path": str(challenge_path.resolve()),
                "sha256": sha256_file(challenge_path),
                "records": len(challenge.ids),
            }
        if (
            challenge_predictions_path is not None
            and challenge_metrics is not None
        ):
            manifest["artifacts"]["synthetic_challenge_predictions"] = {
                "path": challenge_predictions_path.name,
                "sha256": sha256_file(challenge_predictions_path),
            }
            manifest["metrics"]["synthetic_challenge"] = (
                challenge_metrics
            )
        manifest_path = temporary_dir / "training_manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary_dir, output_dir)
        return output_dir / manifest_path.name
    except Exception:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Train the first two-label PetAI memory classifier from fixed "
            "EmbeddingGemma features."
        )
    )
    parser.add_argument("--train", required=True, type=Path)
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--test", required=True, type=Path)
    parser.add_argument("--challenge", type=Path)
    parser.add_argument("--embedding-manifest", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=42)
    return parser


def main() -> None:
    arguments = build_parser().parse_args()
    manifest_path = train_classifier(
        train_path=arguments.train,
        validation_path=arguments.validation,
        test_path=arguments.test,
        challenge_path=arguments.challenge,
        embedding_manifest_path=arguments.embedding_manifest,
        output_dir=arguments.output_dir,
        seed=arguments.seed,
    )
    print(f"Training manifest: {manifest_path}")


if __name__ == "__main__":
    main()
