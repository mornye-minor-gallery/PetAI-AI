from __future__ import annotations

import math
from pathlib import Path
from typing import Any

from .actionability_data import BinarySplit
from .common import ToolRouteBenchError, write_jsonl


def select_threshold(
    targets: Any, probabilities: Any, *, fixed_threshold: float | None = None,
) -> float:
    if fixed_threshold is not None:
        if (isinstance(fixed_threshold, bool)
                or not isinstance(fixed_threshold, (int, float))
                or not math.isfinite(fixed_threshold)
                or not 0 < fixed_threshold < 1):
            raise ToolRouteBenchError("fixed threshold must be finite and between zero and one")
        return float(fixed_threshold)
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
