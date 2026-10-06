from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.evaluation import load_plan
from beolmuri_eval.runner import run
from beolmuri_eval.storage import atomic_json, records


class FakeWorker:
    generations = 0

    def __init__(self, *args):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def call(self, operation, **kwargs):
        if operation == "load":
            assert kwargs["max_num_tokens"] == 8096
            return {"load_ms": 1}
        if operation == "prepare":
            assert kwargs["memories"] == ["산책을 좋아한다."]
            return {"model_input": {"messages": [{"role": "system", "text": "system"},
                        {"role": "user", "text": "user"}]}, "sampling": {}}
        if operation == "start_input":
            return {"status": "started", "message": kwargs["model_input"]["messages"][-1]["text"]}
        if operation == "generate":
            self.__class__.generations += 1
            return {"chunks": ["나는 엘레나야."]}
        if operation == "process":
            return {"status": "processed", "visible_text": "나는 엘레나야."}
        return {"status": "started"}


class RunnerTests(unittest.TestCase):
    def test_judge_failure_checkpoint_does_not_regenerate_on_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = {"run_id": "test", "timeout_seconds": 2, "cases": load_plan(limit_pairs=1).cases[:1], "repeats": 1,
                        "variant": "baseline", "configuration": load_plan().configuration,
                        "runtime": {"max_num_tokens": 8096}, "memories": ["산책을 좋아한다."],
                        "input_files": {}, "litert_python": "python", "model": {"path": "model"}, "judge": {"codex": "codex"}}
            atomic_json(directory / "manifest.json", manifest)
            FakeWorker.generations = 0
            with patch("beolmuri_eval.runner.Worker", FakeWorker):
                with patch("beolmuri_eval.runner.grade", side_effect=RuntimeError("judge unavailable")):
                    self.assertFalse(run(directory)["complete"])
                self.assertEqual(records(directory)[0]["status"], "judge_error")
                self.assertEqual(FakeWorker.generations, 1)
                judgment = {"label": "identity_maintained", "incorrect_name_correction": None,
                            "evidence": "엘레나", "reason": "test fixture"}
                with patch("beolmuri_eval.runner.verify_snapshot"), patch("beolmuri_eval.runner.validate_resume"), patch("beolmuri_eval.runner.grade", return_value=(judgment, {})):
                    self.assertTrue(run(directory, resume=True)["complete"])
                self.assertEqual(FakeWorker.generations, 1)
                self.assertEqual(len(records(directory)[0]["attempts"]), 1)

    def test_changed_sources_cannot_resume(self):
        from beolmuri_eval.runner import validate_resume
        with patch("beolmuri_eval.runner.source_sha", return_value="new"):
            with self.assertRaisesRegex(ValueError, "changed"):
                validate_resume({"source_sha256": "old"}, Path("."))

    def test_cancellation_during_resume_validation_is_not_discarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            atomic_json(directory / "manifest.json", {"run_id": "test", "timeout_seconds": 2,
                                                       "cases": [], "repeats": 1, "input_files": {}})
            def validate(*args):
                atomic_json(directory / "cancel.request", {"requested": True})
            with patch("beolmuri_eval.runner.verify_snapshot"), patch("beolmuri_eval.runner.validate_resume", side_effect=validate):
                with self.assertRaises(KeyboardInterrupt):
                    run(directory, resume=True)
            from beolmuri_eval.storage import read_json
            self.assertEqual(read_json(directory / "state.json")["state"], "interrupted")
