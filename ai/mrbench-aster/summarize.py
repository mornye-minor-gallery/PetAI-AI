from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from common import create_output_dir, load_jsonl, sha256_file, utc_now, write_json


def aggregate(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for record in records:
        score = record.get("score")
        if not isinstance(score, (int, float)) or isinstance(score, bool) or not 1 <= score <= 10:
            raise ValueError("all judge records require scores from 1 to 10")
        key = (
            str(record.get("persona_format")),
            str(record.get("memory_condition")),
            str(record.get("metric")),
        )
        grouped[key].append(float(score))
    rows: list[dict[str, Any]] = []
    for (persona_format, memory_condition, metric), scores in sorted(grouped.items()):
        rows.append(
            {
                "persona_format": persona_format,
                "memory_condition": memory_condition,
                "metric": metric,
                "count": len(scores),
                "mean": round(statistics.fmean(scores), 4),
                "min": min(scores),
                "max": max(scores),
                "population_stdev": round(statistics.pstdev(scores), 4),
            }
        )
    return rows


def render_markdown(rows: list[dict[str, Any]]) -> str:
    lines = [
        "# MRBench-Aster AutoJudge Summary",
        "",
        "> These are raw automatic-judge scores without human calibration.",
        "> They are not directly comparable to human-calibrated MRBench scores.",
        "",
        "| Persona | Condition | Metric | N | Mean | Min | Max | Stddev |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| {row['persona_format']} | {row['memory_condition']} | {row['metric']} | "
            f"{row['count']} | {row['mean']:.4f} | {row['min']:.1f} | {row['max']:.1f} | "
            f"{row['population_stdev']:.4f} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate MRBench-Aster raw judge scores.")
    parser.add_argument("--input", type=Path, action="append", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    records: list[dict[str, Any]] = []
    for path in args.input:
        records.extend(load_jsonl(path))
    if not records:
        raise ValueError("no judge records found")
    rows = aggregate(records)
    create_output_dir(args.output_dir)
    summary = {
        "schema_version": "mrbench-aster-summary-v0",
        "generated_at": utc_now(),
        "score_label": "MRBench-Aster AutoJudge Raw Score",
        "human_calibration": False,
        "input_files": [
            {"path": str(path), "sha256": sha256_file(path)} for path in args.input
        ],
        "rows": rows,
    }
    write_json(args.output_dir / "summary.json", summary)
    (args.output_dir / "summary.md").write_text(render_markdown(rows), encoding="utf-8")
    print(json.dumps({"records": len(records), "groups": len(rows), "output_dir": str(args.output_dir)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
