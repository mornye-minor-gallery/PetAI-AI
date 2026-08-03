#!/usr/bin/env python3
"""Run a small, strict profile-memory key-value extraction smoke eval."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence


RUNNER_VERSION = "0.1.0"
ALLOWED_KEYS = frozenset(
    {
        "profile.nickname",
        "profile.school",
        "profile.major",
        "profile.sibling_count",
        "preference.food",
        "preference.drink",
        "preference.hobby",
        "preference.drama",
    }
)


class EvaluationError(RuntimeError):
    """Raised when the smoke-evaluation contract cannot be satisfied."""


@dataclass(frozen=True)
class ParsedPrediction:
    status: str
    value: dict[str, str] | None


@dataclass(frozen=True)
class GenerationResult:
    text: str
    channels: dict[str, str]
    elapsed_seconds: float
    first_token_seconds: float | None


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_value(value: str) -> str:
    return " ".join(value.strip().split()).casefold()


def parse_prediction(text: str) -> ParsedPrediction:
    stripped = text.strip()
    if stripped == "null":
        return ParsedPrediction(status="canonical_null", value=None)
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError:
        return ParsedPrediction(status="invalid_json", value=None)
    if not isinstance(payload, dict):
        return ParsedPrediction(status="not_object", value=None)
    if len(payload) != 1:
        return ParsedPrediction(status="invalid_fields", value=None)
    key, value = next(iter(payload.items()))
    if key not in ALLOWED_KEYS:
        return ParsedPrediction(status="unknown_key", value=None)
    if not isinstance(value, str) or not value.strip():
        return ParsedPrediction(status="invalid_value", value=None)
    return ParsedPrediction(
        status="canonical_object",
        value={"key": key, "value": value.strip()},
    )


def load_dataset(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise EvaluationError(
                    f"{path.name}:{line_number}: invalid JSON"
                ) from error
            record_id = row.get("id")
            utterance = row.get("utterance")
            expected = row.get("expected")
            if not isinstance(record_id, str) or not record_id:
                raise EvaluationError(
                    f"{path.name}:{line_number}: invalid id"
                )
            if record_id in seen:
                raise EvaluationError(
                    f"{path.name}:{line_number}: duplicate id {record_id}"
                )
            if not isinstance(utterance, str) or not utterance.strip():
                raise EvaluationError(
                    f"{path.name}:{line_number}: invalid utterance"
                )
            if expected is not None:
                if not isinstance(expected, dict) or set(expected) != {
                    "key",
                    "value",
                }:
                    raise EvaluationError(
                        f"{path.name}:{line_number}: invalid expected object"
                    )
                if expected["key"] not in ALLOWED_KEYS:
                    raise EvaluationError(
                        f"{path.name}:{line_number}: unknown expected key"
                    )
                if not isinstance(expected["value"], str) or not expected[
                    "value"
                ].strip():
                    raise EvaluationError(
                        f"{path.name}:{line_number}: invalid expected value"
                    )
            seen.add(record_id)
            rows.append(row)
    if len(rows) != 24:
        raise EvaluationError(f"expected 24 smoke rows, found {len(rows)}")
    positive = sum(row["expected"] is not None for row in rows)
    if positive != 16:
        raise EvaluationError(f"expected 16 positive rows, found {positive}")
    return rows


class DirectLiteRTRuntime:
    """Load one LiteRT-LM engine and use a fresh conversation per row."""

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
            raise EvaluationError(
                "Run with the Python environment bundled with litert-lm."
            ) from error
        backend_value = {
            "cpu": litert_lm.Backend.CPU,
            "gpu": litert_lm.Backend.GPU,
        }.get(backend)
        if backend_value is None:
            raise EvaluationError(f"unsupported backend: {backend}")
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

    def generate(self, *, system_prompt: str, utterance: str) -> GenerationResult:
        chunks: list[str] = []
        channels: dict[str, str] = {}
        first_token: float | None = None
        started = time.perf_counter()
        with self._engine.create_conversation(
            messages=[{"role": "system", "content": system_prompt}],
            extra_context={"enable_thinking": False},
            filter_channel_content_from_kv_cache=True,
            sampler_config=self._sampler,
        ) as conversation:
            for chunk in conversation.send_message_async(utterance):
                content = chunk.get("content", [])
                channel_content = chunk.get("channels", {})
                if first_token is None and (content or channel_content):
                    first_token = time.perf_counter() - started
                for item in content:
                    if item.get("type") == "text" and item.get("text"):
                        chunks.append(item["text"])
                for name, channel_text in channel_content.items():
                    channels[name] = channels.get(name, "") + channel_text
        return GenerationResult(
            text="".join(chunks),
            channels=channels,
            elapsed_seconds=time.perf_counter() - started,
            first_token_seconds=first_token,
        )


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def describe(values: Sequence[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "mean": None, "p50": None, "p95": None}
    return {
        "count": len(values),
        "mean": statistics.fmean(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
    }


def score_row(
    source: dict[str, Any],
    parsed: ParsedPrediction,
) -> dict[str, Any]:
    expected = source["expected"]
    prediction = parsed.value
    protocol_valid = parsed.status in {
        "canonical_null",
        "canonical_object",
    }
    expected_null = expected is None
    predicted_null = protocol_valid and prediction is None
    key_match = bool(
        expected is not None
        and prediction is not None
        and expected["key"] == prediction["key"]
    )
    value_match = bool(
        key_match
        and normalize_value(expected["value"])
        == normalize_value(prediction["value"])
    )
    exact_match = (
        expected_null and predicted_null
    ) or (
        not expected_null and key_match and value_match
    )
    return {
        "protocol_valid": protocol_valid,
        "expected_null": expected_null,
        "predicted_null": predicted_null,
        "key_match": key_match,
        "value_match": value_match,
        "exact_match": exact_match,
    }


def summarize(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    positives = [row for row in rows if not row["score"]["expected_null"]]
    negatives = [row for row in rows if row["score"]["expected_null"]]
    key_matches = sum(row["score"]["key_match"] for row in positives)
    return {
        "records": len(rows),
        "exact_matches": sum(row["score"]["exact_match"] for row in rows),
        "exact_match_rate": sum(
            row["score"]["exact_match"] for row in rows
        )
        / len(rows),
        "protocol_valid_rate": sum(
            row["score"]["protocol_valid"] for row in rows
        )
        / len(rows),
        "positive": {
            "records": len(positives),
            "key_accuracy": key_matches / len(positives),
            "value_accuracy_given_correct_key": (
                sum(row["score"]["value_match"] for row in positives)
                / key_matches
                if key_matches
                else 0.0
            ),
        },
        "null": {
            "records": len(negatives),
            "accuracy": sum(
                row["score"]["predicted_null"] for row in negatives
            )
            / len(negatives),
            "false_positive_count": sum(
                not row["score"]["predicted_null"] for row in negatives
            ),
        },
        "parse_status": {
            status: sum(row["parse_status"] == status for row in rows)
            for status in sorted({row["parse_status"] for row in rows})
        },
        "latency_seconds": {
            "end_to_end": describe(
                [row["elapsed_seconds"] for row in rows]
            ),
            "first_token": describe(
                [
                    row["first_token_seconds"]
                    for row in rows
                    if row["first_token_seconds"] is not None
                ]
            ),
        },
    }


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(canonical_json(row) + "\n")


def run(arguments: argparse.Namespace) -> Path:
    dataset_path = arguments.dataset.expanduser().resolve()
    prompt_path = arguments.prompt.expanduser().resolve()
    model_path = arguments.model_artifact.expanduser().resolve()
    output_dir = arguments.output_dir.expanduser().resolve()
    for path, label in (
        (dataset_path, "dataset"),
        (prompt_path, "prompt"),
        (model_path, "model artifact"),
    ):
        if not path.is_file():
            raise EvaluationError(f"{label} was not found: {path}")
    if output_dir.exists():
        raise EvaluationError(f"output directory already exists: {output_dir}")

    source_rows = load_dataset(dataset_path)
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent)
    )
    runtime = DirectLiteRTRuntime(
        model_path=model_path,
        backend=arguments.backend,
        max_num_tokens=arguments.max_num_tokens,
        temperature=arguments.temperature,
        top_p=arguments.top_p,
    )
    rows: list[dict[str, Any]] = []
    started = datetime.now(timezone.utc)
    try:
        for index, source in enumerate(source_rows, start=1):
            generation = runtime.generate(
                system_prompt=system_prompt,
                utterance=source["utterance"],
            )
            parsed = parse_prediction(generation.text)
            score = score_row(source, parsed)
            row = {
                "id": source["id"],
                "utterance": source["utterance"],
                "expected": source["expected"],
                "raw_output": generation.text,
                "prediction": parsed.value,
                "parse_status": parsed.status,
                "score": score,
                "elapsed_seconds": generation.elapsed_seconds,
                "first_token_seconds": generation.first_token_seconds,
                "channel_names": sorted(generation.channels),
            }
            rows.append(row)
            print(
                f"[{index:02d}/{len(source_rows)}] {source['id']} "
                f"{'PASS' if score['exact_match'] else 'FAIL'} "
                f"{generation.elapsed_seconds:.3f}s",
                flush=True,
            )
    finally:
        runtime.close()

    summary = summarize(rows)
    manifest = {
        "runner_version": RUNNER_VERSION,
        "started_at": started.isoformat(),
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "backend": arguments.backend,
        "thinking_enabled": False,
        "temperature": arguments.temperature,
        "top_p": arguments.top_p,
        "max_num_tokens": arguments.max_num_tokens,
        "dataset": str(dataset_path),
        "dataset_sha256": sha256_file(dataset_path),
        "prompt": str(prompt_path),
        "prompt_sha256": sha256_file(prompt_path),
        "model_artifact": str(model_path),
        "model_sha256": sha256_file(model_path),
        "scope": "24-case exploratory smoke; not deployment performance",
    }
    write_jsonl(temporary / "results.jsonl", rows)
    (temporary / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (temporary / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.rename(output_dir)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return output_dir


def validate(arguments: argparse.Namespace) -> None:
    rows = load_dataset(arguments.dataset.expanduser().resolve())
    prompt = arguments.prompt.expanduser().resolve()
    if not prompt.is_file() or not prompt.read_text(encoding="utf-8").strip():
        raise EvaluationError("prompt is missing or empty")
    print(f"PASS: {len(rows)} rows, {len(ALLOWED_KEYS)} allowed keys")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    defaults = {
        "dataset": Path(__file__).parent / "data" / "smoke_v0.jsonl",
        "prompt": Path(__file__).parent / "prompts" / "profile_kv_v0.txt",
    }
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--dataset", type=Path, default=defaults["dataset"])
    validate_parser.add_argument("--prompt", type=Path, default=defaults["prompt"])
    validate_parser.set_defaults(handler=validate)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--dataset", type=Path, default=defaults["dataset"])
    run_parser.add_argument("--prompt", type=Path, default=defaults["prompt"])
    run_parser.add_argument("--model-artifact", type=Path, required=True)
    run_parser.add_argument("--output-dir", type=Path, required=True)
    run_parser.add_argument("--backend", choices=["cpu", "gpu"], default="cpu")
    run_parser.add_argument("--max-num-tokens", type=int, default=8192)
    run_parser.add_argument("--temperature", type=float, default=0.0)
    run_parser.add_argument("--top-p", type=float, default=1.0)
    run_parser.set_defaults(handler=run)
    return parser


def main() -> None:
    parser = build_parser()
    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()
