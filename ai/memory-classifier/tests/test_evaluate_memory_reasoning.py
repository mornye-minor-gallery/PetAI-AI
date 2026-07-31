from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import evaluate_memory_reasoning as evaluator


def result_row(
    *,
    record_id: str,
    expected: str,
    predicted: str | None,
    exact: bool,
) -> dict:
    return {
        "record_id": record_id,
        "expected": expected,
        "predicted": predicted,
        "exact_match": exact,
        "primary": {"syntax": "canonical"},
        "visible_text": "대화",
        "retry_attempted": False,
        "control_leak": False,
        "elapsed_seconds": 1.0,
        "first_any_seconds": 0.2,
        "first_normal_seconds": 0.5,
        "tokens": {
            "utterance": 3,
            "normal": 4,
            "reasoning": 5,
            "conversation_total": 12,
        },
    }


class HeaderDecodingTests(unittest.TestCase):
    def test_reasoning_never_enters_header_gate(self) -> None:
        decoded = evaluator.decode_chunks(
            ["save(", "P=1", ",E=0", ")\n답", "변"]
        )
        self.assertEqual(decoded["decision"], "P")
        self.assertEqual(decoded["syntax"], "canonical")
        self.assertEqual(decoded["visible_text"], "답변")


class SummaryTests(unittest.TestCase):
    def test_summary_reports_exact_and_axis_metrics(self) -> None:
        rows = [
            result_row(
                record_id="n", expected="N", predicted="N", exact=True
            ),
            result_row(
                record_id="p", expected="P", predicted="B", exact=False
            ),
            result_row(
                record_id="e", expected="E", predicted="E", exact=True
            ),
            result_row(
                record_id="b", expected="B", predicted="B", exact=True
            ),
        ]
        summary = evaluator.summarize(rows)
        self.assertEqual(summary["label_exact_match"], 0.75)
        self.assertEqual(
            summary["by_expected_label"]["P"]["predictions"],
            {"B": 1},
        )
        self.assertEqual(summary["axes"]["event"]["false_positive"], 1)


class PairedComparisonTests(unittest.TestCase):
    def test_compare_counts_improvement_and_regression(self) -> None:
        baseline = [
            {
                "record_id": "improved",
                "hybrid_label_correct": False,
                "outcome": {"decision": "B"},
            },
            {
                "record_id": "regressed",
                "hybrid_label_correct": True,
                "outcome": {"decision": "P"},
            },
        ]
        candidate = [
            result_row(
                record_id="improved",
                expected="P",
                predicted="P",
                exact=True,
            ),
            result_row(
                record_id="regressed",
                expected="P",
                predicted="B",
                exact=False,
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline_path = root / "baseline.jsonl"
            candidate_path = root / "candidate.jsonl"
            output_path = root / "comparison.json"
            baseline_path.write_text(
                "\n".join(json.dumps(row) for row in baseline) + "\n"
            )
            candidate_path.write_text(
                "\n".join(json.dumps(row) for row in candidate) + "\n"
            )
            comparison = evaluator.compare_results(
                baseline_path,
                candidate_path,
                output_path,
            )
            self.assertEqual(comparison["improved"], 1)
            self.assertEqual(comparison["regressed"], 1)
            self.assertEqual(comparison["changed_predictions"], 2)
            self.assertTrue(output_path.is_file())


if __name__ == "__main__":
    unittest.main()
