from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cohort_labeler as labeler
import prepare


def source_pair(
    left_id: str,
    right_id: str,
    *,
    label: str,
    cosine: float,
    overlap: int,
    operational: bool = True,
) -> dict:
    return {
        "case_id": "case-1",
        "query": "What is current?",
        "temporal_subtype": "current_state",
        "label": label,
        "operational": operational,
        "left": {
            "turn_id": left_id,
            "text": f"Text for {left_id}",
            "timestamp": [2026, 1, 1, 0, 0],
        },
        "right": {
            "turn_id": right_id,
            "text": f"Text for {right_id}",
            "timestamp": [2026, 2, 1, 0, 0],
        },
        "cosine": cosine,
        "shared_tokens": [],
        "overlap_count": overlap,
    }


def fixture_queue() -> list[dict]:
    pairs = [
        source_pair(
            "a",
            "b",
            label="same_fact_version",
            cosine=0.8,
            overlap=2,
        ),
        source_pair(
            "a",
            "c",
            label="non_evidence_top_k",
            cosine=0.9,
            overlap=0,
        ),
        source_pair(
            "b",
            "c",
            label="non_evidence_top_k",
            cosine=0.4,
            overlap=0,
        ),
    ]
    sweep = {
        "rows": [
            {"cosine_threshold": -1.0, "overlap_threshold": 0},
            {"cosine_threshold": -1.0, "overlap_threshold": 1},
        ]
    }
    return labeler.build_queue(pairs, sweep, seed=42)


class QueueTests(unittest.TestCase):
    def test_queue_is_deterministic_and_deduplicates_directed_selections(self) -> None:
        first = fixture_queue()
        second = fixture_queue()
        self.assertEqual(first, second)
        self.assertEqual(len(first), 2)
        self.assertEqual(len({row["pair_id"] for row in first}), 2)

    def test_blind_state_hides_scores_and_source_labels(self) -> None:
        queue = fixture_queue()
        state = labeler.blind_state(queue, {}, 0)
        self.assertNotIn("case_id", state)
        self.assertNotIn("source_groups", state)
        self.assertNotIn("selected_by", state)
        self.assertNotIn("cosine", state)
        self.assertNotIn("overlap_count", state)
        self.assertEqual(set(state["left"]), {"text", "timestamp"})
        self.assertEqual(set(state["right"]), {"text", "timestamp"})


class AnnotationTests(unittest.TestCase):
    def test_draft_persists_and_can_be_reloaded(self) -> None:
        queue = fixture_queue()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "draft.jsonl"
            annotations: dict[str, dict] = {}
            row = queue[0]
            saved = labeler.save_annotation(
                path,
                queue,
                annotations,
                {
                    "pair_id": row["pair_id"],
                    "label": "same_cohort",
                    "reason": "same_attribute_update",
                    "note": "updated value",
                },
            )
            self.assertEqual(saved["label"], "same_cohort")
            reloaded = labeler.load_annotations(path, queue)
            self.assertEqual(reloaded[row["pair_id"]]["note"], "updated value")

    def test_export_requires_complete_annotations(self) -> None:
        queue = fixture_queue()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue_path = root / "queue.jsonl"
            draft_path = root / "draft.jsonl"
            output_path = root / "export.jsonl"
            prepare.write_jsonl_atomic(queue_path, queue)
            annotations: dict[str, dict] = {}
            labeler.save_annotation(
                draft_path,
                queue,
                annotations,
                {
                    "pair_id": queue[0]["pair_id"],
                    "label": "different_cohort",
                    "reason": "different_attribute",
                    "note": "",
                },
            )
            with self.assertRaises(labeler.CohortLabelerError):
                labeler.export_annotations(
                    queue_path=queue_path,
                    draft_path=draft_path,
                    output_path=output_path,
                )

            labeler.save_annotation(
                draft_path,
                queue,
                annotations,
                {
                    "pair_id": queue[1]["pair_id"],
                    "label": "ambiguous",
                    "reason": "insufficient_context",
                    "note": "",
                },
            )
            result = labeler.export_annotations(
                queue_path=queue_path,
                draft_path=draft_path,
                output_path=output_path,
            )
            self.assertEqual(result["annotations"], 2)
            self.assertTrue(output_path.is_file())

    def test_agent_votes_require_agreement_then_accept_blind_adjudication(self) -> None:
        queue = fixture_queue()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vote_1 = root / "vote-1.jsonl"
            vote_2 = root / "vote-2.jsonl"
            vote_3 = root / "vote-3.jsonl"
            adjudication = root / "adjudication.jsonl"
            draft = root / "agent-draft.jsonl"
            disagreements = root / "disagreements"
            prepare.write_jsonl_atomic(vote_1, [
                {
                    "pair_id": queue[0]["pair_id"],
                    "label": "same_cohort",
                    "reason": "same_attribute_update",
                    "rationale": "같은 속성의 갱신이다.",
                },
                {
                    "pair_id": queue[1]["pair_id"],
                    "label": "same_cohort",
                    "reason": "restatement",
                    "rationale": "같은 내용을 반복한다.",
                },
            ])
            prepare.write_jsonl_atomic(vote_2, [{
                "pair_id": queue[1]["pair_id"],
                "label": "different_cohort",
                "reason": "different_attribute",
                "rationale": "서로 다른 속성이다.",
            }])
            prepare.write_jsonl_atomic(vote_3, [{
                "pair_id": queue[0]["pair_id"],
                "label": "same_cohort",
                "reason": "restatement",
                "rationale": "같은 상태를 다시 말한다.",
            }])

            vote_specs = [
                ("annotator-1", vote_1),
                ("annotator-2", vote_2),
                ("annotator-3", vote_3),
            ]
            initial = labeler.reconcile_agent_votes(
                queue=queue,
                vote_specs=vote_specs,
                draft_path=draft,
                disagreement_dir=disagreements,
            )
            self.assertEqual(initial["consensus"], 1)
            self.assertEqual(initial["pending_adjudication"], 1)
            self.assertEqual(
                len(prepare.read_jsonl(disagreements / "annotator-3.jsonl")),
                1,
            )

            prepare.write_jsonl_atomic(adjudication, [{
                "pair_id": queue[1]["pair_id"],
                "label": "different_cohort",
                "reason": "different_attribute",
                "rationale": "시간 경쟁을 하지 않는 별도 속성이다.",
            }])
            final = labeler.reconcile_agent_votes(
                queue=queue,
                vote_specs=vote_specs + [("annotator-3", adjudication)],
                draft_path=draft,
                disagreement_dir=disagreements,
            )
            self.assertEqual(final["consensus"], 2)
            self.assertEqual(final["adjudicated"], 1)
            self.assertEqual(final["pending_adjudication"], 0)
            annotations = prepare.read_jsonl(draft)
            self.assertEqual(
                annotations[1]["agreement"],
                "majority_after_blind_adjudication",
            )
            self.assertEqual(len(annotations[1]["votes"]), 3)

    def test_fourth_blind_vote_breaks_a_three_way_tie(self) -> None:
        queue = fixture_queue()[:1]
        pair_id = queue[0]["pair_id"]
        ballots = [
            ("annotator-1", "same_cohort", "restatement"),
            ("annotator-2", "different_cohort", "different_attribute"),
            ("annotator-3", "ambiguous", "insufficient_context"),
            ("annotator-4", "ambiguous", "insufficient_context"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vote_specs = []
            for annotator, label, reason in ballots:
                path = root / f"{annotator}.jsonl"
                prepare.write_jsonl_atomic(path, [{
                    "pair_id": pair_id,
                    "label": label,
                    "reason": reason,
                    "rationale": "독립 판정이다.",
                }])
                vote_specs.append((annotator, path))
            result = labeler.reconcile_agent_votes(
                queue=queue,
                vote_specs=vote_specs,
                draft_path=root / "draft.jsonl",
                disagreement_dir=root / "disagreements",
            )
            self.assertEqual(result["consensus"], 1)
            self.assertEqual(result["tiebroken"], 1)
            annotation = prepare.read_jsonl(root / "draft.jsonl")[0]
            self.assertEqual(annotation["label"], "ambiguous")
            self.assertEqual(
                annotation["agreement"],
                "majority_after_fresh_blind_tiebreak",
            )


if __name__ == "__main__":
    unittest.main()
