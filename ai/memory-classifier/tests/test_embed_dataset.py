from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from embed_dataset import (
    CLASSIFICATION_PREFIX,
    DatasetEmbeddingError,
    build_input_tokens,
    load_split,
)


class FakeTokenizer:
    def __init__(self, encoded: list[int]) -> None:
        self.encoded = encoded
        self.received_text: str | None = None

    def bos_id(self) -> int:
        return 1

    def eos_id(self) -> int:
        return 2

    def pad_id(self) -> int:
        return 0

    def encode(self, text: str, out_type: type[int]) -> list[int]:
        self.received_text = text
        assert out_type is int
        return self.encoded


class EmbedDatasetTests(unittest.TestCase):
    def test_input_tokens_match_ios_preprocessing_contract(self) -> None:
        tokenizer = FakeTokenizer([10, 11])

        tokens = build_input_tokens("  나는 딸기를 좋아해. \n", tokenizer, 8)

        self.assertEqual(
            tokenizer.received_text,
            CLASSIFICATION_PREFIX + "나는 딸기를 좋아해.",
        )
        np.testing.assert_array_equal(
            tokens,
            np.asarray([1, 10, 11, 2, 0, 0, 0, 0], dtype=np.int32),
        )

    def test_input_tokens_truncate_before_eos(self) -> None:
        tokenizer = FakeTokenizer([10, 11, 12, 13, 14])

        tokens = build_input_tokens("hello", tokenizer, 5)

        np.testing.assert_array_equal(
            tokens,
            np.asarray([1, 10, 11, 12, 2], dtype=np.int32),
        )

    def test_load_split_preserves_labels(self) -> None:
        rows = [
            {
                "id": f"memory-{index}",
                "utterance": f"문장 {index}",
                "preference": index % 2 == 0,
                "event": index % 3 == 0,
                "challenge_type": "test",
            }
            for index in range(100)
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.jsonl"
            path.write_text(
                "".join(
                    json.dumps(row, ensure_ascii=False) + "\n" for row in rows
                ),
                encoding="utf-8",
            )

            records = load_split(path, "test")

        self.assertEqual(len(records), 100)
        self.assertEqual(records[0].id, "memory-0")
        self.assertTrue(records[0].preference)
        self.assertTrue(records[0].event)
        self.assertEqual(records[0].split, "test")

    def test_load_split_rejects_wrong_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.jsonl"
            path.write_text("", encoding="utf-8")

            with self.assertRaises(DatasetEmbeddingError):
                load_split(path, "test")

    def test_load_split_accepts_explicit_custom_count(self) -> None:
        row = {
            "id": "memory-one",
            "utterance": "문장 하나",
            "preference": False,
            "event": False,
            "challenge_type": "test",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic_challenge.jsonl"
            path.write_text(
                json.dumps(row, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )

            records = load_split(
                path,
                "synthetic_challenge",
                expected_count=1,
            )

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].split, "synthetic_challenge")


if __name__ == "__main__":
    unittest.main()
