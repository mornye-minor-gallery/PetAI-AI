from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from typing import Any

import numpy as np

from .common import ToolRouteBenchError


AGGREGATIONS = {
    "max_similarity",
    "centroid_similarity",
    "top3_mean_similarity",
}


def cosine(left: Sequence[float], right: Sequence[float]) -> float:
    left_array = np.asarray(left, dtype=np.float64)
    right_array = np.asarray(right, dtype=np.float64)
    if left_array.ndim != 1 or right_array.ndim != 1 or left_array.shape != right_array.shape:
        raise ToolRouteBenchError("cosine vectors must be one-dimensional and equal-sized")
    denominator = float(np.linalg.norm(left_array) * np.linalg.norm(right_array))
    if denominator == 0 or not math.isfinite(denominator):
        raise ToolRouteBenchError("cosine vectors must have finite non-zero norm")
    value = float(np.dot(left_array, right_array) / denominator)
    if not math.isfinite(value):
        raise ToolRouteBenchError("cosine produced a non-finite value")
    return max(-1.0, min(1.0, value))


def aggregate_similarity(
    query: Sequence[float],
    prototypes: Sequence[Sequence[float]],
    method: str,
) -> float:
    if method not in AGGREGATIONS:
        raise ToolRouteBenchError(f"unsupported aggregation: {method}")
    if not prototypes:
        raise ToolRouteBenchError("at least one prototype is required")
    if method == "centroid_similarity":
        matrix = np.asarray(prototypes, dtype=np.float64)
        if matrix.ndim != 2:
            raise ToolRouteBenchError("prototype matrix must be two-dimensional")
        centroid = np.mean(matrix, axis=0)
        return cosine(query, centroid)

    scores = sorted((cosine(query, prototype) for prototype in prototypes), reverse=True)
    if method == "max_similarity":
        return scores[0]
    count = min(3, len(scores))
    return float(sum(scores[:count]) / count)


def positive_vs_normal_margin(
    query: Sequence[float],
    positives: Sequence[Sequence[float]],
    normals: Sequence[Sequence[float]],
    aggregation: str,
) -> float:
    return aggregate_similarity(query, positives, aggregation) - aggregate_similarity(
        query, normals, aggregation
    )


def route_state(active_tools: Iterable[str]) -> str:
    count = len(set(active_tools))
    if count == 0:
        return "normal"
    if count == 1:
        return "tool"
    return "conflict"


def multilabel_metrics(
    gold_rows: Sequence[Iterable[str]],
    predicted_rows: Sequence[Iterable[str]],
    tool_order: Sequence[str],
) -> dict[str, Any]:
    if len(gold_rows) != len(predicted_rows) or not gold_rows:
        raise ToolRouteBenchError("gold and prediction rows must be non-empty and equal-sized")
    tools = tuple(tool_order)
    tool_set = set(tools)
    gold = [set(row) for row in gold_rows]
    predicted = [set(row) for row in predicted_rows]
    if any((row - tool_set) for row in gold + predicted):
        raise ToolRouteBenchError("metrics received an unknown tool ID")

    normal_indices = [index for index, row in enumerate(gold) if not row]
    false_activations = sum(bool(predicted[index]) for index in normal_indices)
    exact = sum(left == right for left, right in zip(gold, predicted, strict=True))
    hamming_errors = sum(
        len(left.symmetric_difference(right))
        for left, right in zip(gold, predicted, strict=True)
    )

    per_tool: dict[str, dict[str, float]] = {}
    f1_values: list[float] = []
    for tool in tools:
        true_positive = sum(tool in left and tool in right for left, right in zip(gold, predicted, strict=True))
        false_positive = sum(tool not in left and tool in right for left, right in zip(gold, predicted, strict=True))
        false_negative = sum(tool in left and tool not in right for left, right in zip(gold, predicted, strict=True))
        precision = true_positive / (true_positive + false_positive) if true_positive + false_positive else 0.0
        recall = true_positive / (true_positive + false_negative) if true_positive + false_negative else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per_tool[tool] = {"precision": precision, "recall": recall, "f1": f1}
        f1_values.append(f1)

    return {
        "record_count": len(gold),
        "exact_match": exact / len(gold),
        "hamming_loss": hamming_errors / (len(gold) * len(tools)),
        "normal_count": len(normal_indices),
        "normal_false_activation_count": false_activations,
        "normal_false_activation_rate": (
            false_activations / len(normal_indices) if normal_indices else 0.0
        ),
        "single_track_macro_f1": sum(f1_values) / len(f1_values),
        "per_tool": per_tool,
    }


def select_safe_candidate(
    regex_baseline: dict[str, Any],
    candidates: Sequence[dict[str, Any]],
) -> dict[str, Any] | None:
    baseline_false_activation = float(regex_baseline["normal_false_activation_rate"])
    baseline_macro_f1 = float(regex_baseline["single_track_macro_f1"])
    for candidate in candidates:
        if not isinstance(candidate.get("oof_metrics"), dict):
            raise ToolRouteBenchError(
                "candidate selection requires explicit oof_metrics"
            )
    eligible = [
        candidate
        for candidate in candidates
        if float(candidate["oof_metrics"]["normal_false_activation_rate"])
        <= baseline_false_activation
        and float(candidate["oof_metrics"]["single_track_macro_f1"])
        > baseline_macro_f1
    ]
    if not eligible:
        return None
    return sorted(
        eligible,
        key=lambda item: (
            -float(item["oof_metrics"]["single_track_macro_f1"]),
            float(item["oof_metrics"]["normal_false_activation_rate"]),
            str(item["candidate_id"]),
        ),
    )[0]
