from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

from .common import append_jsonl, read_jsonl
from .contracts import validate_result
from .datasets import Case
from .litert_target import Generation, LiteRTTarget
from .prompt_adapter import normalize_responses


def generate_cases(
    target: LiteRTTarget,
    cases: Iterable[Case],
    seeds: tuple[int, ...],
    output_path: Path,
) -> list[dict]:
    existing = read_jsonl(output_path)
    completed = {(row["case_id"], row["seed"]) for row in existing}
    pending_raw: list[dict] = []
    pending_context: list[tuple[Case, int, Generation]] = []

    def flush() -> None:
        if not pending_raw:
            return
        normalized = normalize_responses(pending_raw)
        rows: list[dict] = []
        for case, seed, result in pending_context:
            synthetic_id = f"{case.case_id}::seed={seed}"
            product = normalized[synthetic_id]
            row = {
                "case_id": case.case_id,
                "suite": case.suite,
                "seed": seed,
                "prompt": case.prompt,
                "expected": case.expected,
                "metadata": case.metadata,
                "raw_text": product["raw_text"],
                "visible_text": product["visible_text"],
                "header_syntax": (
                    "generation_error"
                    if result.error is not None
                    else product["header_syntax"]
                ),
                "memory_decision": product["memory_decision"],
                "latency_ms": result.latency_ms,
                "error": result.error,
                "guard_decision": result.guard_decision,
                "guard_label": result.guard_label,
                "guard_score": result.guard_score,
                "guard_latency_ms": result.guard_latency_ms,
                "generation_skipped": result.generation_skipped,
            }
            validate_result(row)
            rows.append(row)
        append_jsonl(output_path, rows)
        pending_raw.clear()
        pending_context.clear()

    for seed in seeds:
        for case in cases:
            if (case.case_id, seed) in completed:
                continue
            result = target.generate(case.prompt, seed)
            synthetic_id = f"{case.case_id}::seed={seed}"
            pending_raw.append({"case_id": synthetic_id, "raw_text": result.text})
            pending_context.append((case, seed, result))
            if len(pending_raw) >= 16:
                flush()
    flush()
    return read_jsonl(output_path)
