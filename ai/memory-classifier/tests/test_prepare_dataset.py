from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from prepare_dataset import EXPECTED_COUNTS, prepare_dataset


class PrepareDatasetTests(unittest.TestCase):
    def test_prepare_dataset_writes_balanced_splits(self) -> None:
        rows = []
        combinations = (
            (False, False),
            (True, False),
            (False, True),
            (True, True),
        )
        row_number = 0
        for split, count in EXPECTED_COUNTS.items():
            for index in range(count):
                preference, event = combinations[index % 4]
                rows.append(
                    {
                        "id": f"memory-{row_number}",
                        "utterance": f"고유한 문장 {row_number}",
                        "split": split,
                        "preference": preference,
                        "event": event,
                        "challenge_type": "test",
                        "expression_pattern": "test",
                        "surface_style": "clean",
                        "topic_hint": "test",
                        "family_id": f"{split}-family-{index}",
                    }
                )
                row_number += 1

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.jsonl"
            source.write_text(
                "".join(
                    json.dumps(row, ensure_ascii=False) + "\n"
                    for row in rows
                ),
                encoding="utf-8",
            )
            output_dir = root / "splits"

            manifest = prepare_dataset(source, output_dir)

            self.assertTrue(manifest.is_file())
            for split, count in EXPECTED_COUNTS.items():
                output = output_dir / f"{split}.jsonl"
                self.assertEqual(
                    len(output.read_text().splitlines()),
                    count,
                )


if __name__ == "__main__":
    unittest.main()
