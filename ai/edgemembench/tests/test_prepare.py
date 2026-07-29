import copy
import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import prepare


def source_record(
    *,
    question_id: str = "q1",
    question_type: str = "single-session-user",
    role: str = "user",
    has_answer: bool = True,
) -> dict:
    return {
        "question_id": question_id,
        "question_type": question_type,
        "question": "What did I eat?",
        "answer": "sushi",
        "answer_session_ids": ["s1"],
        "haystack_session_ids": ["s1"],
        "haystack_dates": ["2026-01-01"],
        "haystack_sessions": [
            [
                {"role": role, "content": "I ate sushi.", "has_answer": has_answer},
                {"role": "assistant", "content": "Sounds good."},
                {"role": "user", "content": "Another user message."},
            ]
        ],
    }


class StorageTests(unittest.TestCase):
    def test_all_boolean_combinations_map_to_labels(self) -> None:
        self.assertEqual(prepare.storage_label(False, False), "N")
        self.assertEqual(prepare.storage_label(True, False), "P")
        self.assertEqual(prepare.storage_label(False, True), "E")
        self.assertEqual(prepare.storage_label(True, True), "B")

    def test_normalization_sets_store_from_axes(self) -> None:
        record = {
            "id": "x",
            "utterance": "초밥을 좋아해.",
            "split": "test",
            "preference": True,
            "event": False,
        }
        normalized = prepare.normalize_storage_record(record)
        self.assertEqual(normalized["expected"]["label"], "P")
        self.assertTrue(normalized["expected"]["store"])


class LongMemEvalAdapterTests(unittest.TestCase):
    def test_selection_assigns_b_c_and_d(self) -> None:
        b = source_record()
        c = source_record(question_id="q2", question_type="knowledge-update")
        d = source_record(question_id="q3_abs", has_answer=False)
        d["answer_session_ids"] = []
        selected = prepare.select_longmemeval_cases([b, c, d])
        self.assertEqual({axis: len(rows) for axis, rows in selected.items()}, {
            "B": 1,
            "C": 1,
            "D": 1,
        })

    def test_assistant_evidence_is_excluded_from_b(self) -> None:
        record = source_record(role="assistant")
        selected = prepare.select_longmemeval_cases([record])
        self.assertEqual(selected["B"], [])

    def test_normalization_keeps_only_user_turns_and_gold_id(self) -> None:
        normalized = prepare.normalize_longmemeval_record(
            source_record(), "B", "single_memory_retrieval"
        )
        turns = normalized["history"][0]["turns"]
        self.assertEqual([turn["role"] for turn in turns], ["user", "user"])
        self.assertEqual(
            normalized["expected"]["gold_evidence_turn_ids"],
            ["s1::turn-0000"],
        )

    def test_empty_non_evidence_user_turn_is_dropped(self) -> None:
        record = source_record()
        record["haystack_sessions"][0].append({"role": "user", "content": ""})
        normalized = prepare.normalize_longmemeval_record(
            record, "B", "single_memory_retrieval"
        )
        self.assertEqual(len(normalized["history"][0]["turns"]), 2)

    def test_abstention_has_no_gold_evidence(self) -> None:
        record = source_record(question_id="q_abs", has_answer=False)
        record["answer_session_ids"] = []
        normalized = prepare.normalize_longmemeval_record(
            record, "D", "abstention"
        )
        self.assertTrue(normalized["expected"]["expected_abstention"])
        self.assertEqual(normalized["expected"]["gold_evidence_turn_ids"], [])

    def test_abstention_preserves_incomplete_evidence_separately(self) -> None:
        record = source_record(question_id="q_abs", has_answer=True)
        normalized = prepare.normalize_longmemeval_record(
            record, "D", "abstention"
        )
        self.assertEqual(normalized["expected"]["gold_evidence_turn_ids"], [])
        self.assertEqual(
            normalized["expected"]["partial_evidence_turn_ids"],
            ["s1::turn-0000"],
        )

    def test_missing_gold_is_rejected_for_answerable_case(self) -> None:
        with self.assertRaises(prepare.BenchmarkError):
            prepare.normalize_longmemeval_record(
                source_record(has_answer=False), "B", "single_memory_retrieval"
            )

    def test_non_user_leak_is_rejected(self) -> None:
        normalized = prepare.normalize_longmemeval_record(
            source_record(), "B", "single_memory_retrieval"
        )
        normalized["history"][0]["turns"][0]["role"] = "assistant"
        with self.assertRaises(prepare.BenchmarkError):
            prepare.validate_memory_records("B", [normalized], 1)

    def test_missing_gold_turn_is_rejected(self) -> None:
        normalized = prepare.normalize_longmemeval_record(
            source_record(), "B", "single_memory_retrieval"
        )
        normalized["expected"]["gold_evidence_turn_ids"] = ["missing"]
        with self.assertRaises(prepare.BenchmarkError):
            prepare.validate_memory_records("B", [normalized], 1)


class DeterminismTests(unittest.TestCase):
    def test_canonical_json_is_order_independent(self) -> None:
        self.assertEqual(
            prepare.canonical_json({"b": 1, "a": 2}),
            prepare.canonical_json({"a": 2, "b": 1}),
        )

    def test_jsonl_write_is_byte_deterministic(self) -> None:
        records = [{"z": 1, "a": "한글"}, {"b": True}]
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.jsonl"
            second = Path(directory) / "second.jsonl"
            prepare.write_jsonl_atomic(first, records)
            prepare.write_jsonl_atomic(second, copy.deepcopy(records))
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_verify_file_rejects_wrong_hash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.json"
            path.write_text(json.dumps([]), encoding="utf-8")
            with self.assertRaises(prepare.BenchmarkError):
                prepare.verify_file(path, "0" * 64, "fixture")


if __name__ == "__main__":
    unittest.main()
