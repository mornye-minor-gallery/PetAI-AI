from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path
from typing import Any

from common import load_jsonl


HONORIFIC_RE = re.compile(
    r"(?:습니다|세요|시겠|십시오|이에요|예요|군요|네요|요)(?:[.!?]|$)"
)
FORMAT_LEAK_RE = re.compile(r"(?:^|\n)\s*(?:[-*#>]\s|\[[^\]]+\])")
AMBIGUOUS_IDS = {f"custom-ms-{index:03d}" for index in range(11, 16)}
FIRST_INTRO_IDS = {f"custom-ms-{index:03d}" for index in range(1, 5)}
EARTH_IDS = {f"custom-ms-{index:03d}" for index in range(6, 11)}


def safe_rate(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0


def f1_score(true_positive: int, false_positive: int, false_negative: int) -> float:
    precision = safe_rate(true_positive, true_positive + false_positive)
    recall = safe_rate(true_positive, true_positive + false_negative)
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def screen_run(generation_dir: Path) -> dict[str, Any]:
    records = load_jsonl(generation_dir / "results.jsonl")
    manifest = json.loads((generation_dir / "run_manifest.json").read_text(encoding="utf-8"))
    ms = [record for record in records if record.get("ability") == "MS"]
    by_id = {record["case_id"]: record for record in ms}
    if set(AMBIGUOUS_IDS | FIRST_INTRO_IDS | EARTH_IDS) - set(by_id):
        raise ValueError(f"{generation_dir}: required MS screen cases are missing")

    compass_predictions = {
        record["case_id"] for record in ms if "나침반" in record["response"]
    }
    true_positive = len(compass_predictions & AMBIGUOUS_IDS)
    false_positive = len(compass_predictions - AMBIGUOUS_IDS)
    false_negative = len(AMBIGUOUS_IDS - compass_predictions)
    honorific_count = sum(bool(HONORIFIC_RE.search(record["response"])) for record in ms)
    format_leak_count = sum(bool(FORMAT_LEAK_RE.search(record["response"])) for record in ms)
    intro_count = sum("엘레나" in by_id[case_id]["response"] for case_id in FIRST_INTRO_IDS)
    earth_question_count = sum("?" in by_id[case_id]["response"] for case_id in EARTH_IDS)
    latencies = [
        float(record["timing"]["elapsed_ms"])
        for record in records
        if isinstance(record.get("timing", {}).get("elapsed_ms"), (int, float))
    ]
    return {
        "generation_dir": str(generation_dir),
        "prompt_id": manifest.get("persona_format"),
        "prompt": manifest.get("prompt"),
        "facet_hint_mode": manifest.get("facet_hint_mode", "none"),
        "record_count": len(records),
        "ms_count": len(ms),
        "honorific_count": honorific_count,
        "format_leak_count": format_leak_count,
        "first_contact_intro": {"passed": intro_count, "total": len(FIRST_INTRO_IDS)},
        "earth_question": {"passed": earth_question_count, "total": len(EARTH_IDS)},
        "compass_routing": {
            "true_positive": true_positive,
            "false_positive": false_positive,
            "false_negative": false_negative,
            "precision": safe_rate(true_positive, true_positive + false_positive),
            "recall": safe_rate(true_positive, len(AMBIGUOUS_IDS)),
            "f1": f1_score(true_positive, false_positive, false_negative),
        },
        "mean_ms_response_characters": statistics.fmean(len(record["response"]) for record in ms),
        "mean_request_latency_ms": statistics.fmean(latencies) if latencies else None,
    }


def render_markdown(rows: list[dict[str, Any]]) -> str:
    lines = [
        "| Prompt | Hint | Honorific | Format leak | Intro | Earth question | Compass P/R/F1 | Mean chars | Mean ms |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |",
    ]
    for row in rows:
        compass = row["compass_routing"]
        latency = row["mean_request_latency_ms"]
        lines.append(
            f"| {row['prompt_id']} | {row['facet_hint_mode']} | {row['honorific_count']} | "
            f"{row['format_leak_count']} | {row['first_contact_intro']['passed']}/4 | "
            f"{row['earth_question']['passed']}/5 | {compass['precision']:.2f}/"
            f"{compass['recall']:.2f}/{compass['f1']:.2f} | "
            f"{row['mean_ms_response_characters']:.1f} | "
            f"{latency:.1f} |" if latency is not None else "N/A |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministically screen MRBench-Custom generations.")
    parser.add_argument("generation_dirs", nargs="+", type=Path)
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    rows = [screen_run(path) for path in args.generation_dirs]
    if args.json_output:
        args.json_output.write_text(
            json.dumps(rows, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(render_markdown(rows), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
