from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import needle

from common import (
    ARTIFACT_ROOT,
    DATASET_PATH,
    NEEDLE_SYSTEM_FACTS,
    base_schema,
    enriched_schema,
    read_jsonl,
    sha256,
    write_jsonl,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=ARTIFACT_ROOT / "needle.predictions.jsonl",
    )
    args = parser.parse_args()

    dataset = read_jsonl(DATASET_PATH)
    rows = []
    arms = ("needle_schema_only", "needle_enriched")
    for arm in arms:
        for tool_name in sorted({case["tool"] for case in dataset}):
            schema = (
                base_schema(tool_name)
                if arm == "needle_schema_only"
                else enriched_schema(tool_name)
            )
            # Needle's native API owns one global session. Do not retain or
            # interleave agents with different toolsets.
            agent = needle.Needle(
                tools=[schema],
                system=NEEDLE_SYSTEM_FACTS,
            )
            for case in [row for row in dataset if row["tool"] == tool_name]:
                agent.reset()
                started = time.perf_counter()
                try:
                    response = agent.complete(case["user"], max_new_tokens=256)
                    rows.append(
                        {
                            "case_id": case["id"],
                            "slice": case["slice"],
                            "selected_tool": case["tool"],
                            "model": "needle2",
                            "arm": arm,
                            "latency_ms": round(
                                (time.perf_counter() - started) * 1000, 3
                            ),
                            "function_calls": response.get("function_calls", []),
                            "confidence": response.get("confidence"),
                            "raw": response,
                            "error": response.get("error"),
                        }
                    )
                except Exception as error:  # preserve every model/runtime failure
                    rows.append(
                        {
                            "case_id": case["id"],
                            "slice": case["slice"],
                            "selected_tool": case["tool"],
                            "model": "needle2",
                            "arm": arm,
                            "latency_ms": round(
                                (time.perf_counter() - started) * 1000, 3
                            ),
                            "function_calls": [],
                            "confidence": None,
                            "raw": None,
                            "error": repr(error),
                        }
                    )

    write_jsonl(args.output, rows)
    engine_path = (
        Path.home() / ".cache" / "cactus-needle" / "2.0.1" / "libneedle.dylib"
    )
    manifest = {
        "package": "cactus-needle==2.0.2",
        "engine": "2.0.1",
        "engine_sha256": sha256(engine_path) if engine_path.exists() else None,
        "model": "Cactus-Compute/needle2",
        "dataset_sha256": sha256(DATASET_PATH),
        "arms": list(arms),
        "rows": len(rows),
        "max_new_tokens": 256,
    }
    args.output.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
