import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from summarize import aggregate, render_markdown  # noqa: E402


class SummarizeTests(unittest.TestCase):
    def test_aggregate_raw_scores(self):
        rows = aggregate(
            [
                {"persona_format": "mrprompt", "memory_condition": "full", "metric": "ME-HLE", "score": 8},
                {"persona_format": "mrprompt", "memory_condition": "full", "metric": "ME-HLE", "score": 10},
            ]
        )
        self.assertEqual(rows[0]["count"], 2)
        self.assertEqual(rows[0]["mean"], 9.0)
        rendered = render_markdown(rows)
        self.assertIn("without human calibration", rendered)
        self.assertIn("9.0000", rendered)


if __name__ == "__main__":
    unittest.main()
