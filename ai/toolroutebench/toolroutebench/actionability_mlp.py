from __future__ import annotations

import importlib.metadata
import platform
import warnings
from collections import Counter
from pathlib import Path
from typing import Any

from .common import (
    CONFIGS_DIR,
    ToolRouteBenchError,
    git_commit,
    read_json,
    sha256_file,
    utc_now,
    write_json,
)
from .actionability_data import (
    EXPECTED_DIMENSION,
    BinarySplit,
    _assert_splits_disjoint,
    _exclude_reference_overlaps,
    _load_auxiliary_train,
    _load_petai_authoring_train,
    _load_petai_track,
    _load_public_splits,
)
from .actionability_metrics import (
    _slice_metrics,
    _tool_slice_metrics,
    _write_predictions,
    binary_metrics,
    select_threshold,
)

ACTIONABILITY_CONFIG = CONFIGS_DIR / "actionability-3i4k-mlp-smoke.v1.json"


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
        verbose=bool(mlp.get("verbose", False)),
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
        fixed_threshold=config.get("fixed_threshold"),
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
            "threshold_selection_track": (
                "fixed" if config.get("fixed_threshold") is not None else threshold_track
            ),
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
