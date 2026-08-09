from __future__ import annotations

import hashlib
import itertools
from pathlib import Path
from typing import Any, Sequence

from .common import (
    CONFIGS_DIR,
    ToolRouteBenchError,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
)
from .contracts import load_tool_contract
from .embedding import load_dataset_split
from .evaluation import aggregate_similarity, multilabel_metrics, positive_vs_normal_margin, select_safe_candidate
from .manifests import write_run_manifest
from .regex_baseline import validate_regex_predictions_artifact


def candidate_grid() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for representation in ("tool_id", "tool_description"):
        rows.append(
            {
                "representation": representation,
                "aggregation": "max_similarity",
                "normal_decision": "absolute_tool_threshold",
            }
        )
    for representation in ("utterance_prototype", "description_plus_prototype"):
        for aggregation in (
            "max_similarity",
            "centroid_similarity",
            "top3_mean_similarity",
        ):
            rows.append(
                {
                    "representation": representation,
                    "aggregation": aggregation,
                    "normal_decision": "absolute_tool_threshold",
                }
            )
    for aggregation in (
        "max_similarity",
        "centroid_similarity",
        "top3_mean_similarity",
    ):
        rows.append(
            {
                "representation": "utterance_prototype_vs_normal",
                "aggregation": aggregation,
                "normal_decision": "positive_vs_normal_margin",
            }
        )
    return [
        {**row, "threshold_structure": threshold}
        for row, threshold in itertools.product(
            rows, ("single_global", "raw_per_tool", "cv_shrunk_per_tool")
        )
    ]


def _embedding_index(path: Path) -> dict[str, list[float]]:
    rows = read_jsonl(path)
    index: dict[str, list[float]] = {}
    for row in rows:
        identifier = row.get("embedding_id")
        vector = row.get("embedding")
        if not isinstance(identifier, str) or not isinstance(vector, list) or len(vector) != 768:
            raise ToolRouteBenchError("embedding cache contains an invalid row")
        if identifier in index:
            raise ToolRouteBenchError("embedding cache contains duplicate IDs")
        index[identifier] = vector
    return index


def _prototype_index(
    embeddings_path: Path,
) -> tuple[
    dict[str, list[float]],
    dict[str, list[float]],
    dict[str, list[list[float]]],
    dict[str, list[list[float]]],
    dict[str, list[float]],
]:
    rows = read_jsonl(embeddings_path)
    tool_ids: dict[str, list[float]] = {}
    descriptions: dict[str, list[float]] = {}
    positives: dict[str, list[list[float]]] = {}
    normals: dict[str, list[list[float]]] = {}
    queries: dict[str, list[float]] = {}
    for row in rows:
        kind, tool, vector = row["kind"], row.get("tool_id"), row["embedding"]
        if kind == "tool_id":
            tool_ids[tool] = vector
        elif kind == "tool_description":
            descriptions[tool] = vector
        elif kind == "positive_prototype":
            positives.setdefault(tool, []).append(vector)
        elif kind == "normal_prototype":
            normals.setdefault(tool, []).append(vector)
        elif kind == "query":
            queries[row["case_id"]] = vector
    tools = load_tool_contract()["tool_order"]
    if any(tool not in tool_ids or tool not in descriptions for tool in tools):
        raise ToolRouteBenchError("embedding cache is missing Tool ID or description")
    if any(not positives.get(tool) or not normals.get(tool) for tool in tools):
        raise ToolRouteBenchError("embedding cache is missing positive or NORMAL prototypes")
    return tool_ids, descriptions, positives, normals, queries


def score_matrix(
    records: Sequence[dict[str, Any]],
    embeddings_path: Path,
    representation: str,
    aggregation: str,
) -> dict[str, dict[str, float]]:
    tool_ids, descriptions, positives, normals, queries = _prototype_index(
        embeddings_path
    )
    tools = load_tool_contract()["tool_order"]
    scores: dict[str, dict[str, float]] = {}
    for record in records:
        query = queries.get(record["case_id"])
        if query is None:
            raise ToolRouteBenchError(f"missing query embedding: {record['case_id']}")
        row: dict[str, float] = {}
        for tool in tools:
            if representation == "tool_id":
                row[tool] = aggregate_similarity(query, [tool_ids[tool]], "max_similarity")
            elif representation == "tool_description":
                row[tool] = aggregate_similarity(
                    query, [descriptions[tool]], "max_similarity"
                )
            elif representation == "utterance_prototype":
                row[tool] = aggregate_similarity(query, positives[tool], aggregation)
            elif representation == "description_plus_prototype":
                row[tool] = aggregate_similarity(
                    query, [descriptions[tool], *positives[tool]], aggregation
                )
            elif representation == "utterance_prototype_vs_normal":
                row[tool] = positive_vs_normal_margin(
                    query, positives[tool], normals[tool], aggregation
                )
            else:
                raise ToolRouteBenchError(f"unsupported representation: {representation}")
        scores[record["case_id"]] = row
    return scores


def _threshold_candidates(values: Sequence[float]) -> list[float]:
    unique = sorted(set(float(value) for value in values))
    if not unique:
        raise ToolRouteBenchError("cannot tune threshold without scores")
    return [
        unique[0] - 1e-9,
        *[(left + right) / 2 for left, right in zip(unique, unique[1:], strict=False)],
        unique[-1] + 1e-9,
    ]


def _predict(
    records: Sequence[dict[str, Any]],
    scores: dict[str, dict[str, float]],
    thresholds: dict[str, float],
) -> list[list[str]]:
    tools = load_tool_contract()["tool_order"]
    return [
        [tool for tool in tools if scores[row["case_id"]][tool] >= thresholds[tool]]
        for row in records
    ]


def _metrics(
    records: Sequence[dict[str, Any]], predicted: Sequence[Sequence[str]]
) -> dict[str, Any]:
    return multilabel_metrics(
        [row["gold_tool_ids"] for row in records],
        predicted,
        load_tool_contract()["tool_order"],
    )


def _best_global_threshold(
    records: Sequence[dict[str, Any]], scores: dict[str, dict[str, float]]
) -> tuple[dict[str, float], dict[str, Any]]:
    tools = load_tool_contract()["tool_order"]
    values = [
        scores[row["case_id"]][tool]
        for row in records
        for tool in tools
    ]
    best: tuple[tuple[float, float, float], float, dict[str, Any]] | None = None
    for threshold in _threshold_candidates(values):
        thresholds = {tool: threshold for tool in tools}
        metrics = _metrics(records, _predict(records, scores, thresholds))
        key = (
            metrics["single_track_macro_f1"],
            -metrics["normal_false_activation_rate"],
            threshold,
        )
        if best is None or key > best[0]:
            best = (key, threshold, metrics)
    assert best is not None
    return {tool: best[1] for tool in tools}, best[2]


def _binary_f1(gold: Sequence[bool], predicted: Sequence[bool]) -> float:
    true_positive = sum(left and right for left, right in zip(gold, predicted, strict=True))
    false_positive = sum(not left and right for left, right in zip(gold, predicted, strict=True))
    false_negative = sum(left and not right for left, right in zip(gold, predicted, strict=True))
    precision = true_positive / (true_positive + false_positive) if true_positive + false_positive else 0
    recall = true_positive / (true_positive + false_negative) if true_positive + false_negative else 0
    return 2 * precision * recall / (precision + recall) if precision + recall else 0


def _raw_per_tool_thresholds(
    records: Sequence[dict[str, Any]], scores: dict[str, dict[str, float]]
) -> dict[str, float]:
    thresholds: dict[str, float] = {}
    for tool in load_tool_contract()["tool_order"]:
        values = [scores[row["case_id"]][tool] for row in records]
        gold = [tool in row["gold_tool_ids"] for row in records]
        best: tuple[float, float] | None = None
        for threshold in _threshold_candidates(values):
            f1 = _binary_f1(gold, [value >= threshold for value in values])
            key = (f1, threshold)
            if best is None or key > best:
                best = key
        assert best is not None
        thresholds[tool] = best[1]
    return thresholds


def _label_stratum(record: dict[str, Any]) -> str:
    gold = record.get("gold_tool_ids")
    if not isinstance(gold, list) or any(not isinstance(tool, str) for tool in gold):
        raise ToolRouteBenchError("OOF record has invalid gold_tool_ids")
    return "+".join(sorted(gold)) if gold else "NORMAL"


def assign_oof_folds(
    records: Sequence[dict[str, Any]], count: int
) -> dict[str, int]:
    if count < 2:
        raise ToolRouteBenchError("OOF requires at least two folds")
    if len(records) < count:
        raise ToolRouteBenchError("OOF requires at least one record per fold")

    groups: dict[str, dict[str, Any]] = {}
    case_ids: set[str] = set()
    for record in records:
        case_id = record.get("case_id")
        family = record.get("expression_family_id")
        if not isinstance(case_id, str) or not case_id:
            raise ToolRouteBenchError("OOF record has no case_id")
        if case_id in case_ids:
            raise ToolRouteBenchError("OOF records contain duplicate case IDs")
        case_ids.add(case_id)
        if not isinstance(family, str) or not family:
            raise ToolRouteBenchError("OOF record has no expression_family_id")
        stratum = _label_stratum(record)
        group = groups.setdefault(family, {"stratum": stratum, "case_ids": []})
        if group["stratum"] != stratum:
            raise ToolRouteBenchError(
                "an expression family cannot contain different gold labels"
            )
        group["case_ids"].append(case_id)

    by_stratum: dict[str, list[str]] = {}
    for family, group in groups.items():
        by_stratum.setdefault(group["stratum"], []).append(family)

    assignments: dict[str, int] = {}
    for stratum, families in sorted(by_stratum.items()):
        ordered = sorted(
            families,
            key=lambda family: (
                hashlib.sha256(family.encode()).hexdigest(),
                family,
            ),
        )
        offset = int(hashlib.sha256(stratum.encode()).hexdigest()[:8], 16) % count
        for index, family in enumerate(ordered):
            fold = (offset + index) % count
            for case_id in groups[family]["case_ids"]:
                assignments[case_id] = fold

    fold_counts = [sum(fold == index for fold in assignments.values()) for index in range(count)]
    if any(value == 0 for value in fold_counts):
        raise ToolRouteBenchError("group-aware OOF produced an empty fold")
    if set(assignments) != case_ids:
        raise ToolRouteBenchError("OOF fold assignment is incomplete")
    return assignments


def _fit_thresholds(
    records: Sequence[dict[str, Any]],
    scores: dict[str, dict[str, float]],
    threshold_structure: str,
    *,
    shrinkage: float,
) -> dict[str, float]:
    global_thresholds, _ = _best_global_threshold(records, scores)
    if threshold_structure == "single_global":
        return global_thresholds

    raw = _raw_per_tool_thresholds(records, scores)
    if threshold_structure == "raw_per_tool":
        return raw
    if threshold_structure != "cv_shrunk_per_tool":
        raise ToolRouteBenchError(f"unknown threshold structure: {threshold_structure}")
    if not 0 <= shrinkage <= 1:
        raise ToolRouteBenchError("invalid threshold shrinkage")
    return {
        tool: shrinkage * global_thresholds[tool] + (1 - shrinkage) * raw[tool]
        for tool in load_tool_contract()["tool_order"]
    }


def tune_candidate(
    records: Sequence[dict[str, Any]],
    scores: dict[str, dict[str, float]],
    threshold_structure: str,
    *,
    cv_folds: int = 5,
    shrinkage: float = 0.5,
) -> tuple[
    dict[str, float],
    dict[str, Any],
    dict[str, Any],
    dict[str, int],
]:
    if cv_folds < 2 or not 0 <= shrinkage <= 1:
        raise ToolRouteBenchError("invalid cross-validation configuration")

    final_thresholds = _fit_thresholds(
        records,
        scores,
        threshold_structure,
        shrinkage=shrinkage,
    )
    training_metrics = _metrics(
        records, _predict(records, scores, final_thresholds)
    )
    fold_assignments = assign_oof_folds(records, cv_folds)
    out_of_fold: dict[str, list[str]] = {}
    for fold_index in range(cv_folds):
        train = [
            row
            for row in records
            if fold_assignments[row["case_id"]] != fold_index
        ]
        test = [
            row
            for row in records
            if fold_assignments[row["case_id"]] == fold_index
        ]
        if not train or not test:
            raise ToolRouteBenchError("cross-validation fold is empty")
        fold_thresholds = _fit_thresholds(
            train,
            scores,
            threshold_structure,
            shrinkage=shrinkage,
        )
        for row, prediction in zip(
            test,
            _predict(test, scores, fold_thresholds),
            strict=True,
        ):
            if row["case_id"] in out_of_fold:
                raise ToolRouteBenchError("OOF predicted a Dev row more than once")
            out_of_fold[row["case_id"]] = prediction
    if set(out_of_fold) != {row["case_id"] for row in records}:
        raise ToolRouteBenchError("cross-validation did not predict every Dev row")
    oof_metrics = _metrics(
        records, [out_of_fold[row["case_id"]] for row in records]
    )
    return final_thresholds, training_metrics, oof_metrics, fold_assignments


def load_baseline_predictions(
    path: Path, records: Sequence[dict[str, Any]]
) -> tuple[list[list[str]], dict[str, Any]]:
    rows = read_jsonl(path)
    by_id = {row.get("case_id"): row.get("predicted_tool_ids") for row in rows}
    expected = {record["case_id"] for record in records}
    if set(by_id) != expected:
        raise ToolRouteBenchError("Regex baseline predictions do not match Dev case IDs")
    tools = set(load_tool_contract()["tool_order"])
    predictions = []
    for record in records:
        predicted = by_id[record["case_id"]]
        if not isinstance(predicted, list) or len(predicted) != len(set(predicted)) or not set(predicted) <= tools:
            raise ToolRouteBenchError("Regex baseline contains invalid Tool IDs")
        predictions.append(predicted)
    return predictions, _metrics(records, predictions)


def score_regex_track(
    *,
    track: str,
    dataset_dir: Path,
    predictions_path: Path,
    output_path: Path,
) -> Path:
    git_commit(require_clean=True)
    if track not in {"dev", "holdout"}:
        raise ToolRouteBenchError("Regex scoring supports Dev or Holdout only")
    records = load_dataset_split(dataset_dir, track)
    dataset_path = dataset_dir / f"{track}.jsonl"
    regex_manifest = validate_regex_predictions_artifact(
        predictions_path, dataset_path
    )
    predictions, metrics = load_baseline_predictions(predictions_path, records)
    result = {
        "schema_version": "toolroutebench-regex-result-v1",
        "created_at": utc_now(),
        "track": track,
        "candidate_id": "swift-regex-router",
        "dataset_sha256": sha256_file(dataset_path),
        "predictions_sha256": sha256_file(predictions_path),
        "regex_manifest_sha256": sha256_file(
            predictions_path.with_suffix(".manifest.json")
        ),
        "swift_source": regex_manifest["swift_source"],
        "metrics": metrics,
        "predictions": [
            {"case_id": row["case_id"], "predicted_tool_ids": prediction}
            for row, prediction in zip(records, predictions, strict=True)
        ],
    }
    write_json(output_path, result)
    return output_path.resolve()


def run_dev_grid(
    *,
    dataset_dir: Path,
    embeddings_path: Path,
    regex_predictions_path: Path,
    output_dir: Path,
) -> Path:
    git_commit(require_clean=True)
    if output_dir.exists():
        raise ToolRouteBenchError(f"refusing to overwrite run: {output_dir}")
    records = load_dataset_split(dataset_dir, "dev")
    validate_regex_predictions_artifact(
        regex_predictions_path, dataset_dir / "dev.jsonl"
    )
    _, regex_metrics = load_baseline_predictions(regex_predictions_path, records)
    config = read_json(CONFIGS_DIR / "embedding-router.pilot.v1.json")
    candidates: list[dict[str, Any]] = []
    for index, spec in enumerate(candidate_grid(), start=1):
        scores = score_matrix(
            records,
            embeddings_path,
            spec["representation"],
            spec["aggregation"],
        )
        thresholds, training_metrics, oof_metrics, fold_assignments = tune_candidate(
            records,
            scores,
            spec["threshold_structure"],
            cv_folds=config["threshold_tuning"]["cv_folds"],
            shrinkage=config["threshold_tuning"]["shrinkage"],
        )
        candidates.append(
            {
                "candidate_id": f"embedding-{index:02d}",
                **spec,
                "thresholds": thresholds,
                "training_metrics": training_metrics,
                "oof_metrics": oof_metrics,
            }
        )
    selected = select_safe_candidate(regex_metrics, candidates)
    fold_counts = [
        sum(fold == index for fold in fold_assignments.values())
        for index in range(config["threshold_tuning"]["cv_folds"])
    ]
    output_dir.mkdir(parents=True)
    result = {
        "schema_version": "toolroutebench-dev-grid-v2",
        "created_at": utc_now(),
        "dataset_sha256": sha256_file(dataset_dir / "dev.jsonl"),
        "embeddings_sha256": sha256_file(embeddings_path),
        "regex_predictions_sha256": sha256_file(regex_predictions_path),
        "regex_baseline": regex_metrics,
        "selection_protocol": {
            "metric_source": "oof_metrics",
            "cv_folds": config["threshold_tuning"]["cv_folds"],
            "group_key": "expression_family_id",
            "stratification_key": "gold_tool_ids",
            "fold_counts": fold_counts,
        },
        "candidate_count": len(candidates),
        "candidates": candidates,
        "selected_candidate": selected,
        "pilot_result": "candidate_selected" if selected else "pilot_failed",
    }
    result_path = output_dir / "dev_results.json"
    write_json(result_path, result)
    if selected:
        write_json(output_dir / "selected_candidate.json", selected)
    write_run_manifest(
        output_path=output_dir / "run_manifest.json",
        track="dev",
        candidate_id="embedding-grid-33",
        dataset_path=dataset_dir / "dev.jsonl",
        embeddings_path=embeddings_path,
        result_path=result_path,
    )
    return result_path.resolve()


def create_holdout_lock(
    *, selected_candidate_path: Path, dataset_dir: Path, output_path: Path
) -> Path:
    git_commit(require_clean=True)
    candidate = read_json(selected_candidate_path)
    lock = {
        "schema_version": "toolroutebench-holdout-lock-v1",
        "created_at": utc_now(),
        "candidate": candidate,
        "candidate_sha256": sha256_file(selected_candidate_path),
        "holdout_sha256": sha256_file(dataset_dir / "holdout.jsonl"),
        "reused_after_tuning": False,
    }
    write_json(output_path, lock)
    return output_path.resolve()


def run_locked_track(
    *,
    track: str,
    dataset_dir: Path,
    embeddings_path: Path,
    lock_path: Path,
    output_path: Path,
) -> Path:
    git_commit(require_clean=True)
    split = {
        "holdout": "holdout",
        "multilabel_challenge": "multilabel_challenge",
    }.get(track)
    if split is None:
        raise ToolRouteBenchError("locked runner supports holdout or multilabel_challenge")
    lock = read_json(lock_path)
    if lock.get("schema_version") != "toolroutebench-holdout-lock-v1":
        raise ToolRouteBenchError("invalid holdout lock")
    if lock.get("reused_after_tuning") is not False:
        raise ToolRouteBenchError("a result-tuned Holdout may not be reused")
    if track == "holdout" and sha256_file(dataset_dir / "holdout.jsonl") != lock.get("holdout_sha256"):
        raise ToolRouteBenchError("Holdout SHA differs from the locked dataset")
    candidate = lock["candidate"]
    records = load_dataset_split(dataset_dir, split)
    scores = score_matrix(
        records,
        embeddings_path,
        candidate["representation"],
        candidate["aggregation"],
    )
    predictions = _predict(records, scores, candidate["thresholds"])
    result = {
        "schema_version": "toolroutebench-locked-result-v1",
        "created_at": utc_now(),
        "track": track,
        "candidate_id": candidate["candidate_id"],
        "dataset_sha256": sha256_file(dataset_dir / f"{split}.jsonl"),
        "lock_sha256": sha256_file(lock_path),
        "metrics": _metrics(records, predictions),
        "predictions": [
            {"case_id": row["case_id"], "predicted_tool_ids": prediction}
            for row, prediction in zip(records, predictions, strict=True)
        ],
    }
    write_json(output_path, result)
    write_run_manifest(
        output_path=output_path.parent / "run_manifest.json",
        track=track,
        candidate_id=candidate["candidate_id"],
        dataset_path=dataset_dir / f"{split}.jsonl",
        embeddings_path=embeddings_path,
        result_path=output_path,
        holdout_lock=track == "holdout",
    )
    return output_path.resolve()
