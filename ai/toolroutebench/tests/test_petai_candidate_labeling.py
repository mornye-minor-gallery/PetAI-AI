from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from toolroutebench.codex_adapter import CodexInvocation
from toolroutebench.common import read_json, read_jsonl, sha256_file, write_json, write_jsonl
from toolroutebench.petai_candidate_labeling import (
    build_balanced_actionability_rows,
    prepare_3i4k_petai_labeling_queue,
    reconcile_prediction_rows,
    run_3i4k_petai_labeling_stage,
)


def _validator(session_id: str) -> dict[str, str]:
    return {
        "interface": "codex_cli",
        "model": "gpt-5.6-sol",
        "reasoning_effort": "medium",
        "prompt_template_sha256": "a" * 64,
        "request_sha256": "b" * 64,
        "session_id": session_id,
    }


class PetAICandidateLabelingTests(unittest.TestCase):
    def test_balanced_pool_keeps_all_call_and_samples_equal_no_call(self) -> None:
        rows = [
            {
                "case_id": f"call-{index}",
                "call": True,
                "agreed_tool_ids": ["create_alarm"],
                "labeling_partition": "candidate",
            }
            for index in range(2)
        ]
        rows.extend(
            {
                "case_id": f"candidate-normal-{index}",
                "call": False,
                "agreed_tool_ids": [],
                "labeling_partition": "candidate",
            }
            for index in range(3)
        )
        rows.extend(
            {
                "case_id": f"rejected-normal-{index}",
                "call": False,
                "agreed_tool_ids": [],
                "labeling_partition": "rejected_audit",
            }
            for index in range(3)
        )
        first, excluded, counts = build_balanced_actionability_rows(
            agreed_rows=rows,
            candidate_no_call_fraction=0.5,
            seed=7,
        )
        second, _, _ = build_balanced_actionability_rows(
            agreed_rows=rows,
            candidate_no_call_fraction=0.5,
            seed=7,
        )
        self.assertEqual(first, second)
        self.assertEqual(counts["CALL"], 2)
        self.assertEqual(counts["NO_CALL"], 2)
        self.assertEqual(counts["NO_CALL_candidate"], 1)
        self.assertEqual(counts["NO_CALL_rejected_audit"], 1)
        self.assertEqual(len(first), 4)
        self.assertEqual(len(excluded), 4)

    def test_queue_combines_candidates_and_rejected_without_labels(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            mining_dir = root / "mining"
            mining_dir.mkdir()
            candidates_path = mining_dir / "candidates.jsonl"
            rejected_path = mining_dir / "rejected_audit_sample.jsonl"
            write_jsonl(
                candidates_path,
                [{"case_id": "candidate-1", "utterance": "알람 맞춰줘"}],
            )
            write_jsonl(
                rejected_path,
                [{"case_id": "rejected-1", "utterance": "같이 놀자"}],
            )
            mining_manifest = mining_dir / "mining_manifest.json"
            write_json(
                mining_manifest,
                {
                    "schema_version": (
                        "toolroutebench-3i4k-petai-candidate-mining-v1"
                    ),
                    "status": "candidate_search_only_unlabeled",
                    "artifacts": {
                        "candidates": {
                            "path": candidates_path.name,
                            "records": 1,
                            "sha256": sha256_file(candidates_path),
                        },
                        "rejected_audit_sample": {
                            "path": rejected_path.name,
                            "records": 1,
                            "sha256": sha256_file(rejected_path),
                        },
                    },
                },
            )
            with patch(
                "toolroutebench.petai_candidate_labeling.git_commit",
                return_value="commit",
            ):
                manifest_path = prepare_3i4k_petai_labeling_queue(
                    mining_manifest_path=mining_manifest,
                    output_dir=root / "queue",
                )
            queue = read_jsonl(root / "queue" / "labeling_queue.jsonl")
            self.assertEqual(len(queue), 2)
            self.assertEqual(
                {row["labeling_partition"] for row in queue},
                {"candidate", "rejected_audit"},
            )
            self.assertTrue(all("call" not in row for row in queue))
            self.assertTrue(all("gold_tool_ids" not in row for row in queue))
            self.assertEqual(read_json(manifest_path)["counts"]["records"], 2)

    def test_labeling_stage_hides_router_evidence_from_validator(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            queue_path = root / "queue.jsonl"
            queue_manifest_path = root / "queue_manifest.json"
            write_jsonl(
                queue_path,
                [
                    {
                        "case_id": "case-1",
                        "utterance": "알람 맞춰줘",
                        "router_scores": {"create_alarm": 0.99},
                    },
                    {
                        "case_id": "case-2",
                        "utterance": "같이 놀자",
                        "router_scores": {"create_alarm": 0.01},
                    },
                ],
            )
            write_json(
                queue_manifest_path,
                {
                    "schema_version": (
                        "toolroutebench-3i4k-petai-labeling-queue-v1"
                    ),
                    "role": "unlabeled_petai_contract_audit_queue",
                    "artifacts": {
                        "labeling_queue": {
                            "records": 2,
                            "sha256": sha256_file(queue_path),
                        }
                    },
                },
            )
            captured_prompts: list[str] = []

            def fake_complete_json(**kwargs):
                captured_prompts.append(kwargs["prompt"])
                return (
                    {
                        "predictions": [
                            {
                                "candidate_id": "case-1",
                                "predicted_tool_ids": ["create_alarm"],
                                "ambiguous": False,
                            },
                            {
                                "candidate_id": "case-2",
                                "predicted_tool_ids": [],
                                "ambiguous": False,
                            },
                        ]
                    },
                    CodexInvocation(
                        session_id="contract-session",
                        prompt_template_sha256="a" * 64,
                        request_sha256="b" * 64,
                        elapsed_ms=1.0,
                        codex_version="test",
                    ),
                )

            with (
                patch(
                    "toolroutebench.petai_candidate_labeling.git_commit",
                    return_value="commit",
                ),
                patch(
                    "toolroutebench.petai_candidate_labeling.complete_json",
                    side_effect=fake_complete_json,
                ),
            ):
                manifest_path = run_3i4k_petai_labeling_stage(
                    queue_path=queue_path,
                    queue_manifest_path=queue_manifest_path,
                    output_dir=root / "contract",
                    stage="contract",
                    codex_bin="codex",
                    batch_size=2,
                    timeout_seconds=60,
                )
            self.assertEqual(read_json(manifest_path)["counts"]["records"], 2)
            self.assertNotIn("router_scores", captured_prompts[0])
            self.assertNotIn("0.99", captured_prompts[0])

    def test_reconciliation_accepts_only_exact_non_ambiguous_agreement(self) -> None:
        queue = [
            {"case_id": case_id, "utterance": case_id}
            for case_id in ("call", "normal", "ambiguous", "disagree")
        ]

        def prediction(
            case_id: str,
            tools: list[str],
            ambiguous: bool,
            session: str,
        ) -> dict:
            return {
                "case_id": case_id,
                "predicted_tool_ids": tools,
                "ambiguous": ambiguous,
                "validator": _validator(session),
            }

        contract = [
            prediction("call", ["create_alarm"], False, "contract-1"),
            prediction("normal", [], False, "contract-2"),
            prediction("ambiguous", [], True, "contract-3"),
            prediction("disagree", ["create_timer"], False, "contract-4"),
        ]
        blind = [
            prediction("call", ["create_alarm"], False, "blind-1"),
            prediction("normal", [], False, "blind-2"),
            prediction("ambiguous", [], False, "blind-3"),
            prediction("disagree", [], False, "blind-4"),
        ]
        accepted, unresolved = reconcile_prediction_rows(
            queue=queue,
            contract_predictions=contract,
            blind_predictions=blind,
        )
        self.assertEqual({row["case_id"] for row in accepted}, {"call", "normal"})
        self.assertEqual({row["case_id"] for row in unresolved}, {"ambiguous", "disagree"})
        self.assertTrue(next(row for row in accepted if row["case_id"] == "call")["call"])
        self.assertFalse(
            next(row for row in accepted if row["case_id"] == "normal")["call"]
        )


if __name__ == "__main__":
    unittest.main()
