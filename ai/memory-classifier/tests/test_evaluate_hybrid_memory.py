from __future__ import annotations

import sys
import unittest
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from evaluate_hybrid_memory import (  # noqa: E402
    HybridEvaluationError,
    build_parser,
    select_balanced_rows,
)


class BalancedSelectionTests(unittest.TestCase):
    def build_rows(self) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for preference, event in (
            (False, False),
            (True, False),
            (False, True),
            (True, True),
        ):
            for index in range(12):
                rows.append(
                    {
                        "id": (
                            f"{int(preference)}-{int(event)}-{index}"
                        ),
                        "utterance": f"sample {index}",
                        "preference": preference,
                        "event": event,
                    }
                )
        return rows

    def test_selection_is_balanced_and_reproducible(self) -> None:
        rows = self.build_rows()

        first = select_balanced_rows(rows, total=32, seed=42)
        second = select_balanced_rows(rows, total=32, seed=42)

        self.assertEqual(
            [row["id"] for row in first],
            [row["id"] for row in second],
        )
        counts = Counter(
            (row["preference"], row["event"]) for row in first
        )
        self.assertEqual(set(counts.values()), {8})

    def test_selection_requires_four_way_divisible_limit(self) -> None:
        with self.assertRaises(HybridEvaluationError):
            select_balanced_rows(
                self.build_rows(),
                total=30,
                seed=42,
            )

    def test_axis_header_format_is_available(self) -> None:
        arguments = build_parser().parse_args(
            [
                "--dataset-dir",
                "dataset",
                "--embeddings-dir",
                "embeddings",
                "--weights",
                "weights.npz",
                "--prompt",
                "prompt.txt",
                "--model-artifact",
                "model.litertlm",
                "--runtime-version",
                "0.13.1",
                "--output-dir",
                "output",
                "--header-format",
                "axes",
            ]
        )

        self.assertEqual(arguments.header_format, "axes")


if __name__ == "__main__":
    unittest.main()
