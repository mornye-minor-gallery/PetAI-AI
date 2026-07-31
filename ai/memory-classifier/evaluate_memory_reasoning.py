#!/usr/bin/env python3
"""Evaluate the wrapped-axis memory header with LiteRT-LM thinking on/off.

This runner uses LiteRT-LM's direct Python API because the 0.13.1
OpenAI-compatible server does not forward ``enable_thinking``. Normal response
content is passed through the same streaming header gate used by the existing
Python reference harness. Reasoning-channel content is recorded separately and
never passed to the gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import statistics
import tempfile
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

from hybrid_memory_harness import (
    HeaderSyntax,
    MemoryDecision,
    MemoryDecisionParser,
    MemoryHeaderFormat,
    MemoryHeaderGate,
    contains_control_leak,
)


RUNNER_VERSION = "0.1.0"
ANSWER_ONLY_RETRY = (
    "직전 사용자 발화에 직접 반응하는 자연스러운 한국어 답변 한 문장만 "
    "작성하세요. 사과하거나 지시를 언급하지 마세요. save 표시, 분류 라벨, "
    "괄호, JSON은 출력하지 마세요."
)


class ReasoningEvaluationError(RuntimeError):
    """Raised when the evaluation contract cannot be satisfied."""


@dataclass(frozen=True)
class GenerationTrace:
    normal_chunks: tuple[str, ...]
    channels: dict[str, str]
    elapsed_seconds: float
    first_any_seconds: float | None
    first_normal_seconds: float | None
    utterance_tokens: int
    normal_tokens: int
    reasoning_tokens: int
    conversation_tokens: int

    @property
    def normal_text(self) -> str:
        return "".join(self.normal_chunks)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def load_validation(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: invalid JSON"
                ) from error
            record_id = row.get("id")
            utterance = row.get("utterance")
            if row.get("split") != "validation":
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: expected validation split"
                )
            if not isinstance(record_id, str) or not record_id:
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: invalid id"
                )
            if record_id in seen:
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: duplicate id {record_id}"
                )
            if not isinstance(utterance, str) or not utterance.strip():
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: invalid utterance"
                )
            if type(row.get("preference")) is not bool:
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: preference must be bool"
                )
            if type(row.get("event")) is not bool:
                raise ReasoningEvaluationError(
                    f"{path.name}:{line_number}: event must be bool"
                )
            seen.add(record_id)
            rows.append(row)
    if len(rows) != 200:
        raise ReasoningEvaluationError(
            f"expected frozen validation size 200, found {len(rows)}"
        )
    counts = Counter(
        MemoryDecision.from_flags(
            preference=row["preference"],
            event=row["event"],
        ).value
        for row in rows
    )
    if counts != Counter({"N": 50, "P": 50, "E": 50, "B": 50}):
        raise ReasoningEvaluationError(
            f"validation labels are not balanced: {dict(counts)}"
        )
    return rows


def decode_chunks(chunks: Iterable[str]) -> dict[str, Any]:
    gate = MemoryHeaderGate(
        MemoryDecisionParser(
            header_format=MemoryHeaderFormat.WRAPPED_AXES
        )
    )
    for chunk in chunks:
        gate.consume(chunk)
    result = gate.finish()
    return {
        "decision": (
            result.decision.value if result.decision is not None else None
        ),
        "syntax": result.syntax.value,
        "raw_text": result.raw_text,
        "visible_text": result.visible_text.strip(),
        "control_text": result.control_text,
    }


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def describe(values: Sequence[float]) -> dict[str, Any]:
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "mean": statistics.fmean(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def decision_flags(label: str) -> tuple[bool, bool] | None:
    mapping = {
        "N": (False, False),
        "P": (True, False),
        "E": (False, True),
        "B": (True, True),
    }
    return mapping.get(label)


def binary_metrics(
    rows: Sequence[dict[str, Any]],
    axis_index: int,
) -> dict[str, Any]:
    resolved = [
        row for row in rows if decision_flags(row["predicted"]) is not None
    ]
    tp = fp = fn = tn = 0
    for row in resolved:
        expected = decision_flags(row["expected"])
        predicted = decision_flags(row["predicted"])
        assert expected is not None and predicted is not None
        if expected[axis_index] and predicted[axis_index]:
            tp += 1
        elif not expected[axis_index] and predicted[axis_index]:
            fp += 1
        elif expected[axis_index] and not predicted[axis_index]:
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
        "resolved_records": len(resolved),
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "true_negative": tn,
        "precision": precision,
        "recall": recall,
        "f1": f1,
    }


def summarize(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    exact = sum(row["exact_match"] for row in rows)
    confusion: dict[str, Counter[str]] = {
        label: Counter() for label in ("N", "P", "E", "B")
    }
    for row in rows:
        confusion[row["expected"]][row["predicted"] or "UNRESOLVED"] += 1
    return {
        "records": len(rows),
        "label_exact_match": exact / len(rows),
        "exact_matches": exact,
        "protocol": {
            "canonical_header_rate": sum(
                row["primary"]["syntax"] == HeaderSyntax.CANONICAL.value
                for row in rows
            )
            / len(rows),
            "chat_delivery_rate": sum(
                bool(row["visible_text"]) for row in rows
            )
            / len(rows),
            "retry_rate": sum(row["retry_attempted"] for row in rows)
            / len(rows),
            "control_leak_rate": sum(row["control_leak"] for row in rows)
            / len(rows),
            "unresolved_rate": sum(
                row["predicted"] is None for row in rows
            )
            / len(rows),
        },
        "by_expected_label": {
            label: {
                "records": sum(row["expected"] == label for row in rows),
                "exact_matches": sum(
                    row["expected"] == label and row["exact_match"]
                    for row in rows
                ),
                "accuracy": (
                    sum(
                        row["expected"] == label and row["exact_match"]
                        for row in rows
                    )
                    / sum(row["expected"] == label for row in rows)
                ),
                "predictions": dict(sorted(confusion[label].items())),
            }
            for label in ("N", "P", "E", "B")
        },
        "axes": {
            "preference": binary_metrics(rows, 0),
            "event": binary_metrics(rows, 1),
        },
        "latency_seconds": {
            "end_to_end": describe([
                row["elapsed_seconds"] for row in rows
            ]),
            "first_any": describe([
                row["first_any_seconds"]
                for row in rows
                if row["first_any_seconds"] is not None
            ]),
            "first_normal": describe([
                row["first_normal_seconds"]
                for row in rows
                if row["first_normal_seconds"] is not None
            ]),
        },
        "tokens": {
            "utterance": describe([
                float(row["tokens"]["utterance"]) for row in rows
            ]),
            "normal_response": describe([
                float(row["tokens"]["normal"]) for row in rows
            ]),
            "reasoning": describe([
                float(row["tokens"]["reasoning"]) for row in rows
            ]),
            "conversation_total": describe([
                float(row["tokens"]["conversation_total"]) for row in rows
            ]),
        },
    }


class DirectLiteRTRuntime:
    """One-engine, fresh-conversation-per-record LiteRT-LM runtime."""

    def __init__(
        self,
        *,
        model_path: Path,
        backend: str,
        max_num_tokens: int,
        temperature: float,
        top_p: float,
    ) -> None:
        try:
            import litert_lm
        except ImportError as error:
            raise ReasoningEvaluationError(
                "Run this evaluator with the Python environment that provides "
                "LiteRT-LM 0.13.1."
            ) from error
        self._litert_lm = litert_lm
        backend_value = {
            "cpu": litert_lm.Backend.CPU,
            "gpu": litert_lm.Backend.GPU,
        }.get(backend)
        if backend_value is None:
            raise ReasoningEvaluationError(f"unsupported backend: {backend}")
        self._engine_context = litert_lm.Engine(
            str(model_path),
            backend=backend_value(),
            max_num_tokens=max_num_tokens,
        )
        self._engine = self._engine_context.__enter__()
        self._sampler = litert_lm.SamplerConfig(
            temperature=temperature,
            top_p=top_p,
        )

    def close(self) -> None:
        self._engine_context.__exit__(None, None, None)

    def tokenize(self, text: str) -> int:
        return len(self._engine.tokenize(text))

    def generate(
        self,
        *,
        messages: list[dict[str, Any]],
        user_message: str,
        thinking_enabled: bool,
    ) -> GenerationTrace:
        normal_chunks: list[str] = []
        channels: dict[str, str] = {}
        first_any: float | None = None
        first_normal: float | None = None
        started = time.perf_counter()
        with self._engine.create_conversation(
            messages=messages,
            extra_context={"enable_thinking": thinking_enabled},
            filter_channel_content_from_kv_cache=True,
            sampler_config=self._sampler,
        ) as conversation:
            for chunk in conversation.send_message_async(user_message):
                elapsed = time.perf_counter() - started
                channel_payload = chunk.get("channels", {})
                content_payload = chunk.get("content", [])
                if (channel_payload or content_payload) and first_any is None:
                    first_any = elapsed
                for item in content_payload:
                    if item.get("type") != "text":
                        continue
                    text = item.get("text", "")
                    if text:
                        if first_normal is None:
                            first_normal = elapsed
                        normal_chunks.append(text)
                for name, text in channel_payload.items():
                    channels[name] = channels.get(name, "") + text
            conversation_tokens = conversation.token_count
        normal_text = "".join(normal_chunks)
        reasoning_text = "".join(channels.values())
        return GenerationTrace(
            normal_chunks=tuple(normal_chunks),
            channels=channels,
            elapsed_seconds=time.perf_counter() - started,
            first_any_seconds=first_any,
            first_normal_seconds=first_normal,
            utterance_tokens=self.tokenize(user_message),
            normal_tokens=self.tokenize(normal_text) if normal_text else 0,
            reasoning_tokens=(
                self.tokenize(reasoning_text) if reasoning_text else 0
            ),
            conversation_tokens=conversation_tokens,
        )


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(canonical_json(row) + "\n")


def run_evaluation(arguments: argparse.Namespace) -> Path:
    dataset_path = arguments.dataset.expanduser().resolve()
    prompt_path = arguments.prompt.expanduser().resolve()
    model_path = arguments.model_artifact.expanduser().resolve()
    output_dir = arguments.output_dir.expanduser().resolve()
    for path, description in (
        (dataset_path, "validation dataset"),
        (prompt_path, "wrapped-axis prompt"),
        (model_path, "LiteRT-LM model artifact"),
    ):
        if not path.is_file():
            raise ReasoningEvaluationError(
                f"{description} was not found: {path}"
            )
    if output_dir.exists():
        raise ReasoningEvaluationError(
            f"output directory already exists: {output_dir}"
        )

    rows_source = load_validation(dataset_path)
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}.",
            dir=output_dir.parent,
        )
    )
    results_path = temporary / "results.jsonl"
    state_path = temporary / "run_state.json"
    started_at = datetime.now(timezone.utc)
    state_path.write_text(
        json.dumps(
            {
                "phase": "running",
                "started_at": started_at.isoformat(),
                "completed_records": 0,
                "expected_records": len(rows_source),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    runtime = DirectLiteRTRuntime(
        model_path=model_path,
        backend=arguments.backend,
        max_num_tokens=arguments.max_num_tokens,
        temperature=arguments.temperature,
        top_p=arguments.top_p,
    )
    rows: list[dict[str, Any]] = []
    try:
        if arguments.warmup:
            runtime.generate(
                messages=[{"role": "system", "content": system_prompt}],
                user_message="오늘은 짧게 이야기해 보자.",
                thinking_enabled=arguments.thinking_enabled,
            )
        with results_path.open(
            "w", encoding="utf-8", newline="\n"
        ) as handle:
            for index, source in enumerate(rows_source, start=1):
                expected = MemoryDecision.from_flags(
                    preference=source["preference"],
                    event=source["event"],
                ).value
                trace = runtime.generate(
                    messages=[{"role": "system", "content": system_prompt}],
                    user_message=source["utterance"],
                    thinking_enabled=arguments.thinking_enabled,
                )
                primary = decode_chunks(trace.normal_chunks)
                visible_text = primary["visible_text"]
                retry_attempted = not bool(visible_text)
                retry: dict[str, Any] | None = None
                retry_trace: GenerationTrace | None = None
                if retry_attempted:
                    retry_trace = runtime.generate(
                        messages=[
                            {"role": "system", "content": system_prompt},
                            {"role": "user", "content": source["utterance"]},
                            {
                                "role": "assistant",
                                "content": trace.normal_text,
                            },
                        ],
                        user_message=ANSWER_ONLY_RETRY,
                        thinking_enabled=arguments.thinking_enabled,
                    )
                    retry = decode_chunks(retry_trace.normal_chunks)
                    visible_text = retry["visible_text"]

                predicted = primary["decision"]
                elapsed_seconds = trace.elapsed_seconds + (
                    retry_trace.elapsed_seconds
                    if retry_trace is not None
                    else 0.0
                )
                reasoning_channels = dict(trace.channels)
                if retry_trace is not None:
                    for name, text in retry_trace.channels.items():
                        reasoning_channels[f"retry:{name}"] = text
                row = {
                    "record_id": source["id"],
                    "utterance": source["utterance"],
                    "expected": expected,
                    "predicted": predicted,
                    "exact_match": (
                        predicted == expected
                        and primary["syntax"]
                        == HeaderSyntax.CANONICAL.value
                        and bool(visible_text)
                    ),
                    "thinking_enabled": arguments.thinking_enabled,
                    "primary": primary,
                    "retry_attempted": retry_attempted,
                    "retry": retry,
                    "visible_text": visible_text,
                    "control_leak": contains_control_leak(visible_text),
                    "reasoning_channels": reasoning_channels,
                    "elapsed_seconds": elapsed_seconds,
                    "first_any_seconds": trace.first_any_seconds,
                    "first_normal_seconds": trace.first_normal_seconds,
                    "tokens": {
                        "utterance": trace.utterance_tokens,
                        "normal": trace.normal_tokens,
                        "reasoning": trace.reasoning_tokens
                        + (
                            retry_trace.reasoning_tokens
                            if retry_trace is not None
                            else 0
                        ),
                        "conversation_total": trace.conversation_tokens
                        + (
                            retry_trace.conversation_tokens
                            if retry_trace is not None
                            else 0
                        ),
                    },
                }
                rows.append(row)
                handle.write(canonical_json(row) + "\n")
                handle.flush()
                state_path.write_text(
                    json.dumps(
                        {
                            "phase": "running",
                            "started_at": started_at.isoformat(),
                            "completed_records": index,
                            "expected_records": len(rows_source),
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                print(
                    f"Evaluated {index}/{len(rows_source)} "
                    f"exact={sum(item['exact_match'] for item in rows)}",
                    flush=True,
                )
    finally:
        runtime.close()

    manifest = {
        "phase": "memory_header_reasoning_evaluation_complete",
        "runner_version": RUNNER_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "started_at": started_at.isoformat(),
        "configuration": {
            "thinking_enabled": arguments.thinking_enabled,
            "backend": arguments.backend,
            "temperature": arguments.temperature,
            "top_p": arguments.top_p,
            "max_num_tokens": arguments.max_num_tokens,
            "warmup": arguments.warmup,
            "header_format": MemoryHeaderFormat.WRAPPED_AXES.value,
            "fallback": "disabled; malformed or absent header is unresolved",
            "reasoning_channel_policy": (
                "record separately; never pass to MemoryHeaderGate"
            ),
        },
        "provenance": {
            "dataset": {
                "path": str(dataset_path),
                "sha256": sha256_file(dataset_path),
            },
            "prompt": {
                "path": str(prompt_path),
                "sha256": sha256_file(prompt_path),
            },
            "model_artifact": {
                "path": str(model_path),
                "sha256": sha256_file(model_path),
            },
            "runtime": {
                "name": "LiteRT-LM",
                "version": arguments.runtime_version,
                "python": platform.python_version(),
                "platform": platform.platform(),
                "machine": platform.machine(),
            },
        },
        "metrics": summarize(rows),
        "artifacts": {
            "results": {
                "path": results_path.name,
                "records": len(rows),
                "sha256": sha256_file(results_path),
            }
        },
        "verification_scope": {
            "quality": "Exact deployment LiteRT-LM artifact on macOS.",
            "not_proven": [
                "iPhone latency",
                "iPhone memory",
                "iPhone thermal behavior",
                "iPhone battery behavior",
            ],
        },
        "runtime_contract_note": (
            "The legacy OpenAI-compatible server ignored max_tokens and did "
            "not expose enable_thinking. This direct runner fixes the engine "
            "context at max_num_tokens=4096 and records that difference."
        ),
    }
    manifest_path = temporary / "evaluation_manifest.json"
    manifest_path.write_text(
        json.dumps(
            manifest,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    state_path.write_text(
        json.dumps(
            {
                "phase": "complete",
                "started_at": started_at.isoformat(),
                "completed_at": manifest["created_at"],
                "completed_records": len(rows),
                "expected_records": len(rows),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, output_dir)
    return output_dir / manifest_path.name


def load_result_rows(path: Path) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            row = json.loads(line)
            record_id = row["record_id"]
            if record_id in rows:
                raise ReasoningEvaluationError(
                    f"duplicate paired record: {record_id}"
                )
            rows[record_id] = row
    return rows


def compare_results(
    baseline_path: Path,
    candidate_path: Path,
    output_path: Path,
) -> dict[str, Any]:
    baseline = load_result_rows(baseline_path)
    candidate = load_result_rows(candidate_path)
    if set(baseline) != set(candidate):
        raise ReasoningEvaluationError(
            "paired result record IDs do not match"
        )
    improved: list[str] = []
    regressed: list[str] = []
    stable_correct: list[str] = []
    stable_wrong: list[str] = []
    changed_predictions: list[dict[str, Any]] = []
    for record_id in sorted(baseline):
        before = baseline[record_id]
        after = candidate[record_id]
        before_correct = bool(
            before.get("exact_match", before.get("hybrid_label_correct"))
        )
        after_correct = bool(after["exact_match"])
        if not before_correct and after_correct:
            improved.append(record_id)
        elif before_correct and not after_correct:
            regressed.append(record_id)
        elif before_correct:
            stable_correct.append(record_id)
        else:
            stable_wrong.append(record_id)
        before_prediction = (
            before.get("predicted")
            or before.get("outcome", {}).get("decision")
        )
        if before_prediction != after["predicted"]:
            changed_predictions.append({
                "record_id": record_id,
                "expected": after["expected"],
                "baseline": before_prediction,
                "candidate": after["predicted"],
            })

    discordant = len(improved) + len(regressed)
    if discordant:
        tail = min(len(improved), len(regressed))
        p_value = min(
            1.0,
            2
            * sum(
                math.comb(discordant, value)
                for value in range(tail + 1)
            )
            / (2**discordant),
        )
    else:
        p_value = 1.0
    result = {
        "records": len(baseline),
        "improved": len(improved),
        "regressed": len(regressed),
        "stable_correct": len(stable_correct),
        "stable_wrong": len(stable_wrong),
        "changed_predictions": len(changed_predictions),
        "mcnemar_exact_two_sided_p": p_value,
        "record_ids": {
            "improved": improved,
            "regressed": regressed,
            "stable_wrong": stable_wrong,
        },
        "prediction_changes": changed_predictions,
        "inputs": {
            "baseline": {
                "path": str(baseline_path.resolve()),
                "sha256": sha256_file(baseline_path),
            },
            "candidate": {
                "path": str(candidate_path.resolve()),
                "sha256": sha256_file(candidate_path),
            },
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(
            result,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    run_parser = commands.add_parser("run")
    run_parser.add_argument("--dataset", required=True, type=Path)
    run_parser.add_argument("--prompt", required=True, type=Path)
    run_parser.add_argument("--model-artifact", required=True, type=Path)
    run_parser.add_argument("--output-dir", required=True, type=Path)
    run_parser.add_argument(
        "--thinking-enabled",
        action=argparse.BooleanOptionalAction,
        default=False,
    )
    run_parser.add_argument("--backend", choices=["cpu", "gpu"], default="gpu")
    run_parser.add_argument("--temperature", type=float, default=0.0)
    run_parser.add_argument("--top-p", type=float, default=1.0)
    run_parser.add_argument("--max-num-tokens", type=int, default=4096)
    run_parser.add_argument("--runtime-version", default="0.13.1")
    run_parser.add_argument(
        "--warmup",
        action=argparse.BooleanOptionalAction,
        default=True,
    )

    compare_parser = commands.add_parser("compare")
    compare_parser.add_argument("--baseline", required=True, type=Path)
    compare_parser.add_argument("--candidate", required=True, type=Path)
    compare_parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "run":
            result: Any = run_evaluation(arguments)
        else:
            result = compare_results(
                arguments.baseline,
                arguments.candidate,
                arguments.output,
            )
    except (
        ReasoningEvaluationError,
        OSError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        print(f"error: {error}")
        return 1
    print(result if isinstance(result, Path) else canonical_json(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
