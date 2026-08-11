from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np

from toolroutebench.actionability_mlp import (
    BinarySplit,
    _assert_splits_disjoint,
    _exclude_reference_overlaps,
    _load_petai_authoring_train,
    _tool_slice_metrics,
    binary_metrics,
    select_threshold,
)
from toolroutebench.common import ToolRouteBenchError, write_jsonl


class ActionabilityMLPTests(unittest.TestCase):
    def test_threshold_selection_prefers_perfect_binary_boundary(self) -> None:
        targets = np.asarray([0, 0, 1, 1], dtype=np.int64)
        probabilities = np.asarray([0.1, 0.2, 0.8, 0.9], dtype=np.float32)
        threshold = select_threshold(targets, probabilities)
        self.assertGreater(threshold, 0.2)
        self.assertLessEqual(threshold, 0.8)

    def test_metrics_surface_false_activation_and_call_miss(self) -> None:
        targets = np.asarray([0, 0, 1, 1], dtype=np.int64)
        probabilities = np.asarray([0.2, 0.8, 0.7, 0.3], dtype=np.float32)
        metrics = binary_metrics(targets, probabilities, 0.5)
        self.assertEqual(metrics["normal_false_activation_count"], 1)
        self.assertEqual(metrics["call_miss_count"], 1)
        self.assertEqual(metrics["confusion"], {"tn": 1, "fp": 1, "fn": 1, "tp": 1})

    def test_tool_slice_reports_call_recall_per_tool(self) -> None:
        split = BinarySplit(
            name="test",
            ids=["timer", "steps", "normal"],
            utterances=["타이머", "걸음 수", "잡담"],
            features=np.zeros((3, 768), dtype=np.float32),
            targets=np.asarray([1, 1, 0], dtype=np.int64),
            metadata=[
                {"tool_ids": ["create_timer"]},
                {"tool_ids": ["get_step_count"]},
                {"tool_ids": []},
            ],
        )
        metrics = _tool_slice_metrics(
            split,
            np.asarray([0.8, 0.2, 0.9], dtype=np.float32),
            0.5,
        )
        self.assertEqual(metrics["create_timer"]["call_recall"], 1.0)
        self.assertEqual(metrics["get_step_count"]["call_recall"], 0.0)

    def test_petai_authoring_can_load_call_only_or_matched_rows(self) -> None:
        vector = [0.0] * 768
        dataset_rows = [
            {
                "case_id": "call-1",
                "split": "authoring",
                "track": "single_tool",
                "utterance": "20초 타이머 맞춰 줘.",
                "gold_tool_ids": ["create_timer"],
                "difficulty": "direct",
                "expression_family_id": "timer.direct",
            },
            {
                "case_id": "normal-1",
                "split": "authoring",
                "track": "single_tool",
                "utterance": "타이머 기능도 있어?",
                "gold_tool_ids": [],
                "difficulty": "capability_or_meta",
                "expression_family_id": "timer.capability",
            },
        ]
        embedding_rows = [
            {
                "case_id": "call-1",
                "text": "20초 타이머 맞춰 줘.",
                "kind": "positive_prototype",
                "embedding": vector,
            },
            {
                "case_id": "normal-1",
                "text": "타이머 기능도 있어?",
                "kind": "normal_prototype",
                "embedding": vector,
            },
        ]
        with TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "authoring.jsonl"
            embeddings = root / "embeddings.jsonl"
            write_jsonl(dataset, dataset_rows)
            write_jsonl(embeddings, embedding_rows)
            call_only = _load_petai_authoring_train(
                dataset_path=dataset,
                embeddings_path=embeddings,
                mode="call-only",
            )
            matched = _load_petai_authoring_train(
                dataset_path=dataset,
                embeddings_path=embeddings,
                mode="all",
            )
        self.assertEqual(call_only.ids, ["call-1"])
        self.assertEqual(call_only.targets.tolist(), [1])
        self.assertEqual(matched.ids, ["call-1", "normal-1"])
        self.assertEqual(matched.targets.tolist(), [1, 0])

    def test_petai_authoring_rejects_non_authoring_rows(self) -> None:
        vector = [0.0] * 768
        with TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "dev.jsonl"
            embeddings = root / "embeddings.jsonl"
            write_jsonl(
                dataset,
                [
                    {
                        "case_id": "dev-1",
                        "split": "dev",
                        "track": "single_tool",
                        "utterance": "20초 타이머 맞춰 줘.",
                        "gold_tool_ids": ["create_timer"],
                    }
                ],
            )
            write_jsonl(
                embeddings,
                [
                    {
                        "case_id": "dev-1",
                        "text": "20초 타이머 맞춰 줘.",
                        "kind": "positive_prototype",
                        "embedding": vector,
                    }
                ],
            )
            with self.assertRaises(ToolRouteBenchError):
                _load_petai_authoring_train(
                    dataset_path=dataset,
                    embeddings_path=embeddings,
                    mode="all",
                )

    def test_split_overlap_is_rejected(self) -> None:
        empty = np.asarray([[0.0] * 768], dtype=np.float32)
        targets = np.asarray([1], dtype=np.int64)
        left = BinarySplit("train", ["a"], ["같은 문장"], empty, targets, [{}])
        right = BinarySplit("dev", ["b"], ["같은 문장"], empty, targets, [{}])
        with self.assertRaises(ToolRouteBenchError):
            _assert_splits_disjoint([left, right])

    def test_expression_family_overlap_is_rejected(self) -> None:
        features = np.asarray([[0.0] * 768], dtype=np.float32)
        targets = np.asarray([1], dtype=np.int64)
        family = [{"expression_family_id": "timer.direct"}]
        left = BinarySplit("train", ["a"], ["첫 문장"], features, targets, family)
        right = BinarySplit("dev", ["b"], ["둘째 문장"], features, targets, family)
        with self.assertRaises(ToolRouteBenchError):
            _assert_splits_disjoint([left, right])

    def test_reference_overlap_is_excluded_with_evidence(self) -> None:
        features = np.asarray([[0.0] * 768, [1.0] * 768], dtype=np.float32)
        targets = np.asarray([1, 1], dtype=np.int64)
        train = BinarySplit(
            "authoring",
            ["a", "b"],
            ["겹치는 문장", "남는 문장"],
            features,
            targets,
            [{}, {}],
        )
        reference = BinarySplit(
            "holdout",
            ["c"],
            ["겹치는 문장"],
            features[:1],
            targets[:1],
            [{}],
        )
        filtered = _exclude_reference_overlaps(train, [reference])
        self.assertEqual(filtered.ids, ["b"])
        self.assertEqual(
            filtered.exclusions,
            [
                {
                    "case_id": "a",
                    "overlaps": {"utterance": ["holdout"]},
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
