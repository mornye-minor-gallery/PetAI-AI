from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cohort_calibration_runner as calibration


class CohortCalibrationContractTests(unittest.TestCase):
    def test_frozen_dataset_has_expected_case_pair_and_split_counts(self) -> None:
        rows = calibration.load_dataset()
        self.assertEqual(len(rows), 50)
        self.assertEqual(sum(len(row["candidates"]) for row in rows), 100)
        self.assertEqual(
            {split: sum(row["split"] == split for row in rows)
             for split in ("calibration", "holdout")},
            {"calibration": 35, "holdout": 15},
        )

    def test_every_case_has_one_same_and_one_different_candidate(self) -> None:
        for row in calibration.load_dataset():
            self.assertEqual(
                {candidate["label"] for candidate in row["candidates"]},
                {"same_cohort", "different_cohort"},
            )

    def test_embedding_contract_has_50_queries_and_150_documents(self) -> None:
        records = calibration.embedding_records(calibration.load_dataset())
        self.assertEqual(len(records), 200)
        self.assertEqual(sum(row["kind"] == "query" for row in records), 50)
        self.assertEqual(sum(row["kind"] == "document" for row in records), 150)

    def test_prepare_embeddings_is_idempotent_for_identical_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            inputs = Path(directory) / "inputs.jsonl"
            first = calibration.prepare_embeddings(
                calibration.DEFAULT_DATASET_PATH, inputs
            )
            second = calibration.prepare_embeddings(
                calibration.DEFAULT_DATASET_PATH, inputs
            )
            self.assertEqual(first, second)


class CohortCalibrationPolicyTests(unittest.TestCase):
    @staticmethod
    def candidates() -> list[dict]:
        return [
            {
                "turn_id": "same",
                "label": "same_cohort",
                "query_score": 0.76,
                "pair_score": 0.90,
            },
            {
                "turn_id": "different",
                "label": "different_cohort",
                "query_score": 0.80,
                "pair_score": 0.70,
            },
        ]

    def test_zero_delta_is_query_only(self) -> None:
        selected = calibration.select_candidate(self.candidates(), 0.0)
        self.assertEqual(selected["turn_id"], "different")

    def test_band_delta_allows_pair_similarity_to_recover_same_cohort(self) -> None:
        selected = calibration.select_candidate(self.candidates(), 0.05)
        self.assertEqual(selected["turn_id"], "same")

    def test_delta_boundary_is_inclusive(self) -> None:
        candidates = self.candidates()
        candidates[0]["query_score"] = 0.75
        selected = calibration.select_candidate(candidates, 0.05)
        self.assertEqual(selected["turn_id"], "same")

    def test_infinite_delta_is_pair_only(self) -> None:
        selected = calibration.select_candidate(self.candidates(), float("inf"))
        self.assertEqual(selected["turn_id"], "same")

    def test_choose_delta_uses_calibration_accuracy_then_smallest_delta(self) -> None:
        rows = [
            {"delta": 0.0, "accuracy": 0.8},
            {"delta": 0.02, "accuracy": 0.9},
            {"delta": 0.05, "accuracy": 0.9},
            {"delta": "inf", "accuracy": 1.0},
        ]
        self.assertEqual(calibration.choose_delta(rows), 0.02)

    def test_score_delta_counts_only_same_cohort_as_success(self) -> None:
        cases = [
            {"case_id": "a", "family": "fa", "candidates": self.candidates()},
            {
                "case_id": "b",
                "family": "fb",
                "candidates": copy.deepcopy(self.candidates()),
            },
        ]
        result = calibration.score_delta(cases, 0.05)
        self.assertEqual(result["correct"], 2)
        self.assertEqual(result["accuracy"], 1.0)
        self.assertEqual(len(result["wilson_95"]), 2)


if __name__ == "__main__":
    unittest.main()
