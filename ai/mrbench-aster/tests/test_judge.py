import argparse
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from codex_cli_adapter import codex_cli_completion  # noqa: E402
from run_judge import (  # noqa: E402
    build_judge_prompt,
    index_results,
    parse_judge_json,
    validate_backend_args,
    validate_pair_manifests,
)


class JudgeTests(unittest.TestCase):
    def test_parse_judge_json(self):
        score, rationale = parse_judge_json('{"score": 8, "rationale": "경계를 잘 지켰다."}')
        self.assertEqual(score, 8.0)
        self.assertEqual(rationale, "경계를 잘 지켰다.")

    def test_parse_fenced_judge_json(self):
        score, _ = parse_judge_json('```json\n{"score": 7.5, "rationale": "대체로 자연스럽다."}\n```')
        self.assertEqual(score, 7.5)

    def test_reject_duplicate_case_ids(self):
        with self.assertRaises(ValueError):
            index_results([{"case_id": "x"}, {"case_id": "x"}])

    def test_validate_pair_manifests(self):
        controlled = {
            "status": "completed",
            "dataset_sha256": "data",
            "persona_format": "mrprompt",
            "model_id": "gemma-4-e2b-it",
            "model_artifact_sha256": "model",
            "runtime": "litert-lm",
            "runtime_version": "0.0",
            "backend": "cpu",
            "temperature": 0.7,
            "max_tokens": 256,
        }
        primary = {**controlled, "memory_condition": "full"}
        comparison = {**controlled, "memory_condition": "anti"}
        validate_pair_manifests(primary, comparison, metric="MS-FA")

    def test_reject_wrong_pair_condition(self):
        primary = {"status": "completed", "memory_condition": "full"}
        comparison = {"status": "completed", "memory_condition": "no_scene"}
        with self.assertRaises(ValueError):
            validate_pair_manifests(primary, comparison, metric="MS-FA")

    def test_codex_cli_adapter_uses_pinned_execution_contract(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            schema = temporary / "schema.json"
            schema.write_text("{}\n", encoding="utf-8")

            def fake_run(command, **kwargs):
                output_path = Path(command[command.index("--output-last-message") + 1])
                output_path.write_text(
                    '{"score": 9, "rationale": "캐릭터성이 유지됐다."}\n',
                    encoding="utf-8",
                )
                self.assertIn("--ephemeral", command)
                self.assertIn("--ignore-user-config", command)
                self.assertIn("--ignore-rules", command)
                self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
                self.assertEqual(command[command.index("--model") + 1], "gpt-5.6-luna")
                self.assertIn('model_reasoning_effort="low"', command)
                self.assertEqual(kwargs["input"], "judge this")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch("codex_cli_adapter.subprocess.run", side_effect=fake_run):
                content, usage, timing = codex_cli_completion(
                    prompt="judge this",
                    model="gpt-5.6-luna",
                    reasoning_effort="low",
                    output_schema=schema,
                    codex_bin="codex",
                    working_directory=temporary,
                    timeout_seconds=30,
                )
        self.assertIn('"score": 9', content)
        self.assertEqual(usage, {})
        self.assertGreaterEqual(timing["elapsed_ms"], 0)

    def test_openai_backend_requires_base_url(self):
        args = argparse.Namespace(backend="openai-compatible", base_url=None)
        with self.assertRaises(ValueError):
            validate_backend_args(args)

    def test_mb_judge_prompt_includes_controlled_pair(self):
        case = {
            "ability": "MB",
            "boundary_type": "future_timeline",
            "dialogue": [{"role": "user", "content": "내일은?"}],
            "paired_final_turns": {"in_scope": "지금은?", "out_of_scope": "내일은?"},
            "expected": {"forbidden_answer_claims": ["미래를 안다"]},
        }
        prompt = build_judge_prompt(
            metric="MB-AL",
            rubric="RUBRIC",
            persona={"identity": {"name": "아스테르"}},
            case=case,
            primary={"response": "그건 아직 몰라."},
            comparison=None,
        )
        self.assertIn('"in_scope": "지금은?"', prompt)
        self.assertIn('"boundary_type": "future_timeline"', prompt)

    def test_me_ability_filter_contract_is_recordable(self):
        cases = {
            "ms": {"ability": "MS", "metrics": ["ME-HLE"]},
            "mb": {"ability": "MB", "metrics": ["ME-HLE"]},
        }
        primary = {"ms": {}, "mb": {}}
        selected = [
            case_id
            for case_id, case in cases.items()
            if "ME-HLE" in case["metrics"]
            and case_id in primary
            and case["ability"] == "MS"
        ]
        self.assertEqual(selected, ["ms"])


if __name__ == "__main__":
    unittest.main()
