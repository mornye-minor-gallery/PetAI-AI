from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .common import (
    FacetRouteBenchError,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import load_route_contract
from .evaluation import (
    _load_eval_records,
    _score_rows,
    _tune_threshold,
    classification_metrics,
)

SPECIALIST_CANDIDATE = "utterance_prototype"
SHRINKAGE_GRID = (0.0, 0.25, 0.5, 0.75, 1.0)
ARBITRATION_RULES = ("raw_score", "threshold_margin", "normalized_margin")


def _binary_metrics(
    records: Sequence[dict[str, Any]],
    score_rows: Sequence[dict[str, Any]],
    route_id: str,
    threshold: float,
) -> dict[str, float | int]:
    score_by_id = {row["case_id"]: row for row in score_rows}
    tp = fp = fn = tn = 0
    for record in records:
        score = float(score_by_id[record["case_id"]]["route_scores"][route_id])
        predicted_positive = score >= threshold
        gold_positive = record["gold_route_id"] == route_id
        if predicted_positive and gold_positive:
            tp += 1
        elif predicted_positive:
            fp += 1
        elif gold_positive:
            fn += 1
        else:
            tn += 1
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = (
        2 * precision * recall / (precision + recall)
        if precision + recall
        else 0.0
    )
    return {
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def tune_per_route_thresholds(
    records: Sequence[dict[str, Any]],
    score_rows: Sequence[dict[str, Any]],
    route_order: Sequence[str],
) -> tuple[dict[str, float], dict[str, dict[str, float | int]]]:
    if len(records) != len(score_rows):
        raise FacetRouteBenchError("record and score-row counts differ")
    thresholds: dict[str, float] = {}
    diagnostics: dict[str, dict[str, float | int]] = {}
    for route_id in route_order:
        scores = sorted(
            {
                float(row["route_scores"][route_id])
                for row in score_rows
            }
        )
        candidates = [-1.000001, *(math.nextafter(score, math.inf) for score in scores)]
        best: tuple[tuple[float, float, float, float], float, dict[str, float | int]] | None = None
        for threshold in candidates:
            metrics = _binary_metrics(records, score_rows, route_id, threshold)
            rank = (
                float(metrics["f1"]),
                float(metrics["precision"]),
                float(metrics["recall"]),
                threshold,
            )
            if best is None or rank > best[0]:
                best = rank, threshold, metrics
        assert best is not None
        thresholds[route_id] = best[1]
        diagnostics[route_id] = best[2]
    return thresholds, diagnostics


def predict_per_route_thresholds(
    score_rows: Sequence[dict[str, Any]],
    thresholds: dict[str, float],
    route_order: Sequence[str],
    *,
    arbitration: str = "threshold_margin",
) -> list[dict[str, Any]]:
    if set(thresholds) != set(route_order):
        raise FacetRouteBenchError("per-route thresholds do not match route order")
    if arbitration not in {"raw_score", "threshold_margin", "normalized_margin"}:
        raise FacetRouteBenchError(f"unknown arbitration rule: {arbitration}")
    predictions: list[dict[str, Any]] = []
    for row in score_rows:
        accepted = []
        for route_id in route_order:
            score = float(row["route_scores"][route_id])
            threshold = thresholds[route_id]
            if score < threshold:
                continue
            margin = score - threshold
            arbitration_score = {
                "raw_score": score,
                "threshold_margin": margin,
                "normalized_margin": margin / (1.0 - threshold),
            }[arbitration]
            accepted.append(
                (
                    arbitration_score,
                    score,
                    -route_order.index(route_id),
                    route_id,
                    margin,
                )
            )
        predicted_route = max(accepted)[3] if accepted else "GENERAL"
        predictions.append(
            {
                **row,
                "predicted_route_id": predicted_route,
                "arbitration": arbitration,
                "accepted_route_ids": [item[3] for item in sorted(accepted, reverse=True)],
                "winning_threshold_margin": max(accepted)[4] if accepted else None,
            }
        )
    return predictions


def _stratified_fold_ids(
    records: Sequence[dict[str, Any]], fold_count: int = 5
) -> list[set[str]]:
    groups: dict[tuple[str, str], list[str]] = defaultdict(list)
    for record in records:
        groups[(record["gold_route_id"], record["difficulty"])].append(
            record["case_id"]
        )
    folds = [set() for _ in range(fold_count)]
    for key in sorted(groups):
        for index, case_id in enumerate(sorted(groups[key])):
            folds[index % fold_count].add(case_id)
    if set().union(*folds) != {record["case_id"] for record in records}:
        raise FacetRouteBenchError("cross-validation folds do not cover Dev")
    return folds


def _shrink_thresholds(
    thresholds: dict[str, float], global_threshold: float, strength: float
) -> dict[str, float]:
    return {
        route_id: global_threshold + strength * (threshold - global_threshold)
        for route_id, threshold in thresholds.items()
    }


def cross_validate_threshold_strategy(
    records: Sequence[dict[str, Any]],
    score_rows: Sequence[dict[str, Any]],
    route_order: Sequence[str],
) -> tuple[float, str, dict[str, Any]]:
    records_by_id = {record["case_id"]: record for record in records}
    scores_by_id = {row["case_id"]: row for row in score_rows}
    folds = _stratified_fold_ids(records)
    predictions: dict[tuple[float, str], list[dict[str, Any]]] = {
        (strength, arbitration): []
        for strength in SHRINKAGE_GRID
        for arbitration in ARBITRATION_RULES
    }
    fold_details: list[dict[str, Any]] = []
    all_ids = set(records_by_id)
    for fold_index, validation_ids in enumerate(folds):
        train_ids = all_ids - validation_ids
        train_records = [records_by_id[case_id] for case_id in sorted(train_ids)]
        train_scores = [scores_by_id[case_id] for case_id in sorted(train_ids)]
        validation_scores = [
            scores_by_id[case_id] for case_id in sorted(validation_ids)
        ]
        global_threshold, _, _ = _tune_threshold(train_records, train_scores)
        route_thresholds, _ = tune_per_route_thresholds(
            train_records, train_scores, route_order
        )
        fold_details.append(
            {
                "fold": fold_index,
                "train_records": len(train_records),
                "validation_records": len(validation_ids),
                "global_threshold": global_threshold,
                "route_thresholds": route_thresholds,
            }
        )
        for strength in SHRINKAGE_GRID:
            shrunk = _shrink_thresholds(
                route_thresholds, global_threshold, strength
            )
            for arbitration in ARBITRATION_RULES:
                predictions[(strength, arbitration)].extend(
                    predict_per_route_thresholds(
                        validation_scores,
                        shrunk,
                        route_order,
                        arbitration=arbitration,
                    )
                )
    candidates: dict[str, Any] = {}
    best: tuple[tuple[float, float, float, float, float, int], float, str] | None = None
    for strength in SHRINKAGE_GRID:
        for arbitration in ARBITRATION_RULES:
            metrics = classification_metrics(
                records, predictions[(strength, arbitration)]
            )
            candidate_id = f"shrinkage={strength:.2f};arbitration={arbitration}"
            candidates[candidate_id] = metrics
            rank = (
                metrics["macro_f1_20_route"],
                metrics["accuracy"],
                metrics["general_recall"],
                -metrics["false_specialist_activation_rate"],
                -strength,
                -ARBITRATION_RULES.index(arbitration),
            )
            if best is None or rank > best[0]:
                best = rank, strength, arbitration
    assert best is not None
    return (
        best[1],
        best[2],
        {
            "fold_count": len(folds),
            "stratification": "gold_route_id+difficulty;case_id_sorted_round_robin",
            "selection_metric": "out_of_fold_macro_f1_20_route",
            "candidates": candidates,
            "folds": fold_details,
        },
    )


def compare_threshold_strategies(
    *,
    dev_path: Path,
    frozen_path: Path,
    embeddings_path: Path,
    output_dir: Path,
) -> Path:
    if output_dir.exists():
        raise FacetRouteBenchError(
            f"refusing to overwrite output directory: {output_dir}"
        )
    output_dir.mkdir(parents=True)
    embeddings = read_jsonl(embeddings_path)
    dev_records = _load_eval_records(dev_path, "dev")
    frozen_records = _load_eval_records(frozen_path, "frozen")
    specialist_routes = load_route_contract()["route_order"][:-1]
    dev_scores = _score_rows(dev_records, embeddings, SPECIALIST_CANDIDATE)
    frozen_scores = _score_rows(frozen_records, embeddings, SPECIALIST_CANDIDATE)

    global_threshold, global_dev_metrics, global_dev_predictions = _tune_threshold(
        dev_records, dev_scores
    )
    global_frozen_predictions = [
        {
            **row,
            "predicted_route_id": (
                row["top_route_id"]
                if float(row["top_score"]) >= global_threshold
                else "GENERAL"
            ),
        }
        for row in frozen_scores
    ]
    global_frozen_metrics = classification_metrics(
        frozen_records, global_frozen_predictions
    )

    thresholds, threshold_diagnostics = tune_per_route_thresholds(
        dev_records, dev_scores, specialist_routes
    )
    selected_shrinkage, selected_arbitration, cross_validation = (
        cross_validate_threshold_strategy(
            dev_records, dev_scores, specialist_routes
        )
    )
    refit_thresholds = _shrink_thresholds(
        thresholds, global_threshold, selected_shrinkage
    )
    arbitration_results: dict[str, dict[str, Any]] = {}
    arbitration_predictions: dict[str, tuple[list[dict[str, Any]], list[dict[str, Any]]]] = {}
    for arbitration in ARBITRATION_RULES:
        dev_predictions = predict_per_route_thresholds(
            dev_scores, refit_thresholds, specialist_routes, arbitration=arbitration
        )
        frozen_predictions = predict_per_route_thresholds(
            frozen_scores,
            refit_thresholds,
            specialist_routes,
            arbitration=arbitration,
        )
        arbitration_predictions[arbitration] = (dev_predictions, frozen_predictions)
        arbitration_results[arbitration] = {
            "dev_metrics": classification_metrics(dev_records, dev_predictions),
            "frozen_metrics": classification_metrics(frozen_records, frozen_predictions),
        }
    per_route_dev_predictions, per_route_frozen_predictions = arbitration_predictions[
        selected_arbitration
    ]

    prediction_paths = {
        "global_dev": output_dir / "global.dev.predictions.jsonl",
        "global_frozen": output_dir / "global.frozen.predictions.jsonl",
        "per_route_dev": output_dir / "per-route.dev.predictions.jsonl",
        "per_route_frozen": output_dir / "per-route.frozen.predictions.jsonl",
    }
    for key, rows in (
        ("global_dev", global_dev_predictions),
        ("global_frozen", global_frozen_predictions),
        ("per_route_dev", per_route_dev_predictions),
        ("per_route_frozen", per_route_frozen_predictions),
    ):
        write_jsonl(prediction_paths[key], rows)

    result = {
        "schema_version": "facetroutebench-threshold-comparison-v1",
        "created_at": utc_now(),
        "status": "retrospective_exploration",
        "warning": (
            "Frozen v2 had already been inspected before this experiment; "
            "these Frozen metrics are not a pristine confirmation result."
        ),
        "candidate_id": SPECIALIST_CANDIDATE,
        "datasets": {
            "dev": {"path": str(dev_path.resolve()), "sha256": sha256_file(dev_path)},
            "frozen": {
                "path": str(frozen_path.resolve()),
                "sha256": sha256_file(frozen_path),
            },
            "embeddings": {
                "path": str(embeddings_path.resolve()),
                "sha256": sha256_file(embeddings_path),
            },
        },
        "strategies": {
            "single_global_top1_threshold": {
                "threshold": global_threshold,
                "dev_metrics": global_dev_metrics,
                "frozen_metrics": global_frozen_metrics,
            },
            "per_route_one_vs_rest_threshold": {
                "thresholds": thresholds,
                "refit_thresholds": refit_thresholds,
                "threshold_tuning_metric": "per-route binary F1",
                "selected_arbitration": selected_arbitration,
                "selected_shrinkage": selected_shrinkage,
                "strategy_selection": "five_fold_stratified_cross_validation_on_dev",
                "cross_validation": cross_validation,
                "arbitration_candidates": arbitration_results,
                "no_accept_rule": "GENERAL",
                "dev_binary_diagnostics": threshold_diagnostics,
                "dev_metrics": arbitration_results[selected_arbitration]["dev_metrics"],
                "frozen_metrics": arbitration_results[selected_arbitration][
                    "frozen_metrics"
                ],
            },
        },
        "predictions": {
            key: {"path": path.name, "sha256": sha256_file(path)}
            for key, path in prediction_paths.items()
        },
    }
    result_path = output_dir / "comparison.json"
    write_json(result_path, result)
    return result_path.resolve()
