from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from train_classifier import (  # noqa: E402
    ClassifierTrainingError,
    calculate_metrics,
    load_embedding_split,
    select_threshold,
    validate_split_boundaries,
)


class TrainClassifierTests(unittest.TestCase):
    def write_split(
        self,
        directory: Path,
        split: str,
        *,
        row_id: str,
        utterance: str,
    ) -> Path:
        path = directory / f"{split}.jsonl"
        path.write_text(
            json.dumps(
                {
                    "id": row_id,
                    "utterance": utterance,
                    "preference": True,
                    "event": False,
                    "challenge_type": "test",
                    "split": split,
                    "embedding": [0.5, -0.5],
                },
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        return path

    def test_load_embedding_split_preserves_two_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = self.write_split(
                Path(temporary_directory),
                "train",
                row_id="one",
                utterance="나는 딸기를 좋아해.",
            )
            split = load_embedding_split(
                path,
                split_name="train",
                expected_dimension=2,
            )

        np.testing.assert_array_equal(split.targets, [[1, 0]])
        np.testing.assert_allclose(split.features, [[0.5, -0.5]])

    def test_split_boundary_validation_rejects_duplicate_utterance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            train = load_embedding_split(
                self.write_split(
                    directory,
                    "train",
                    row_id="train-one",
                    utterance="같은 문장",
                ),
                split_name="train",
                expected_dimension=2,
            )
            validation = load_embedding_split(
                self.write_split(
                    directory,
                    "validation",
                    row_id="validation-one",
                    utterance="같은 문장",
                ),
                split_name="validation",
                expected_dimension=2,
            )

            with self.assertRaises(ClassifierTrainingError):
                validate_split_boundaries([train, validation])

    def test_threshold_selection_prefers_closest_tie_to_half(self) -> None:
        targets = np.asarray([0, 1], dtype=np.int64)
        probabilities = np.asarray([0.2, 0.8], dtype=np.float32)

        threshold = select_threshold(targets, probabilities)

        self.assertAlmostEqual(threshold, 0.5)

    def test_metrics_report_perfect_multilabel_predictions(self) -> None:
        targets = np.asarray([[1, 0], [0, 1], [1, 1]], dtype=np.int64)
        probabilities = np.asarray(
            [[0.9, 0.1], [0.2, 0.8], [0.8, 0.9]],
            dtype=np.float32,
        )
        metrics = calculate_metrics(
            targets,
            probabilities,
            np.asarray([0.5, 0.5], dtype=np.float32),
        )

        self.assertEqual(metrics["exact_match_accuracy"], 1.0)
        self.assertEqual(metrics["micro_f1"], 1.0)
        self.assertEqual(metrics["macro_f1"], 1.0)


if __name__ == "__main__":
    unittest.main()
