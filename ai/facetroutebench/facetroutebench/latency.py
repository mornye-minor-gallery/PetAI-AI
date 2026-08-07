from __future__ import annotations

import math
import statistics
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .common import FacetRouteBenchError, read_jsonl, utc_now, write_json


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        raise FacetRouteBenchError("latency input contains no samples")
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percentile
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def summarize_latency(
    *, predictions_path: Path, router_family: str, runtime_mode: str, output_path: Path
) -> Path:
    rows = read_jsonl(predictions_path)
    if runtime_mode not in {"warm", "cold"}:
        raise FacetRouteBenchError("runtime_mode must be warm or cold")
    if router_family == "gemma_generative":
        inference = [float(row["route_elapsed_ms"]) for row in rows]
    elif router_family == "embedding_similarity":
        inference = [
            float(row["embedding_inference_elapsed_ms"])
            + float(row["routing_elapsed_ms"])
            for row in rows
        ]
    else:
        raise FacetRouteBenchError("unknown router family")
    loads = [float(row["model_load_elapsed_ms"]) for row in rows]
    totals = [
        value + (load if runtime_mode == "cold" else 0.0)
        for value, load in zip(inference, loads, strict=True)
    ]
    errors = sum(bool(row.get("error")) for row in rows)
    elapsed_seconds = sum(totals) / 1000
    result: dict[str, Any] = {
        "schema_version": "facetroutebench-latency-summary-v1",
        "created_at": utc_now(),
        "scope": "router_only",
        "router_family": router_family,
        "runtime_mode": runtime_mode,
        "samples": len(rows),
        "p50_ms": round(_percentile(totals, 0.50), 6),
        "p95_ms": round(_percentile(totals, 0.95), 6),
        "mean_ms": round(statistics.fmean(totals), 6),
        "throughput_per_second": (
            round(len(rows) / elapsed_seconds, 6) if elapsed_seconds else None
        ),
        "model_load_mean_ms": round(statistics.fmean(loads), 6),
        "error_rate": errors / len(rows),
        "timeout_rate": sum(
            "timeout" in str(row.get("error", "")).lower() for row in rows
        )
        / len(rows),
    }
    write_json(output_path, result)
    return output_path.resolve()
