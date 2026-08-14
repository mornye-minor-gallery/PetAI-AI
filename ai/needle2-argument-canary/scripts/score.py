from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

from common import ARTIFACT_ROOT, DATASET_PATH, read_jsonl


def same_value(left, right) -> bool:
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return float(left) == float(right)
    return left == right


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--validations", type=Path, required=True)
    parser.add_argument(
        "--output", type=Path, default=ARTIFACT_ROOT / "summary.json"
    )
    args = parser.parse_args()

    cases = {row["id"]: row for row in read_jsonl(DATASET_PATH)}
    validations = {
        (row["case_id"], row["arm"]): row
        for row in read_jsonl(args.validations)
    }
    scored = []
    for prediction in read_jsonl(args.predictions):
        case = cases[prediction["case_id"]]
        calls = prediction.get("function_calls", [])
        call = calls[0] if len(calls) == 1 else None
        arguments = call.get("arguments", {}) if call else {}
        ready = case["slice"] == "ready"
        runtime_ok = prediction.get("error") is None
        call_exact = (
            bool(call is not None and runtime_ok)
            if ready
            else bool(not calls and runtime_ok)
        )
        tool_exact = bool(call and call.get("name") == case["tool"])
        strict_exact = bool(
            ready and tool_exact and arguments == case["expected"]
        )
        critical_exact = bool(
            ready
            and tool_exact
            and all(
                field in arguments
                and same_value(arguments[field], case["expected"][field])
                for field in case["criticalFields"]
            )
        )
        text_evidence = bool(
            ready
            and tool_exact
            and all(
                isinstance(arguments.get(field), str)
                and all(token in arguments[field] for token in tokens)
                for field, tokens in case["textEvidence"].items()
            )
        )
        validation = validations.get((case["id"], prediction["arm"]), {})
        swift_validation_pass = validation.get("swift_validation_pass", False)
        proposal_pass = (
            critical_exact and text_evidence and swift_validation_pass
            if ready
            else bool(not calls and runtime_ok)
        )
        scored.append(
            {
                **prediction,
                "call_exact": call_exact,
                "tool_exact": tool_exact,
                "strict_argument_exact": strict_exact,
                "critical_argument_exact": critical_exact,
                "text_evidence_pass": text_evidence,
                "proposal_pass": proposal_pass,
                "swift_parse_pass": validation.get("swift_parse_pass", False),
                "swift_validation_pass": swift_validation_pass,
                "validation_error": validation.get("validation_error"),
            }
        )

    grouped = defaultdict(list)
    for row in scored:
        grouped[(row["arm"], row["slice"])].append(row)

    summary = {"arms": {}, "rows": len(scored)}
    metrics = (
        "call_exact",
        "tool_exact",
        "strict_argument_exact",
        "critical_argument_exact",
        "text_evidence_pass",
        "proposal_pass",
        "swift_parse_pass",
        "swift_validation_pass",
    )
    for (arm, slice_name), rows in sorted(grouped.items()):
        arm_summary = summary["arms"].setdefault(arm, {})
        arm_summary[slice_name] = {
            "count": len(rows),
            **{
                metric: {
                    "passed": sum(bool(row[metric]) for row in rows),
                    "rate": round(
                        sum(bool(row[metric]) for row in rows) / len(rows), 6
                    ),
                }
                for metric in metrics
            },
            "latency_ms": {
                "median": round(
                    statistics.median(row["latency_ms"] for row in rows), 3
                ),
                "min": round(min(row["latency_ms"] for row in rows), 3),
                "max": round(max(row["latency_ms"] for row in rows), 3),
            },
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    scored_path = args.output.with_name("scored.jsonl")
    with scored_path.open("w", encoding="utf-8") as handle:
        for row in scored:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
