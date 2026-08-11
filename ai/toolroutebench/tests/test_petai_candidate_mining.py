from __future__ import annotations

import unittest

from toolroutebench.petai_candidate_mining import (
    build_mining_pool_rows,
    select_candidate_evidence,
    select_rejected_audit_sample,
)


class PetAICandidateMiningTests(unittest.TestCase):
    def test_pool_preserves_source_labels_without_deriving_petai_labels(self) -> None:
        rows = build_mining_pool_rows(
            [
                {
                    "source": "3i4k",
                    "source_split": "train_validation",
                    "source_line": 7,
                    "source_label": 0,
                    "source_label_name": "fragment",
                    "utterance": "타이머 25분.",
                },
                {
                    "source": "3i4k",
                    "source_split": "train_validation",
                    "source_line": 8,
                    "source_label": 2,
                    "source_label_name": "question",
                    "utterance": "넌 몇 살이야?",
                },
            ],
            seed=3,
        )
        self.assertEqual(len(rows), 2)
        self.assertTrue(all("call" not in row for row in rows))
        self.assertTrue(all("label" not in row for row in rows))
        self.assertEqual(
            {row["source_label_name"] for row in rows},
            {"fragment", "question"},
        )

    def test_candidate_selection_unions_embedding_regex_and_gemma(self) -> None:
        case_ids = ["a", "b", "c", "d"]
        evidence = select_candidate_evidence(
            case_ids=case_ids,
            scores={
                "create_timer": [0.9, 0.7, 0.2, 0.1],
                "get_step_count": [0.1, 0.2, 0.8, 0.3],
            },
            tool_order=["create_timer", "get_step_count"],
            thresholds={"create_timer": 0.8, "get_step_count": 0.75},
            top_k_per_tool=1,
            relaxed_threshold_margin=0.1,
            regex_predictions={
                "a": [],
                "b": [],
                "c": [],
                "d": ["create_timer"],
            },
            gemma_predictions={"b": ["get_step_count"]},
        )
        self.assertEqual(
            evidence["a"]["create_timer"],
            ["embedding_top_k", "relaxed_threshold"],
        )
        self.assertEqual(evidence["b"]["create_timer"], ["relaxed_threshold"])
        self.assertEqual(evidence["b"]["get_step_count"], ["gemma_prompt_router"])
        self.assertEqual(
            evidence["c"]["get_step_count"],
            ["embedding_top_k", "relaxed_threshold"],
        )
        self.assertEqual(evidence["d"]["create_timer"], ["regex"])

    def test_rejected_audit_sampling_is_deterministic_and_stratified(self) -> None:
        rows = [
            {
                "case_id": f"case-{label}-{index}",
                "source_label": label,
                "source_label_name": str(label),
            }
            for label in range(7)
            for index in range(3)
        ]
        first = select_rejected_audit_sample(
            pool_rows=rows,
            selected_case_ids={"case-0-0", "case-1-0"},
            per_source_label=1,
            seed=11,
        )
        second = select_rejected_audit_sample(
            pool_rows=rows,
            selected_case_ids={"case-0-0", "case-1-0"},
            per_source_label=1,
            seed=11,
        )
        self.assertEqual(first, second)
        self.assertEqual(len(first), 7)
        self.assertEqual({row["source_label"] for row in first}, set(range(7)))
        self.assertFalse(
            {row["case_id"] for row in first}
            & {"case-0-0", "case-1-0"}
        )


if __name__ == "__main__":
    unittest.main()
