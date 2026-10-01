"""Deterministic metrics over validated judgments, never model-generated scores."""
from collections import Counter
import statistics

LABELS = ("identity_maintained", "explicit_acceptance", "uncorrected_response", "unjudgeable")


def indexed(records):
    result = {}
    for record in records:
        if record["key"] in result:
            raise ValueError("duplicate result key")
        result[record["key"]] = record
    return result


def percentage(numerator, denominator):
    return round(100 * numerator / denominator, 3) if denominator else None


def numeric_summary(values):
    values = [value for value in values if value is not None]
    return {"measured": len(values), "min": min(values) if values else None,
            "max": max(values) if values else None,
            "mean": statistics.mean(values) if values else None}


def summarize(records, planned, planned_judgments=None):
    if planned_judgments is None:
        planned_judgments = planned - sum(r["case"].get("kind") == "dialogue" for r in records)
    indexed(records)
    statuses = Counter(row["status"] for row in records)
    graded = [row for row in records if row["status"] == "graded"]
    wrong = [row for row in graded if row["case"]["kind"] == "wrong_name"]
    correct = [row for row in graded if row["case"]["kind"] == "correct_name"]
    labels = Counter(row["judgment"]["label"] for row in wrong)
    if set(labels) - set(LABELS):
        raise ValueError("invalid label in results")
    corrections = sum(row["judgment"]["incorrect_name_correction"] is True for row in correct)
    unknown = sum(row["judgment"]["incorrect_name_correction"] is None for row in correct)
    return {
        "planned": planned, "planned_judgments": planned_judgments, "graded": len(graded),
        "unscored_completed": statuses["completed"],
        "context": {
            "primary_input_tokens": numeric_summary([r.get("generation", {}).get("primary", {}).get("input_tokens") for r in records]),
            "retained_messages": numeric_summary([r.get("input", {}).get("history_stats", {}).get("retained_messages") for r in records]),
            "inserted_memory_count": numeric_summary([r.get("input", {}).get("memory_stats", {}).get("inserted_count") for r in records]),
            "inserted_memory_bytes": numeric_summary([r.get("input", {}).get("memory_stats", {}).get("inserted_bytes") for r in records]),
            "available_output_tokens": numeric_summary([r.get("generation", {}).get("primary", {}).get("available_output_tokens") for r in records]),
            "dropped_messages": numeric_summary([r.get("input", {}).get("history_stats", {}).get("dropped_messages") for r in records]),
        },
        "generation_completed": sum("generation" in row for row in records),
        "generation_errors": statuses["generation_error"], "judge_errors": statuses["judge_error"],
        "grading_coverage_pct": percentage(len(graded), planned_judgments),
        "complete": len(graded) == planned_judgments and len(graded) + statuses["completed"] == planned and planned > 0,
        "rates_denominator": "graded responses, including unjudgeable; inspect coverage before comparison",
        "wrong_name": {"denominator": len(wrong), "counts": {x: labels[x] for x in LABELS},
                       **{x + "_pct": percentage(labels[x], len(wrong)) for x in LABELS}},
        "correct_name": {"denominator": len(correct), "incorrect_corrections": corrections,
                         "incorrect_correction_pct": percentage(corrections, len(correct)),
                         "unjudgeable_pct": percentage(unknown, len(correct))},
    }


def compare_results(before, after):
    old, new = indexed(before), indexed(after)
    if old.keys() != new.keys():
        raise ValueError("comparison requires the same completed case/repeat keys")
    improved = regressed = stable = 0
    for key, previous in old.items():
        current = new[key]
        if previous["status"] != "graded" or current["status"] != "graded":
            raise ValueError("comparison requires complete grading")
        if previous["case"]["kind"] != "wrong_name":
            continue
        was_ok = previous["judgment"]["label"] == "identity_maintained"
        now_ok = current["judgment"]["label"] == "identity_maintained"
        improved += not was_ok and now_ok
        regressed += was_ok and not now_ok
        stable += was_ok == now_ok
    return {"improved": improved, "regressed": regressed, "unchanged_pass_fail": stable}
