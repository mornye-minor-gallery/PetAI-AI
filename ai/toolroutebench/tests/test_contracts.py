from __future__ import annotations

import unittest

from toolroutebench.authoring import build_plan
from toolroutebench.common import ToolRouteBenchError
from toolroutebench.contracts import (
    load_benchmark_contract,
    load_tool_contract,
    validate_contracts,
    validate_development_dataset,
    validate_holdout_dataset,
    validate_expression_family_partition,
    validate_dataset,
)


class ContractTests(unittest.TestCase):
    def test_frozen_contracts_are_consistent(self) -> None:
        validate_contracts()

    def test_tool_contract_matches_swift_tool_count(self) -> None:
        self.assertEqual(len(load_tool_contract()["tool_order"]), 7)

    def test_pilot_count_is_locked(self) -> None:
        self.assertEqual(load_benchmark_contract()["counts"]["fixed_record_total"], 615)

    def test_expression_family_cannot_cross_splits(self) -> None:
        records = [
            {"expression_family_id": "timer.explicit", "split": "authoring"},
            {"expression_family_id": "timer.explicit", "split": "holdout"},
        ]
        with self.assertRaises(ToolRouteBenchError):
            validate_expression_family_partition(records)

    def test_regression_family_does_not_contaminate_frozen_splits(self) -> None:
        records = [
            {"expression_family_id": "timer.explicit", "split": "dev"},
            {"expression_family_id": "timer.explicit", "split": "regression"},
        ]
        validate_expression_family_partition(records)

    def test_contract_validation_reads_actual_swift_tool_enum(self) -> None:
        validate_contracts()

    def test_dataset_rejects_split_track_mismatch_before_counting(self) -> None:
        record = {
            "case_id": "trb-track-mismatch",
            "dataset_version": "0.1.0",
            "split": "multilabel_challenge",
            "track": "single_tool",
            "expression_family_id": "timer.explicit",
            "difficulty": "direct",
            "utterance": "알람 맞추고 타이머도 시작해줘",
            "gold_tool_ids": ["create_alarm"],
            "style_tags": ["natural_chat"],
            "generation_batch_id": "generation",
            "contract_validation_batch_id": "contract",
            "blind_validation_batch_id": "blind",
            "provenance": {
                "generator": self._invocation(),
                "contract_validator": self._invocation(),
                "blind_validator": self._invocation(),
                "ambiguous": False,
            },
        }
        with self.assertRaises(ToolRouteBenchError):
            validate_dataset([record])

    def test_development_profile_accepts_exact_authoring_and_dev_contract(self) -> None:
        records = self._development_records()
        validate_development_dataset(records)
        self.assertEqual(len(records), 360)

    def test_development_profile_rejects_missing_record(self) -> None:
        records = self._development_records()
        with self.assertRaisesRegex(ToolRouteBenchError, "split counts mismatch"):
            validate_development_dataset(records[:-1])

    def test_holdout_profile_accepts_exact_holdout_contract(self) -> None:
        records = self._records_for_splits({"holdout"})
        validate_holdout_dataset(records)
        self.assertEqual(len(records), 192)

    def _development_records(self) -> list[dict[str, object]]:
        return self._records_for_splits({"authoring", "dev"})

    def _records_for_splits(
        self, included_splits: set[str]
    ) -> list[dict[str, object]]:
        records: list[dict[str, object]] = []
        split_indices = {split: 0 for split in included_splits}
        for task in build_plan()["tasks"]:
            split = task["split"]
            if split not in split_indices:
                continue
            for index in range(task["target_count"]):
                split_indices[split] += 1
                suffix = f"{task['task_id']}.{index:03d}"
                records.append(
                    {
                        "case_id": f"trb-{split}-{split_indices[split]:04d}",
                        "dataset_version": "0.1.0",
                        "split": split,
                        "track": "single_tool",
                        "expression_family_id": suffix,
                        "difficulty": task["difficulty"],
                        "utterance": f"fixture {suffix}",
                        "gold_tool_ids": task["gold_tool_ids"],
                        **(
                            {"contrast_tool_id": task["contrast_tool_id"]}
                            if task.get("contrast_tool_id")
                            else {}
                        ),
                        "style_tags": ["natural_chat"],
                        "generation_batch_id": f"generation-{suffix}",
                        "contract_validation_batch_id": f"contract-{suffix}",
                        "blind_validation_batch_id": f"blind-{suffix}",
                        "provenance": {
                            "generator": self._invocation(f"generator-{suffix}"),
                            "contract_validator": self._invocation(
                                f"contract-{suffix}"
                            ),
                            "blind_validator": self._invocation(f"blind-{suffix}"),
                            "ambiguous": False,
                        },
                    }
                )
        return records

    @staticmethod
    def _invocation(session_id: str = "test-session") -> dict[str, str]:
        return {
            "interface": "codex_cli",
            "model": "gpt-5.6-sol",
            "reasoning_effort": "medium",
            "prompt_template_sha256": "0" * 64,
            "request_sha256": "1" * 64,
            "session_id": session_id,
        }


if __name__ == "__main__":
    unittest.main()
