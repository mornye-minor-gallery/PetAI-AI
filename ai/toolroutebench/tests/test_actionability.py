from __future__ import annotations

import unittest

from toolroutebench.actionability import (
    binary_label,
    parse_3i4k_lines,
    sample_per_source_label,
    split_train_validation,
    validate_split_boundaries,
)
from toolroutebench.common import ToolRouteBenchError


class ActionabilityDatasetTests(unittest.TestCase):
    def test_questions_and_commands_are_call_candidates(self) -> None:
        self.assertTrue(binary_label(2))
        self.assertTrue(binary_label(3))
        for label in (0, 1, 4, 5, 6):
            self.assertFalse(binary_label(label))

    def test_parser_normalizes_and_deduplicates_utterances(self) -> None:
        rows = parse_3i4k_lines(
            ["2\t오늘   일정이 뭐야\n", "2\t오늘 일정이 뭐야\n"],
            source_split="train_validation",
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["utterance"], "오늘 일정이 뭐야")
        self.assertEqual(rows[0]["source_label_name"], "question")

    def test_hash_split_and_sampling_are_deterministic(self) -> None:
        rows = parse_3i4k_lines(
            [f"{label}\t문장 {label}-{index}\n" for label in range(7) for index in range(30)],
            source_split="train_validation",
        )
        first_train, first_validation = split_train_validation(
            rows,
            seed=7,
            validation_fraction=0.2,
        )
        second_train, second_validation = split_train_validation(
            rows,
            seed=7,
            validation_fraction=0.2,
        )
        self.assertEqual(first_train, second_train)
        self.assertEqual(first_validation, second_validation)
        quotas = {str(label): 1 for label in range(7)}
        first = sample_per_source_label(
            first_train,
            quotas=quotas,
            seed=7,
            split="train",
        )
        second = sample_per_source_label(
            first_train,
            quotas=quotas,
            seed=7,
            split="train",
        )
        self.assertEqual(first, second)

    def test_split_boundary_validation_rejects_leakage(self) -> None:
        row = {
            "case_id": "one",
            "split": "train",
            "utterance": "같은 문장",
        }
        with self.assertRaises(ToolRouteBenchError):
            validate_split_boundaries(
                [row, {**row, "case_id": "two", "split": "test"}]
            )


if __name__ == "__main__":
    unittest.main()
