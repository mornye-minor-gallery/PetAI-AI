import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from beolmuri_eval.annotation import run_batch
from beolmuri_eval.storage import atomic_json


class AnnotationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "prompt.txt").write_text("Label this synthetic utterance.")
        atomic_json(self.root / "schema.json", {"type": "object", "properties": {
            "label": {"type": "string"}}, "required": ["label"], "additionalProperties": False})
        self.plan = self.root / "batch.json"
        atomic_json(self.plan, {"model": "test-model", "reasoning_effort": "medium", "timeout": 5,
            "requests": [{"id": "one", "prompt": "prompt.txt", "schema": "schema.json"}]})
        self.output = self.root / "run"

    def fake_execute(self, args, **kwargs):
        if args[-1] == "--version":
            return "test-cli", ""
        Path(args[args.index("--output-last-message") + 1]).write_text('{"label":"ok"}')
        return '{"type":"turn.completed","usage":{"input_tokens":10}}\n', ""

    @patch("beolmuri_eval.annotation.execute")
    def test_completed_checkpoint_is_not_called_again(self, execute):
        execute.side_effect = self.fake_execute
        self.assertTrue(run_batch(self.plan, self.output)["complete"])
        calls = sum('--output-last-message' in call.args[0] for call in execute.call_args_list)
        self.assertTrue(run_batch(self.plan, self.output, resume=True)["complete"])
        self.assertEqual(sum('--output-last-message' in call.args[0]
                             for call in execute.call_args_list), calls)
        self.assertEqual(json.loads((self.output / "records/one.json").read_text())["answer"], {"label": "ok"})

    @patch("beolmuri_eval.annotation.execute")
    def test_changed_runner_code_cannot_reuse_checkpoint(self, execute):
        execute.side_effect = self.fake_execute
        run_batch(self.plan, self.output)
        with patch("beolmuri_eval.annotation.source_hashes", return_value={"annotation.py": "changed"}):
            with self.assertRaisesRegex(ValueError, "code changed"):
                run_batch(self.plan, self.output, resume=True)

    @patch("beolmuri_eval.annotation.execute")
    def test_changed_codex_version_cannot_reuse_checkpoint(self, execute):
        execute.side_effect = self.fake_execute
        run_batch(self.plan, self.output)
        def changed_version(args, **kwargs):
            if args[-1] == "--version":
                return "different-cli", ""
            return self.fake_execute(args, **kwargs)
        execute.side_effect = changed_version
        with self.assertRaisesRegex(ValueError, "provider changed"):
            run_batch(self.plan, self.output, resume=True)

    @patch("beolmuri_eval.annotation.execute")
    def test_changed_input_cannot_reuse_checkpoint(self, execute):
        execute.side_effect = self.fake_execute
        run_batch(self.plan, self.output)
        (self.root / "prompt.txt").write_text("Changed task")
        with self.assertRaisesRegex(ValueError, "changed"):
            run_batch(self.plan, self.output, resume=True)

    @patch("beolmuri_eval.annotation.execute")
    def test_schema_failure_is_saved_and_explicit_resume_keeps_attempt(self, execute):
        def bad(args, **kwargs):
            out = self.fake_execute(args, **kwargs)
            if "--output-last-message" in args:
                Path(args[args.index("--output-last-message") + 1]).write_text('{"wrong":1}')
            return out
        execute.side_effect = bad
        self.assertFalse(run_batch(self.plan, self.output)["complete"])
        self.assertTrue((self.output / "attempts/one/001/answer.json").exists())
        execute.side_effect = self.fake_execute
        self.assertTrue(run_batch(self.plan, self.output, resume=True)["complete"])
        self.assertTrue((self.output / "attempts/one/002/answer.json").exists())

    @patch("beolmuri_eval.annotation.execute")
    def test_duplicate_ids_fail_before_model_call(self, execute):
        p = json.loads(self.plan.read_text())
        p["requests"] *= 2
        atomic_json(self.plan, p)
        with self.assertRaisesRegex(ValueError, "unique"):
            run_batch(self.plan, self.output)
        execute.assert_not_called()

    @patch("beolmuri_eval.annotation.execute")
    def test_tool_event_cannot_count_as_isolated_annotation(self, execute):
        def with_tool(args, **kwargs):
            stdout, stderr = self.fake_execute(args, **kwargs)
            if "--output-last-message" in args:
                stdout += '{"type":"item.completed","item":{"type":"command_execution"}}\n'
            return stdout, stderr
        execute.side_effect = with_tool
        self.assertFalse(run_batch(self.plan, self.output)["complete"])


if __name__ == "__main__":
    unittest.main()
