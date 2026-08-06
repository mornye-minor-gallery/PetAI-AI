import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from common import FORMATS, load_jsonl  # noqa: E402
from run_generation import build_requests, parse_args, select_cases_for_condition  # noqa: E402


class GenerationTests(unittest.TestCase):
    def test_compact_is_a_versioned_prompt_format(self):
        self.assertIn("compact", FORMATS)

    def test_build_requests_preserves_case_contract(self):
        cases = load_jsonl(ROOT / "data/evaluation.jsonl")
        requests = build_requests(
            cases[:2],
            system_prompt="SYSTEM",
            persona_format="mrprompt",
            memory_condition="full",
        )
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0]["messages"][0], {"role": "system", "content": "SYSTEM"})
        self.assertEqual(requests[0]["messages"][-1]["role"], "user")
        self.assertEqual(requests[0]["persona_format"], "mrprompt")
        self.assertEqual(requests[0]["memory_condition"], "full")
        self.assertEqual(requests[0]["ability"], "MS")
        self.assertEqual(requests[0]["facet_hint_mode"], "none")

    def test_oracle_hint_is_injected_only_for_ms(self):
        cases = [
            {
                "case_id": "ms",
                "ability": "MS",
                "facet_id": "playful_exchange",
                "metrics": ["MS-FA"],
                "dialogue": [{"role": "user", "content": "장난이야"}],
            },
            {
                "case_id": "mb",
                "ability": "MB",
                "boundary_type": "future_timeline",
                "metrics": ["MB-AL"],
                "dialogue": [{"role": "user", "content": "내일은?"}],
            },
        ]
        requests = build_requests(
            cases,
            system_prompt="SYSTEM",
            persona_format="mrprompt",
            memory_condition="full",
            inject_facet_hint=True,
        )
        self.assertIn("playful_exchange", requests[0]["messages"][0]["content"])
        self.assertEqual(requests[0]["facet_hint_mode"], "evaluation_oracle_id")
        self.assertEqual(requests[1]["messages"][0]["content"], "SYSTEM")
        self.assertEqual(requests[1]["facet_hint_mode"], "none")

    def test_oracle_card_injects_behavior_not_expected_contract(self):
        case = {
            "case_id": "ms",
            "ability": "MS",
            "facet_id": "ambiguous_direction",
            "metrics": ["MS-FA"],
            "dialogue": [{"role": "user", "content": "A일까 B일까?"}],
            "expected": {"required_behaviors": ["secret evaluation text"]},
        }
        request = build_requests(
            [case],
            system_prompt="SYSTEM",
            persona_format="mrprompt",
            memory_condition="full",
            inject_facet_card=True,
        )[0]
        system_prompt = request["messages"][0]["content"]
        self.assertIn("사용자가 제시한 두 가능성", system_prompt)
        self.assertNotIn("secret evaluation text", system_prompt)
        self.assertEqual(request["facet_hint_mode"], "evaluation_oracle_card")

    def test_non_full_conditions_select_only_ms_cases(self):
        cases = [{"ability": "MS"}, {"ability": "MB"}]
        self.assertEqual(select_cases_for_condition(cases, "full"), cases)
        self.assertEqual(select_cases_for_condition(cases, "anti"), [cases[0]])
        self.assertEqual(select_cases_for_condition(cases, "no_scene"), [cases[0]])

    def test_versioned_prompt_file_arguments_parse(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            prompt = Path(temporary_directory) / "candidate.md"
            with mock.patch.object(
                sys,
                "argv",
                [
                    "run_generation.py",
                    "--base-url", "http://127.0.0.1:9379/v1",
                    "--model", "model",
                    "--runtime", "runtime",
                    "--backend", "gpu",
                    "--prompt-file", str(prompt),
                    "--prompt-id", "candidate-v1",
                    "--memory-condition", "full",
                    "--output-dir", str(Path(temporary_directory) / "out"),
                ],
            ):
                arguments = parse_args()
        self.assertEqual(arguments.prompt_id, "candidate-v1")


if __name__ == "__main__":
    unittest.main()
