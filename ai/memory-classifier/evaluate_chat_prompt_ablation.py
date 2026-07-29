from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from hybrid_memory_harness import (
    HeaderParseKind,
    MemoryDecisionParser,
    MemoryHeaderFormat,
)
from litert_chat_client import LiteRTChatClient


class ChatPromptAblationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_cases(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        row = json.loads(line)
        required = {"id", "category", "criterion", "utterance"}
        if not required.issubset(row):
            missing = sorted(required - set(row))
            raise ChatPromptAblationError(
                f"{path}:{line_number} is missing {missing}."
            )
        if row["id"] in seen_ids:
            raise ChatPromptAblationError(
                f"Duplicate case id: {row['id']}"
            )
        seen_ids.add(row["id"])
        rows.append({key: str(row[key]) for key in required})
    if not rows:
        raise ChatPromptAblationError("No cases were loaded.")
    return rows


def generate(
    client: LiteRTChatClient,
    utterance: str,
) -> tuple[str, float]:
    started = time.perf_counter()
    text = "".join(client.stream_primary(utterance)).strip()
    elapsed = time.perf_counter() - started
    if not text:
        raise ChatPromptAblationError("Model returned an empty response.")
    return text, elapsed


def visible_memory_reply(raw_text: str) -> tuple[str, str]:
    parser = MemoryDecisionParser(
        header_format=MemoryHeaderFormat.WRAPPED_AXES
    )
    parsed = parser.parse(raw_text, final=True)
    if parsed.kind is not HeaderParseKind.RECOGNIZED:
        raise ChatPromptAblationError(
            f"Memory response did not contain a valid header: {raw_text!r}"
        )
    visible = raw_text[parsed.consumed_characters :].strip()
    if not visible:
        raise ChatPromptAblationError(
            "Memory response did not contain a visible reply."
        )
    decision = parsed.decision.value if parsed.decision else ""
    return decision, visible


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    index = (len(ordered) - 1) * quantile
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = index - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def latency_summary(values: list[float]) -> dict[str, float]:
    return {
        "mean": sum(values) / len(values),
        "p50": percentile(values, 0.5),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def run(arguments: argparse.Namespace) -> None:
    output_dir = arguments.output_dir.resolve()
    if output_dir.exists():
        raise ChatPromptAblationError(
            f"Output directory already exists: {output_dir}"
        )

    memory_prompt_path = arguments.memory_prompt.resolve()
    chat_prompt_path = arguments.chat_prompt.resolve()
    cases_path = arguments.cases.resolve()
    model_artifact_path = arguments.model_artifact.resolve()
    cases = load_cases(cases_path)

    memory_prompt = memory_prompt_path.read_text(
        encoding="utf-8"
    ).strip()
    chat_prompt = chat_prompt_path.read_text(
        encoding="utf-8"
    ).strip()
    if not memory_prompt or not chat_prompt:
        raise ChatPromptAblationError("A system prompt is empty.")

    common_client = {
        "base_url": arguments.base_url,
        "model": arguments.model,
        "temperature": arguments.temperature,
        "top_p": arguments.top_p,
        "max_tokens": arguments.max_tokens,
        "timeout_seconds": arguments.timeout_seconds,
    }
    memory_client = LiteRTChatClient(
        system_prompt=memory_prompt,
        **common_client,
    )
    chat_client = LiteRTChatClient(
        system_prompt=chat_prompt,
        **common_client,
    )

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}.",
            dir=output_dir.parent,
        )
    )
    results_path = temporary_dir / "results.jsonl"
    manifest_path = temporary_dir / "evaluation_manifest.json"

    generate(memory_client, "오늘은 짧게 이야기해 보자.")
    generate(chat_client, "오늘은 짧게 이야기해 보자.")

    results: list[dict[str, Any]] = []
    memory_latencies: list[float] = []
    chat_latencies: list[float] = []
    started_at = datetime.now(UTC)
    try:
        with results_path.open(
            "w",
            encoding="utf-8",
            newline="\n",
        ) as handle:
            for index, case in enumerate(cases):
                conditions = (
                    (
                        ("memory", memory_client),
                        ("chat_only", chat_client),
                    )
                    if index % 2 == 0
                    else (
                        ("chat_only", chat_client),
                        ("memory", memory_client),
                    )
                )
                generated: dict[str, tuple[str, float]] = {}
                for name, client in conditions:
                    generated[name] = generate(
                        client,
                        case["utterance"],
                    )

                memory_raw, memory_seconds = generated["memory"]
                decision, memory_visible = visible_memory_reply(memory_raw)
                chat_visible, chat_seconds = generated["chat_only"]
                memory_latencies.append(memory_seconds)
                chat_latencies.append(chat_seconds)
                row = {
                    **case,
                    "generation_order": [
                        name for name, _ in conditions
                    ],
                    "memory": {
                        "decision": decision,
                        "raw_text": memory_raw,
                        "visible_text": memory_visible,
                        "seconds": memory_seconds,
                    },
                    "chat_only": {
                        "visible_text": chat_visible,
                        "seconds": chat_seconds,
                    },
                }
                results.append(row)
                handle.write(
                    json.dumps(row, ensure_ascii=False) + "\n"
                )

        manifest = {
            "phase": "chat_prompt_ablation_complete",
            "created_at": datetime.now(UTC).isoformat(),
            "started_at": started_at.isoformat(),
            "configuration": {
                "model": arguments.model,
                "runtime_version": arguments.runtime_version,
                "base_url": arguments.base_url,
                "temperature": arguments.temperature,
                "top_p": arguments.top_p,
                "max_tokens": arguments.max_tokens,
                "timeout_seconds": arguments.timeout_seconds,
                "repeats": 1,
                "counterbalanced_order": True,
                "quality_scoring": (
                    "manual binary case-specific criterion"
                ),
            },
            "provenance": {
                "cases": {
                    "path": str(cases_path),
                    "sha256": sha256_file(cases_path),
                    "records": len(cases),
                },
                "memory_prompt": {
                    "path": str(memory_prompt_path),
                    "sha256": sha256_file(memory_prompt_path),
                },
                "chat_prompt": {
                    "path": str(chat_prompt_path),
                    "sha256": sha256_file(chat_prompt_path),
                },
                "model_artifact": {
                    "path": str(model_artifact_path),
                    "sha256": sha256_file(model_artifact_path),
                },
                "results": {
                    "sha256": sha256_file(results_path),
                },
            },
            "runtime": {
                "python": platform.python_version(),
                "platform": platform.platform(),
                "machine": platform.machine(),
            },
            "metrics": {
                "records_per_condition": len(results),
                "latency_seconds": {
                    "memory": latency_summary(memory_latencies),
                    "chat_only": latency_summary(chat_latencies),
                },
            },
        }
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        temporary_dir.rename(output_dir)
    except BaseException:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--memory-prompt", required=True, type=Path)
    parser.add_argument("--chat-prompt", required=True, type=Path)
    parser.add_argument("--model-artifact", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:9379/v1",
    )
    parser.add_argument("--model", default="gemma4-e2b,gpu")
    parser.add_argument("--runtime-version", default="0.13.1")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top-p", type=float, default=1.0)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=120.0,
    )
    return parser


if __name__ == "__main__":
    run(build_parser().parse_args())
