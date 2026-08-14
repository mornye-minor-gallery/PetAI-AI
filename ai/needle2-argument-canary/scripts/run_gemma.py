from __future__ import annotations

import argparse
import json
import time
from importlib.metadata import version
from pathlib import Path
from typing import Any

import litert_lm

from common import (
    ARTIFACT_ROOT,
    COMMON_SYSTEM_FACTS,
    DATASET_PATH,
    base_schema,
    enriched_schema,
    openai_tool,
    production_prompt,
    read_jsonl,
    sha256,
    write_jsonl,
)


class SchemaTool(litert_lm.Tool):
    def __init__(self, schema: dict[str, Any]):
        self.schema = schema

    def get_tool_description(self) -> dict[str, Any]:
        return openai_tool(self.schema)

    def execute(self, param: dict[str, Any]) -> dict[str, Any]:
        return param


def normalize_calls(response: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    for call in response.get("tool_calls", []):
        function = call.get("function", {})
        result.append(
            {
                "name": function.get("name"),
                "arguments": function.get("arguments", {}),
            }
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument(
        "--output",
        type=Path,
        default=ARTIFACT_ROOT / "gemma.predictions.jsonl",
    )
    parser.add_argument("--cache-dir", type=Path, default=ARTIFACT_ROOT / "gemma-cache")
    args = parser.parse_args()

    args.cache_dir.mkdir(parents=True, exist_ok=True)
    engine = litert_lm.Engine(
        str(args.model),
        backend=litert_lm.Backend.CPU(),
        cache_dir=str(args.cache_dir),
        enable_speculative_decoding=False,
    )
    rows = []
    arms = ("gemma_current", "gemma_schema_only", "gemma_enriched")
    try:
        for arm in arms:
            for case in read_jsonl(DATASET_PATH):
                if arm == "gemma_current":
                    schema = base_schema(case["tool"])
                    system_message = production_prompt(case["tool"])
                elif arm == "gemma_schema_only":
                    schema = base_schema(case["tool"])
                    system_message = COMMON_SYSTEM_FACTS
                else:
                    schema = enriched_schema(case["tool"])
                    system_message = COMMON_SYSTEM_FACTS

                conversation = engine.create_conversation(
                    system_message=system_message,
                    tools=[SchemaTool(schema)],
                    automatic_tool_calling=False,
                    extra_context={"enable_thinking": False},
                    filter_channel_content_from_kv_cache=True,
                    sampler_config=litert_lm.SamplerConfig(
                        top_k=40,
                        top_p=1.0,
                        temperature=0.0,
                    ),
                    max_output_tokens=4_096,
                )
                started = time.perf_counter()
                try:
                    response = conversation.send_message(case["user"])
                    rows.append(
                        {
                            "case_id": case["id"],
                            "slice": case["slice"],
                            "selected_tool": case["tool"],
                            "model": "gemma-4-E2B-it",
                            "arm": arm,
                            "latency_ms": round(
                                (time.perf_counter() - started) * 1000, 3
                            ),
                            "function_calls": normalize_calls(response),
                            "raw": response,
                            "error": None,
                        }
                    )
                except Exception as error:  # preserve every model/runtime failure
                    rows.append(
                        {
                            "case_id": case["id"],
                            "slice": case["slice"],
                            "selected_tool": case["tool"],
                            "model": "gemma-4-E2B-it",
                            "arm": arm,
                            "latency_ms": round(
                                (time.perf_counter() - started) * 1000, 3
                            ),
                            "function_calls": [],
                            "raw": None,
                            "error": repr(error),
                        }
                    )
                finally:
                    conversation.close()
    finally:
        engine.close()

    write_jsonl(args.output, rows)
    manifest = {
        "runtime": f"litert-lm=={version('litert-lm')}",
        "model_path": str(args.model),
        "model_sha256": sha256(args.model),
        "dataset_sha256": sha256(DATASET_PATH),
        "arms": list(arms),
        "backend": "cpu",
        "speculative_decoding": False,
        "sampling": {"temperature": 0.0, "top_k": 40, "top_p": 1.0},
        "max_output_tokens": 4_096,
        "rows": len(rows),
    }
    args.output.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
