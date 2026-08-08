from __future__ import annotations

import math
import statistics
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .common import (
    FacetRouteBenchError,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import (
    load_route_contract,
    validate_record_schema,
    validate_record_semantics,
)
from .manifests import embedding_run_manifest, write_validated_manifest

EMBEDDING_CANDIDATES = (
    "raw_scene_card",
    "route_description",
    "utterance_prototype",
    "description_plus_prototype",
    "utterance_prototype_vs_general",
)
GENERAL_COMPETITION_CANDIDATE = "utterance_prototype_vs_general"


def cosine(left: Sequence[float], right: Sequence[float]) -> float:
    if len(left) != len(right) or not left:
        raise FacetRouteBenchError("cosine vectors must have equal non-zero dimensions")
    dot = sum(a * b for a, b in zip(left, right, strict=True))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        raise FacetRouteBenchError("cosine vector norm must be non-zero")
    score = dot / (left_norm * right_norm)
    if not math.isfinite(score):
        raise FacetRouteBenchError("cosine score must be finite")
    return max(-1.0, min(1.0, score))


def _references(
    embeddings: Sequence[dict[str, Any]],
    candidate_id: str,
) -> dict[str, list[list[float]]]:
    if candidate_id not in EMBEDDING_CANDIDATES:
        raise FacetRouteBenchError(f"unknown embedding candidate: {candidate_id}")
    all_routes = load_route_contract()["route_order"]
    route_order = (
        all_routes
        if candidate_id == GENERAL_COMPETITION_CANDIDATE
        else all_routes[:-1]
    )
    references: dict[str, list[list[float]]] = {route: [] for route in route_order}
    allowed_kinds = {
        "raw_scene_card": {"route_card"},
        "route_description": {"route_description"},
        "utterance_prototype": {"prototype"},
        "description_plus_prototype": {"route_description", "prototype"},
        "utterance_prototype_vs_general": {"prototype"},
    }[candidate_id]
    for item in embeddings:
        if item.get("kind") in allowed_kinds and item.get("route_id") in references:
            vector = item.get("embedding")
            if not isinstance(vector, list) or len(vector) != 768:
                raise FacetRouteBenchError(
                    "reference embedding must contain 768 values"
                )
            references[item["route_id"]].append(vector)
    empty = [route for route, vectors in references.items() if not vectors]
    if empty:
        raise FacetRouteBenchError(f"candidate references are incomplete: {empty}")
    expected_per_route = {
        "raw_scene_card": 1,
        "route_description": 1,
        "utterance_prototype": 12,
        "description_plus_prototype": 13,
        "utterance_prototype_vs_general": 12,
    }[candidate_id]
    invalid_counts = {
        route: len(vectors)
        for route, vectors in references.items()
        if len(vectors)
        != (
            240
            if candidate_id == GENERAL_COMPETITION_CANDIDATE
            and route == "GENERAL"
            else expected_per_route
        )
    }
    if invalid_counts:
        raise FacetRouteBenchError(
            f"candidate reference counts violate contract: {invalid_counts}"
        )
    return references


def route_embedding(
    vector: Sequence[float],
    references: dict[str, list[list[float]]],
    route_order: Sequence[str],
) -> tuple[str, float, str, float]:
    started = time.perf_counter()
    scores = [
        (max(cosine(vector, reference) for reference in references[route]), route)
        for route in route_order
    ]
    ordered = sorted(scores, key=lambda item: (-item[0], route_order.index(item[1])))
    elapsed_ms = (time.perf_counter() - started) * 1000
    return ordered[0][1], ordered[0][0], ordered[1][1], elapsed_ms


def route_embedding_scores(
    vector: Sequence[float],
    references: dict[str, list[list[float]]],
    route_order: Sequence[str],
) -> tuple[dict[str, float], float]:
    started = time.perf_counter()
    scores = {
        route: max(cosine(vector, reference) for reference in references[route])
        for route in route_order
    }
    elapsed_ms = (time.perf_counter() - started) * 1000
    return scores, elapsed_ms


def _prediction(top_route: str, top_score: float, threshold: float) -> str:
    return top_route if top_score >= threshold else "GENERAL"


def classification_metrics(
    records: Sequence[dict[str, Any]],
    predictions: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    if len(records) != len(predictions):
        raise FacetRouteBenchError("record and prediction counts differ")
    by_id = {item["case_id"]: item for item in predictions}
    if len(by_id) != len(predictions):
        raise FacetRouteBenchError("predictions contain duplicate case IDs")
    route_contract = load_route_contract()
    route_order = route_contract["route_order"]
    confusion = {gold: {pred: 0 for pred in route_order} for gold in route_order}
    pairs: list[tuple[dict[str, Any], str]] = []
    for record in records:
        prediction = by_id.get(record["case_id"])
        if (
            prediction is None
            or prediction.get("predicted_route_id") not in route_order
        ):
            raise FacetRouteBenchError(f"missing prediction for {record['case_id']}")
        predicted = prediction["predicted_route_id"]
        confusion[record["gold_route_id"]][predicted] += 1
        pairs.append((record, predicted))

    per_route: dict[str, dict[str, float | int]] = {}
    for route in route_order:
        tp = confusion[route][route]
        fp = sum(confusion[gold][route] for gold in route_order if gold != route)
        fn = sum(confusion[route][pred] for pred in route_order if pred != route)
        support = sum(confusion[route].values())
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = (
            2 * precision * recall / (precision + recall) if precision + recall else 0.0
        )
        per_route[route] = {
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "support": support,
        }
    accuracy = sum(
        gold == predicted
        for gold, predicted in (
            (record["gold_route_id"], predicted) for record, predicted in pairs
        )
    ) / len(records)
    macro_f1 = statistics.fmean(per_route[route]["f1"] for route in route_order)

    facet_by_route = {
        route: detail["facet_id"] for route, detail in route_contract["routes"].items()
    }
    coarse_accuracy = statistics.fmean(
        facet_by_route[record["gold_route_id"]] == facet_by_route[predicted]
        for record, predicted in pairs
    )
    general_rows = [
        (record, predicted)
        for record, predicted in pairs
        if record["gold_route_id"] == "GENERAL"
    ]
    false_activation = (
        statistics.fmean(predicted != "GENERAL" for _, predicted in general_rows)
        if general_rows
        else 0.0
    )

    difficulty_metrics: dict[str, Any] = {}
    for difficulty in sorted({record["difficulty"] for record in records}):
        subset = [
            (record, predicted)
            for record, predicted in pairs
            if record["difficulty"] == difficulty
        ]
        labels = sorted(
            {record["gold_route_id"] for record, _ in subset},
            key=route_order.index,
        )
        f1_values: list[float] = []
        for label in labels:
            tp = sum(
                record["gold_route_id"] == label and pred == label
                for record, pred in subset
            )
            fp = sum(
                record["gold_route_id"] != label and pred == label
                for record, pred in subset
            )
            fn = sum(
                record["gold_route_id"] == label and pred != label
                for record, pred in subset
            )
            precision = tp / (tp + fp) if tp + fp else 0.0
            recall = tp / (tp + fn) if tp + fn else 0.0
            f1_values.append(
                2 * precision * recall / (precision + recall)
                if precision + recall
                else 0.0
            )
        difficulty_metrics[difficulty] = {
            "macro_f1": statistics.fmean(f1_values),
            "records": len(subset),
        }

    return {
        "record_count": len(records),
        "macro_f1_20_route": macro_f1,
        "accuracy": accuracy,
        "coarse_facet_accuracy": coarse_accuracy,
        "general_precision": per_route["GENERAL"]["precision"],
        "general_recall": per_route["GENERAL"]["recall"],
        "false_specialist_activation_rate": false_activation,
        "error_rate": statistics.fmean(bool(item.get("error")) for item in predictions),
        "timeout_rate": statistics.fmean(
            "timeout" in str(item.get("error", "")).lower() for item in predictions
        ),
        "per_route": per_route,
        "difficulty": difficulty_metrics,
        "confusion_matrix": confusion,
    }


def _score_rows(
    records: Sequence[dict[str, Any]],
    embeddings: Sequence[dict[str, Any]],
    candidate_id: str,
) -> list[dict[str, Any]]:
    query_by_case = {
        item["case_id"]: item
        for item in embeddings
        if item.get("kind") == "query" and item.get("case_id")
    }
    query_items = [
        item
        for item in embeddings
        if item.get("kind") == "query" and item.get("case_id")
    ]
    if len(query_by_case) != len(query_items):
        raise FacetRouteBenchError("query embeddings contain duplicate case IDs")
    all_routes = load_route_contract()["route_order"]
    route_order = (
        all_routes
        if candidate_id == GENERAL_COMPETITION_CANDIDATE
        else all_routes[:-1]
    )
    references = _references(embeddings, candidate_id)
    rows: list[dict[str, Any]] = []
    for record in records:
        query = query_by_case.get(record["case_id"])
        if query is None:
            raise FacetRouteBenchError(f"missing query embedding: {record['case_id']}")
        route_scores, routing_ms = route_embedding_scores(
            query["embedding"], references, route_order
        )
        ordered = sorted(
            route_scores.items(),
            key=lambda item: (-item[1], route_order.index(item[0])),
        )
        top_route, top_score = ordered[0]
        second_route = ordered[1][0]
        rows.append(
            {
                "case_id": record["case_id"],
                "top_route_id": top_route,
                "top_score": top_score,
                "second_route_id": second_route,
                "route_scores": route_scores,
                "model_load_elapsed_ms": query.get("model_load_elapsed_ms"),
                "embedding_inference_elapsed_ms": query.get("inference_elapsed_ms"),
                "routing_elapsed_ms": round(routing_ms, 6),
            }
        )
    return rows


def _load_eval_records(path: Path, expected_split: str) -> list[dict[str, Any]]:
    records = read_jsonl(path)
    if not records or any(record["split"] != expected_split for record in records):
        raise FacetRouteBenchError(
            f"runner accepts only a non-empty {expected_split} split"
        )
    expected_count = {"dev": 696, "frozen": 696, "context_challenge": 60}[
        expected_split
    ]
    if len(records) != expected_count:
        raise FacetRouteBenchError(
            f"{expected_split} requires {expected_count} records, found {len(records)}"
        )
    for record in records:
        validate_record_schema(record)
        validate_record_semantics(record)
    return records


def _tune_threshold(
    records: Sequence[dict[str, Any]],
    score_rows: Sequence[dict[str, Any]],
) -> tuple[float, dict[str, Any], list[dict[str, Any]]]:
    scores = sorted({float(item["top_score"]) for item in score_rows})
    thresholds = [-1.000001, *(math.nextafter(score, math.inf) for score in scores)]
    best: (
        tuple[
            tuple[float, float, float, float],
            float,
            dict[str, Any],
            list[dict[str, Any]],
        ]
        | None
    ) = None
    for threshold in thresholds:
        predictions = [
            {
                **item,
                "predicted_route_id": _prediction(
                    item["top_route_id"], item["top_score"], threshold
                ),
            }
            for item in score_rows
        ]
        metrics = classification_metrics(records, predictions)
        rank = (
            metrics["macro_f1_20_route"],
            metrics["accuracy"],
            metrics["general_recall"],
            -metrics["false_specialist_activation_rate"],
        )
        if best is None or rank > best[0] or (rank == best[0] and threshold < best[1]):
            best = rank, threshold, metrics, predictions
    assert best is not None
    return best[1], best[2], best[3]


def run_embedding_dev(
    *,
    dev_path: Path,
    embeddings_path: Path,
    output_dir: Path,
) -> Path:
    if output_dir.exists():
        raise FacetRouteBenchError(
            f"refusing to overwrite output directory: {output_dir}"
        )
    records = _load_eval_records(dev_path, "dev")
    embeddings = read_jsonl(embeddings_path)
    output_dir.mkdir(parents=True)
    started_at = utc_now()
    summary: dict[str, Any] = {
        "schema_version": "facetroutebench-embedding-dev-v1",
        "created_at": utc_now(),
        "dataset": {"path": str(dev_path.resolve()), "sha256": sha256_file(dev_path)},
        "embeddings": {
            "path": str(embeddings_path.resolve()),
            "sha256": sha256_file(embeddings_path),
        },
        "candidates": {},
    }
    for candidate_id in EMBEDDING_CANDIDATES:
        score_rows = _score_rows(records, embeddings, candidate_id)
        if candidate_id == GENERAL_COMPETITION_CANDIDATE:
            threshold = None
            predictions = [
                {**item, "predicted_route_id": item["top_route_id"]}
                for item in score_rows
            ]
            metrics = classification_metrics(records, predictions)
            decision_rule = "specialist_vs_general_top1"
            notes = "Dev direct competition; max cosine; GENERAL prototypes included."
        else:
            threshold, metrics, predictions = _tune_threshold(records, score_rows)
            decision_rule = "single_global_top1_threshold"
            notes = "Dev threshold tuning; max cosine; single global threshold."
        prediction_path = output_dir / f"{candidate_id}.predictions.jsonl"
        write_jsonl(prediction_path, predictions)
        candidate_result = {
            "schema_version": "facetroutebench-embedding-dev-candidate-v1",
            "created_at": utc_now(),
            "candidate_id": candidate_id,
            "decision_rule": decision_rule,
            "threshold": threshold,
            "metrics": metrics,
            "predictions": {
                "path": prediction_path.name,
                "sha256": sha256_file(prediction_path),
            },
        }
        candidate_result_path = output_dir / f"{candidate_id}.result.json"
        write_json(candidate_result_path, candidate_result)
        manifest = embedding_run_manifest(
            run_id=f"{output_dir.name}-{candidate_id}",
            track="controlled_single_turn",
            candidate_id=candidate_id,
            dataset_path=dev_path,
            record_count=len(records),
            dataset_version=records[0]["dataset_version"],
            embeddings_path=embeddings_path,
            result_path=candidate_result_path,
            started_at=started_at,
            notes=notes,
        )
        manifest_path = output_dir / f"{candidate_id}.run_manifest.json"
        write_validated_manifest(manifest_path, manifest)
        summary["candidates"][candidate_id] = {
            **candidate_result,
            "run_manifest": {
                "path": manifest_path.name,
                "sha256": sha256_file(manifest_path),
            },
        }
    write_json(output_dir / "dev_summary.json", summary)
    return (output_dir / "dev_summary.json").resolve()


def select_embedding_candidate(
    *,
    dev_summary_path: Path,
    frozen_path: Path,
    route_contract_path: Path,
    output_path: Path,
) -> Path:
    summary = read_json(dev_summary_path)
    candidates = summary["candidates"]
    selected_id, selected = max(
        candidates.items(),
        key=lambda item: (
            item[1]["metrics"]["macro_f1_20_route"],
            item[1]["metrics"]["accuracy"],
            item[1]["metrics"]["general_recall"],
            -item[1]["metrics"]["false_specialist_activation_rate"],
            -EMBEDDING_CANDIDATES.index(item[0]),
        ),
    )
    lock = {
        "schema_version": "facetroutebench-frozen-selection-v1",
        "created_at": utc_now(),
        "candidate_id": selected_id,
        "decision_rule": selected["decision_rule"],
        "threshold": selected["threshold"],
        "selection_metric": "macro_f1_20_route",
        "dev_summary": {
            "path": str(dev_summary_path.resolve()),
            "sha256": sha256_file(dev_summary_path),
        },
        "frozen_dataset": {
            "path": str(frozen_path.resolve()),
            "sha256": sha256_file(frozen_path),
        },
        "route_contract": {
            "path": str(route_contract_path.resolve()),
            "sha256": sha256_file(route_contract_path),
        },
        "embedding_contract": {
            "aggregation": "max_similarity",
            "similarity": "cosine",
            "rejection": selected["decision_rule"],
            "top1_top2_margin_enabled": False,
        },
    }
    write_json(output_path, lock)
    return output_path.resolve()


def run_embedding_frozen(
    *,
    selection_path: Path,
    frozen_path: Path,
    embeddings_path: Path,
    output_dir: Path,
) -> Path:
    if output_dir.exists():
        raise FacetRouteBenchError(
            f"refusing to overwrite output directory: {output_dir}"
        )
    selection = read_json(selection_path)
    if sha256_file(frozen_path) != selection["frozen_dataset"]["sha256"]:
        raise FacetRouteBenchError("Frozen dataset SHA does not match selection lock")
    route_path = Path(selection["route_contract"]["path"])
    if sha256_file(route_path) != selection["route_contract"]["sha256"]:
        raise FacetRouteBenchError("Route contract changed after candidate selection")
    started_at = utc_now()
    records = _load_eval_records(frozen_path, "frozen")
    embeddings = read_jsonl(embeddings_path)
    score_rows = _score_rows(records, embeddings, selection["candidate_id"])
    threshold = selection["threshold"]
    if selection["decision_rule"] == "specialist_vs_general_top1":
        predictions = [
            {**item, "predicted_route_id": item["top_route_id"]}
            for item in score_rows
        ]
    else:
        threshold = float(threshold)
        predictions = [
            {
                **item,
                "predicted_route_id": _prediction(
                    item["top_route_id"], item["top_score"], threshold
                ),
            }
            for item in score_rows
        ]
    metrics = classification_metrics(records, predictions)
    output_dir.mkdir(parents=True)
    prediction_path = output_dir / "predictions.jsonl"
    write_jsonl(prediction_path, predictions)
    result = {
        "schema_version": "facetroutebench-embedding-frozen-v1",
        "created_at": utc_now(),
        "candidate_id": selection["candidate_id"],
        "decision_rule": selection["decision_rule"],
        "threshold": threshold,
        "selection": {
            "path": str(selection_path.resolve()),
            "sha256": sha256_file(selection_path),
        },
        "dataset": {
            "path": str(frozen_path.resolve()),
            "sha256": sha256_file(frozen_path),
        },
        "embeddings": {
            "path": str(embeddings_path.resolve()),
            "sha256": sha256_file(embeddings_path),
        },
        "predictions": {
            "path": prediction_path.name,
            "sha256": sha256_file(prediction_path),
        },
        "metrics": metrics,
    }
    result_path = output_dir / "frozen_result.json"
    write_json(result_path, result)
    manifest = embedding_run_manifest(
        run_id=output_dir.name,
        track="controlled_single_turn",
        candidate_id=selection["candidate_id"],
        dataset_path=frozen_path,
        record_count=len(records),
        dataset_version=records[0]["dataset_version"],
        embeddings_path=embeddings_path,
        result_path=result_path,
        started_at=started_at,
        notes="Frozen evaluation; candidate and decision rule verified against selection lock.",
    )
    return write_validated_manifest(output_dir / "run_manifest.json", manifest)


def run_embedding_context(
    *,
    selection_path: Path,
    context_path: Path,
    embeddings_path: Path,
    output_dir: Path,
) -> Path:
    if output_dir.exists():
        raise FacetRouteBenchError(
            f"refusing to overwrite output directory: {output_dir}"
        )
    started_at = utc_now()
    selection = read_json(selection_path)
    route_path = Path(selection["route_contract"]["path"])
    if sha256_file(route_path) != selection["route_contract"]["sha256"]:
        raise FacetRouteBenchError("Route contract changed after candidate selection")
    records = _load_eval_records(context_path, "context_challenge")
    embeddings = read_jsonl(embeddings_path)
    score_rows = _score_rows(records, embeddings, selection["candidate_id"])
    threshold = selection["threshold"]
    if selection["decision_rule"] == "specialist_vs_general_top1":
        predictions = [
            {**item, "predicted_route_id": item["top_route_id"]}
            for item in score_rows
        ]
    else:
        threshold = float(threshold)
        predictions = [
            {
                **item,
                "predicted_route_id": _prediction(
                    item["top_route_id"], item["top_score"], threshold
                ),
            }
            for item in score_rows
        ]
    metrics = classification_metrics(records, predictions)
    output_dir.mkdir(parents=True)
    prediction_path = output_dir / "predictions.jsonl"
    write_jsonl(prediction_path, predictions)
    result_path = output_dir / "context_result.json"
    write_json(
        result_path,
        {
            "schema_version": "facetroutebench-embedding-context-v1",
            "created_at": utc_now(),
            "candidate_id": selection["candidate_id"],
            "decision_rule": selection["decision_rule"],
            "threshold": threshold,
            "context_policy": "current_user_input_only",
            "selection": {
                "path": str(selection_path.resolve()),
                "sha256": sha256_file(selection_path),
            },
            "predictions": {
                "path": prediction_path.name,
                "sha256": sha256_file(prediction_path),
            },
            "metrics": metrics,
        },
    )
    manifest = embedding_run_manifest(
        run_id=output_dir.name,
        track="context_challenge",
        candidate_id=selection["candidate_id"],
        dataset_path=context_path,
        record_count=len(records),
        dataset_version=records[0]["dataset_version"],
        embeddings_path=embeddings_path,
        result_path=result_path,
        started_at=started_at,
        notes="Context Challenge embedding arm; final user input only by contract.",
    )
    return write_validated_manifest(output_dir / "run_manifest.json", manifest)


def score_prediction_file(
    *, dataset_path: Path, predictions_path: Path, output_path: Path
) -> Path:
    records = read_jsonl(dataset_path)
    predictions = read_jsonl(predictions_path)
    write_json(
        output_path,
        {
            "created_at": utc_now(),
            "dataset_sha256": sha256_file(dataset_path),
            "predictions_sha256": sha256_file(predictions_path),
            "metrics": classification_metrics(records, predictions),
        },
    )
    return output_path.resolve()
