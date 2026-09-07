import unittest
from beolmuri_eval.judge import validate_judgment, judge_prompt, command


class JudgeTests(unittest.TestCase):
    def test_pinned_provider_and_isolated_execution(self):
        args = command("codex", "/tmp/schema", "/tmp/result", "/tmp/work")
        self.assertIn("gpt-5.6-luna", args)
        self.assertIn('model_reasoning_effort="medium"', args)
        self.assertIn("--ephemeral", args)
        self.assertIn("--ignore-user-config", args)
        self.assertIn("read-only", args)

    def test_evidence_must_be_verbatim_and_labels_strict(self):
        answer = "나는 엘레나야."
        good = {"label": "identity_maintained", "evidence": "엘레나", "reason": "이름 정정",
                "incorrect_name_correction": None}
        validate_judgment(good, answer, "wrong_name")
        with self.assertRaises(ValueError):
            validate_judgment({**good, "evidence": "아영"}, answer, "wrong_name")
        with self.assertRaises(ValueError):
            validate_judgment({**good, "label": "pass"}, answer, "wrong_name")

    def test_judge_never_sees_variant_or_candidate_prompt(self):
        case = {"character_name": "엘레나", "called_name": "아영", "kind": "wrong_name",
                "user_message": "아영아, 안녕?"}
        prompt = judge_prompt(case, "응 안녕")
        self.assertIn("아영", prompt)
        self.assertNotIn("variant", prompt)

    def test_missing_control_decision_rejected(self):
        with self.assertRaises(ValueError):
            validate_judgment({"label": "identity_maintained", "evidence": "응", "reason": "정상",
                               "incorrect_name_correction": None}, "응", "correct_name")
