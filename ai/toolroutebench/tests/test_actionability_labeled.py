from __future__ import annotations

import unittest
from collections import Counter

from toolroutebench.actionability_labeled import build_labeled_actionability_splits


def _row(case_id: str, utterance: str, *, call: bool, tool_id: str | None = None) -> dict:
    return {
        "case_id": case_id,
        "utterance": utterance,
        "call": call,
        "training_label": "CALL" if call else "NO_CALL",
        "agreed_tool_ids": [tool_id] if tool_id else [],
        "labeling_partition": "candidate",
        "source": "3i4k",
        "source_label": 3 if call else 1,
        "source_label_name": "command" if call else "statement",
    }


class LabeledActionabilityTests(unittest.TestCase):
    def test_split_is_balanced_deduplicated_and_preserves_rare_tool_test(self) -> None:
        rows = [
            _row(f"call-{index}", f"일정 요청 {index}", call=True, tool_id="calendar")
            for index in range(18)
        ]
        rows.extend(
            _row(f"timer-{index}", f"타이머 요청 {index}", call=True, tool_id="timer")
            for index in range(2)
        )
        rows.extend(
            _row(f"normal-{index}", f"일반 대화 {index}", call=False)
            for index in range(20)
        )
        rows.append(_row("call-duplicate", "일정요청0", call=True, tool_id="calendar"))
        rows.append(_row("normal-duplicate", "일반대화0", call=False))

        first, exclusions = build_labeled_actionability_splits(rows=rows, seed=11)
        second, _ = build_labeled_actionability_splits(rows=rows, seed=11)

        self.assertEqual(first, second)
        self.assertEqual(len(first), 40)
        self.assertEqual(len(exclusions), 2)
        counts = Counter((row["split"], row["training_label"]) for row in first)
        self.assertEqual(counts[("train", "CALL")], 16)
        self.assertEqual(counts[("train", "NO_CALL")], 16)
        self.assertEqual(counts[("validation", "CALL")], 2)
        self.assertEqual(counts[("validation", "NO_CALL")], 2)
        self.assertEqual(counts[("test", "CALL")], 2)
        self.assertEqual(counts[("test", "NO_CALL")], 2)
        timer_splits = {
            row["split"] for row in first if row["agreed_tool_ids"] == ["timer"]
        }
        self.assertEqual(timer_splits, {"train", "test"})


if __name__ == "__main__":
    unittest.main()
