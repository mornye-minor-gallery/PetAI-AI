from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from toolroutebench.authoring import build_plan, build_validator_prompt, write_plan
from toolroutebench.common import read_json, sha256_file, write_json
from toolroutebench.manifests import write_run_manifest
from toolroutebench.runner import assign_oof_folds, candidate_grid, tune_candidate


class AuthoringRunnerTests(unittest.TestCase):
    def test_authoring_plan_is_exactly_615_records(self) -> None:
        plan = build_plan()
        self.assertEqual(plan["target_record_count"], 615)
        self.assertEqual(sum(task["target_count"] for task in plan["tasks"]), 615)
        self.assertEqual(
            sum(
                task["target_count"]
                for task in plan["tasks"]
                if task["split"] == "multilabel_challenge"
            ),
            63,
        )

    def test_plan_writer_round_trips_machine_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            write_plan(path)
            self.assertEqual(read_json(path)["target_record_count"], 615)

    def test_validator_prompt_does_not_reveal_intended_labels(self) -> None:
        prompt = build_validator_prompt(
            [
                {
                    "candidate_id": "candidate-1",
                    "utterance": "10초 타이머 맞춰줘",
                    "gold_tool_ids": ["create_timer"],
                    "difficulty": "direct",
                }
            ],
            stage="blind",
        )
        self.assertIn("10초 타이머 맞춰줘", prompt)
        self.assertNotIn("gold_tool_ids", prompt)
        self.assertNotIn("difficulty", prompt)

    def test_candidate_grid_has_only_33_compatible_candidates(self) -> None:
        grid = candidate_grid()
        self.assertEqual(len(grid), 33)
        self.assertEqual(
            len(
                {
                    (
                        item["representation"],
                        item["aggregation"],
                        item["normal_decision"],
                        item["threshold_structure"],
                    )
                    for item in grid
                }
            ),
            33,
        )
        for item in grid:
            if item["normal_decision"] == "positive_vs_normal_margin":
                self.assertEqual(
                    item["representation"], "utterance_prototype_vs_normal"
                )

    def test_all_threshold_structures_produce_training_and_oof_metrics(self) -> None:
        tools = [
            "get_step_count",
            "create_alarm",
            "list_alarms",
            "create_timer",
            "schedule_local_notification",
            "get_calendar_events",
            "create_calendar_event",
        ]
        records = []
        scores = {}
        for index in range(20):
            case_id = f"trb-dev-{index:04d}"
            gold = [tools[index % len(tools)]] if index < 14 else []
            records.append(
                {
                    "case_id": case_id,
                    "expression_family_id": f"family-{index:04d}",
                    "gold_tool_ids": gold,
                }
            )
            scores[case_id] = {
                tool: (0.9 if tool in gold else 0.1 + tool_index * 0.001)
                for tool_index, tool in enumerate(tools)
            }
        for structure in (
            "single_global",
            "raw_per_tool",
            "cv_shrunk_per_tool",
        ):
            thresholds, training, oof, assignments = tune_candidate(
                records, scores, structure, cv_folds=5, shrinkage=0.5
            )
            self.assertEqual(set(thresholds), set(tools))
            self.assertEqual(training["record_count"], 20)
            self.assertEqual(oof["record_count"], 20)
            self.assertEqual(set(assignments), {row["case_id"] for row in records})

    def test_oof_folds_keep_expression_families_together(self) -> None:
        records = [
            {
                "case_id": "case-a1",
                "expression_family_id": "family-a",
                "gold_tool_ids": ["create_alarm"],
            },
            {
                "case_id": "case-a2",
                "expression_family_id": "family-a",
                "gold_tool_ids": ["create_alarm"],
            },
            {
                "case_id": "case-b",
                "expression_family_id": "family-b",
                "gold_tool_ids": ["create_timer"],
            },
            {
                "case_id": "case-c",
                "expression_family_id": "family-c",
                "gold_tool_ids": [],
            },
            {
                "case_id": "case-d",
                "expression_family_id": "family-d",
                "gold_tool_ids": [],
            },
        ]
        first = assign_oof_folds(records, 2)
        second = assign_oof_folds(list(reversed(records)), 2)
        self.assertEqual(first, second)
        self.assertEqual(first["case-a1"], first["case-a2"])
        self.assertEqual(set(first), {row["case_id"] for row in records})

    def test_oof_rejects_mixed_labels_in_one_expression_family(self) -> None:
        records = [
            {
                "case_id": "case-a",
                "expression_family_id": "shared-family",
                "gold_tool_ids": ["create_alarm"],
            },
            {
                "case_id": "case-b",
                "expression_family_id": "shared-family",
                "gold_tool_ids": [],
            },
        ]
        with self.assertRaisesRegex(RuntimeError, "different gold labels"):
            assign_oof_folds(records, 2)

    def test_run_manifest_records_exact_embedding_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            embeddings = root / "embeddings.jsonl"
            dataset = root / "dev.jsonl"
            result = root / "dev_results.json"
            embeddings.write_text("{}\n", encoding="utf-8")
            dataset.write_text("{}\n", encoding="utf-8")
            result.write_text("{}\n", encoding="utf-8")
            write_json(
                root / "embedding_manifest.json",
                {
                    "created_at": "2026-08-08T00:00:00Z",
                    "output": {"sha256": sha256_file(embeddings)},
                    "model": {
                        "id": "embeddinggemma-300m-seq256",
                        "sha256": "1" * 64,
                    },
                    "tokenizer": {
                        "id": "embeddinggemma-300m-sentencepiece",
                        "sha256": "2" * 64,
                    },
                    "runtime": {
                        "name": "ai-edge-litert",
                        "version": "2.1.3",
                        "backend": "cpu",
                    },
                },
            )
            with patch(
                "toolroutebench.manifests.git_commit", return_value="a" * 40
            ):
                manifest = write_run_manifest(
                    output_path=root / "run_manifest.json",
                    track="dev",
                    candidate_id="embedding-grid-33",
                    dataset_path=dataset,
                    embeddings_path=embeddings,
                    result_path=result,
                )
            self.assertEqual(read_json(manifest)["models"][0]["artifact_sha256"], "1" * 64)


if __name__ == "__main__":
    unittest.main()
