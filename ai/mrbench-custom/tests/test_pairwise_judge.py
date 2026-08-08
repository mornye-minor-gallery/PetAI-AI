from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from run_pairwise_judge import parse_pairwise_json, presentation_order


class PairwiseJudgeTests(unittest.TestCase):
    def test_parse_pairwise_json(self) -> None:
        self.assertEqual(
            parse_pairwise_json('{"winner":"B","rationale":"더 자연스럽다."}'),
            ("B", "더 자연스럽다."),
        )

    def test_presentation_order_is_deterministic_and_balanced(self) -> None:
        first = [presentation_order(f"case-{index}", 42) for index in range(40)]
        second = [presentation_order(f"case-{index}", 42) for index in range(40)]
        self.assertEqual(first, second)
        self.assertIn(("primary", "challenger"), first)
        self.assertIn(("challenger", "primary"), first)

    def test_presentation_order_flips_between_repetitions(self) -> None:
        first = presentation_order("case-1", 42, 0)
        second = presentation_order("case-1", 42, 1)
        self.assertEqual(first, (second[1], second[0]))


if __name__ == "__main__":
    unittest.main()
