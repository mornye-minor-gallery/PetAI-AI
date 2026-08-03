from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cohort_similarity_runner as cohort
import prepare
import retrieval_runner as dense


class FakeEmbeddingStore:
    def __init__(self, vectors: dict[tuple[str, str], tuple[float, ...]]) -> None:
        self.vectors = vectors

    def vector(self, kind: str, text: str) -> tuple[float, ...]:
        return self.vectors[(kind, text)]


def fixture_record() -> dict:
    return {
        "case_id": "case-1",
        "axis": "C",
        "task": "knowledge_update",
        "query": "What do I currently prefer?",
        "history": [
            {
                "session_id": "session-old",
                "timestamp": "2026/01/01 (Thu) 00:00",
                "turns": [
                    {
                        "turn_id": "old",
                        "role": "user",
                        "content": "I prefer sushi.",
                    }
                ],
            },
            {
                "session_id": "session-current",
                "timestamp": "2026/02/01 (Sun) 00:00",
                "turns": [
                    {
                        "turn_id": "current",
                        "role": "user",
                        "content": "I now prefer pasta.",
                    }
                ],
            },
            {
                "session_id": "session-context",
                "timestamp": "2026/03/01 (Sun) 00:00",
                "turns": [
                    {
                        "turn_id": "context",
                        "role": "user",
                        "content": "I visited a restaurant.",
                    }
                ],
            },
            {
                "session_id": "session-negative",
                "timestamp": "2026/04/01 (Wed) 00:00",
                "turns": [
                    {
                        "turn_id": "negative",
                        "role": "user",
                        "content": "I bought a bicycle.",
                    }
                ],
            },
        ],
        "expected": {
            "evaluation_status": "scored",
            "temporal_subtype": "current_state",
            "gold_evidence_turn_ids": ["old", "current"],
            "target_evidence_turn_ids": ["current"],
            "competing_evidence_turn_ids": ["old"],
            "context_evidence_turn_ids": ["context"],
        },
    }


def fixture_store() -> FakeEmbeddingStore:
    return FakeEmbeddingStore(
        {
            ("query", "What do I currently prefer?"): (1.0, 0.0),
            ("document", "I prefer sushi."): (1.0, 0.0),
            ("document", "I now prefer pasta."): (0.9, 0.1),
            ("document", "I visited a restaurant."): (0.8, 0.2),
            ("document", "I bought a bicycle."): (0.0, 1.0),
        }
    )


class CohortSimilarityMathTests(unittest.TestCase):
    def test_content_tokens_remove_values_and_generic_stopwords(self) -> None:
        self.assertEqual(
            cohort.content_tokens("My personal best time was 27:12."),
            frozenset({"personal", "best", "time"}),
        )
        self.assertEqual(
            cohort.shared_content_tokens(
                "My personal best time was 27:12.",
                "My personal best time is now 25:50.",
            ),
            ("best", "personal", "time"),
        )

    def test_average_precision_is_perfect_for_separated_scores(self) -> None:
        self.assertEqual(
            cohort.average_precision([0.9, 0.8], [0.2, 0.1]),
            1.0,
        )

    def test_threshold_metrics_count_false_pairs_per_case(self) -> None:
        rows = cohort.threshold_metrics(
            [0.9, 0.7],
            {"a": [0.8, 0.2], "b": [0.6]},
            [0.75],
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["true_positive"], 1)
        self.assertEqual(rows[0]["false_positive"], 1)
        self.assertEqual(rows[0]["cases_with_false_pair"], 1)
        self.assertEqual(rows[0]["mean_false_pairs_per_case"], 0.5)

    def test_combined_gate_requires_cosine_and_overlap(self) -> None:
        rows = cohort.combined_gate_metrics(
            [
                {"cosine": 0.9, "overlap_count": 2},
                {"cosine": 0.7, "overlap_count": 3},
            ],
            {
                "a": [
                    {"cosine": 0.8, "overlap_count": 1},
                    {"cosine": 0.6, "overlap_count": 4},
                ]
            },
            [0.75],
            [2],
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["true_positive"], 1)
        self.assertEqual(rows[0]["false_positive"], 0)
        self.assertEqual(rows[0]["precision"], 1.0)
        self.assertEqual(rows[0]["recall"], 0.5)

    def test_partner_top1_selects_only_one_candidate_per_anchor(self) -> None:
        def pair(
            left: str,
            right: str,
            cosine: float,
            overlap: int,
            *,
            positive: bool,
        ) -> dict:
            return {
                "left": {"turn_id": left},
                "right": {"turn_id": right},
                "cosine": cosine,
                "overlap_count": overlap,
                "operational": positive,
            }

        case_rows = [
            {
                "positive_pairs": [
                    pair("a", "b", 0.8, 2, positive=True)
                ],
                "negative_pairs": [
                    pair("a", "c", 0.9, 0, positive=False),
                    pair("b", "c", 0.4, 0, positive=False),
                ],
            }
        ]
        rows = cohort.partner_top1_metrics(
            case_rows,
            [-1.0],
            [0, 1],
        )
        no_gate = next(row for row in rows if row["overlap_threshold"] == 0)
        overlap_gate = next(
            row for row in rows if row["overlap_threshold"] == 1
        )
        self.assertEqual(no_gate["anchor_count"], 2)
        self.assertEqual(no_gate["selected_count"], 2)
        self.assertEqual(no_gate["correct_count"], 1)
        self.assertEqual(no_gate["incorrect_count"], 1)
        self.assertEqual(overlap_gate["correct_count"], 2)
        self.assertEqual(overlap_gate["incorrect_count"], 0)
        self.assertEqual(overlap_gate["precision"], 1.0)
        self.assertEqual(overlap_gate["recall"], 1.0)

    def test_canonical_pair_is_order_independent(self) -> None:
        self.assertEqual(
            cohort.canonical_pair("new", "old"),
            cohort.canonical_pair("old", "new"),
        )

    def test_blind_annotations_rescore_partner_selection(self) -> None:
        def pair(
            left: str,
            right: str,
            cosine: float,
            overlap: int,
            label: str,
        ) -> dict:
            return {
                "case_id": "case-1",
                "query": "same state",
                "label": label,
                "operational": True,
                "left": {"turn_id": left, "text": left, "timestamp": [1]},
                "right": {"turn_id": right, "text": right, "timestamp": [2]},
                "cosine": cosine,
                "overlap_count": overlap,
            }

        positive = pair("a", "b", 0.8, 2, "same_fact_version")
        negative_a = pair("a", "c", 0.9, 0, "non_evidence_top_k")
        negative_b = pair("b", "c", 0.4, 0, "non_evidence_top_k")
        annotations = {
            cohort.annotation_key("case-1", "a", "b"): {
                "label": "same_cohort",
                "reason": "restatement",
                "pair_id": "p-ab",
            },
            cohort.annotation_key("case-1", "a", "c"): {
                "label": "different_cohort",
                "reason": "different_attribute",
                "pair_id": "p-ac",
            },
            cohort.annotation_key("case-1", "b", "c"): {
                "label": "different_cohort",
                "reason": "different_attribute",
                "pair_id": "p-bc",
            },
        }
        rows = cohort.annotation_partner_top1_metrics(
            [{
                "case_id": "case-1",
                "positive_pairs": [positive],
                "negative_pairs": [negative_a, negative_b],
            }],
            annotations,
            [(-1.0, 0), (-1.0, 1)],
        )
        no_gate, overlap_gate = rows
        self.assertEqual(no_gate["same_cohort_count"], 1)
        self.assertEqual(no_gate["different_cohort_count"], 1)
        self.assertEqual(no_gate["decided_precision"], 0.5)
        self.assertEqual(overlap_gate["same_cohort_count"], 2)
        self.assertEqual(overlap_gate["decided_precision"], 1.0)
        analysis = cohort.analyze_partner_failures(
            [{
                "case_id": "case-1",
                "positive_pairs": [positive],
                "negative_pairs": [negative_a, negative_b],
            }],
            annotations,
            comparison_gate=(-1.0, 1),
            query_candidate_scores={
                ("case-1", "a"): 0.7,
                ("case-1", "b"): 0.8,
                ("case-1", "c"): 0.4,
            },
        )
        self.assertEqual(analysis["failure_count"], 1)
        self.assertEqual(analysis["reason_counts"], {"different_attribute": 1})
        self.assertEqual(
            analysis["comparison_gate_transitions"],
            {"same_cohort": 1},
        )
        self.assertEqual(
            analysis["query_candidate_score_comparison"],
            {"alternative_higher": 1, "equal": 0, "wrong_higher": 0},
        )
        abc_rows = cohort.annotation_abc_policy_metrics(
            [{
                "case_id": "case-1",
                "positive_pairs": [positive],
                "negative_pairs": [negative_a, negative_b],
            }],
            annotations,
            {
                ("case-1", "a"): 0.7,
                ("case-1", "b"): 0.8,
                ("case-1", "c"): 0.4,
            },
            [0.0, float("inf")],
        )
        self.assertEqual(abc_rows[0]["policy"], "B_query_only")
        self.assertEqual(abc_rows[0]["same_cohort_count"], 2)
        self.assertEqual(abc_rows[1]["policy"], "A_pair_only")
        self.assertEqual(abc_rows[1]["same_cohort_count"], 1)
        transitions = cohort.annotation_abc_policy_transitions(
            [{
                "case_id": "case-1",
                "positive_pairs": [positive],
                "negative_pairs": [negative_a, negative_b],
            }],
            annotations,
            {
                ("case-1", "a"): 0.7,
                ("case-1", "b"): 0.8,
                ("case-1", "c"): 0.4,
            },
            [0.0, float("inf")],
        )
        self.assertEqual(
            transitions["A_pair_only_to_delta_0"],
            {"different_cohort->same_cohort": 1, "same_cohort->same_cohort": 1},
        )

    def test_annotation_rescore_writes_frozen_outputs(self) -> None:
        pair_rows = [
            {
                "case_id": "case-1",
                "query": "same state",
                "label": "same_fact_version",
                "operational": True,
                "left": {"turn_id": "a", "text": "same state", "timestamp": [1]},
                "right": {"turn_id": "b", "text": "same state", "timestamp": [2]},
                "cosine": 0.9,
                "overlap_count": 2,
            },
            {
                "case_id": "case-1",
                "query": "same state",
                "label": "non_evidence_top_k",
                "operational": True,
                "left": {"turn_id": "a", "text": "same state", "timestamp": [1]},
                "right": {"turn_id": "c", "text": "other", "timestamp": [3]},
                "cosine": 0.2,
                "overlap_count": 0,
            },
            {
                "case_id": "case-1",
                "query": "same state",
                "label": "non_evidence_top_k",
                "operational": True,
                "left": {"turn_id": "b", "text": "same state", "timestamp": [2]},
                "right": {"turn_id": "c", "text": "other", "timestamp": [3]},
                "cosine": 0.1,
                "overlap_count": 0,
            },
        ]
        annotations = [
            {
                "pair_id": "p1",
                "case_id": "case-1",
                "left_turn_id": "a",
                "right_turn_id": "b",
                "label": "same_cohort",
                "reason": "restatement",
            },
            {
                "pair_id": "p2",
                "case_id": "case-1",
                "left_turn_id": "a",
                "right_turn_id": "c",
                "label": "different_cohort",
                "reason": "different_attribute",
            },
            {
                "pair_id": "p3",
                "case_id": "case-1",
                "left_turn_id": "b",
                "right_turn_id": "c",
                "label": "different_cohort",
                "reason": "different_attribute",
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pair_path = root / "pair_scores.jsonl"
            annotation_path = root / "annotations.jsonl"
            sweep_path = root / "partner_top1_sweep.json"
            prepare.write_jsonl_atomic(pair_path, pair_rows)
            prepare.write_jsonl_atomic(annotation_path, annotations)
            prepare.write_json_atomic(sweep_path, {
                "rows": [{
                    "cosine_threshold": -1.0,
                    "overlap_threshold": 0,
                }]
            })
            summary = cohort.rescore_blind_annotations(
                pair_scores_path=pair_path,
                source_partner_sweep_path=sweep_path,
                annotations_path=annotation_path,
                output_dir=root,
            )
            self.assertEqual(summary["coverage"]["annotated_pairs"], 3)
            self.assertEqual(summary["separation"]["cosine_auroc"], 1.0)
            self.assertTrue((root / "annotation_rescore_summary.json").is_file())


class CohortSimilarityRecordTests(unittest.TestCase):
    def test_target_competing_is_positive_and_context_is_not_negative(self) -> None:
        row = cohort.analyze_record(
            fixture_record(),
            fixture_store(),
            top_k=4,
            vector_cache={},
        )
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(len(row["positive_pairs"]), 1)
        self.assertTrue(row["positive_pairs"][0]["operational"])
        self.assertEqual(row["positive_pairs"][0]["label"], "same_fact_version")
        self.assertEqual(
            row["positive_pairs"][0]["shared_tokens"],
            ["prefer"],
        )
        self.assertEqual(row["positive_pairs"][0]["overlap_count"], 1)

        negative_ids = {
            member["turn_id"]
            for pair in row["negative_pairs"]
            for member in (pair["left"], pair["right"])
        }
        self.assertIn("negative", negative_ids)
        self.assertNotIn("context", negative_ids)
        self.assertEqual(len(row["negative_pairs"]), 2)

    def test_positive_outside_top_k_is_intrinsic_but_not_operational(self) -> None:
        row = cohort.analyze_record(
            fixture_record(),
            fixture_store(),
            top_k=1,
            vector_cache={},
        )
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(len(row["positive_pairs"]), 1)
        self.assertFalse(row["positive_pairs"][0]["operational"])
        self.assertEqual(row["operational_margins"], [])

    def test_excluded_or_non_conflict_record_is_skipped(self) -> None:
        record = fixture_record()
        record["expected"]["evaluation_status"] = "excluded"
        self.assertIsNone(
            cohort.analyze_record(
                record,
                fixture_store(),
                top_k=4,
                vector_cache={},
            )
        )

        record = fixture_record()
        record["expected"]["competing_evidence_turn_ids"] = []
        self.assertIsNone(
            cohort.analyze_record(
                record,
                fixture_store(),
                top_k=4,
                vector_cache={},
            )
        )


if __name__ == "__main__":
    unittest.main()
