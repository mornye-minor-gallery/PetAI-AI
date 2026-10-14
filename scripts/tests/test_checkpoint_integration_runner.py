import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_checkpoint_integration as runner


class CheckpointRunnerTests(unittest.TestCase):
    def test_backend_and_context_are_explicit_worker_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "cold.json").write_text(json.dumps({"backend": "gpu", "contextTokens": 8192, "output": "hello"}))
            process = Mock(returncode=0)
            process.poll.return_value = 0
            with patch.object(runner.subprocess, "Popen", return_value=process) as launch:
                runner.run(Path("worker"), Path("model"), root, "next", "cold", "gpu", 8192)
            self.assertEqual(launch.call_args.args[0][-2:], ["gpu", "8192"])

    def test_wrong_backend_empty_output_and_wrong_context_fail(self):
        for result in [
            {"backend": "cpu", "contextTokens": 8192, "output": "hello"},
            {"backend": "gpu", "contextTokens": 8192, "output": ""},
            {"backend": "gpu", "contextTokens": 4096, "output": "hello"},
        ]:
            with self.subTest(result=result), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "cold.json").write_text(json.dumps(result))
                process = Mock(returncode=0)
                process.poll.return_value = 0
                with patch.object(runner.subprocess, "Popen", return_value=process):
                    with self.assertRaises(ValueError):
                        runner.run(Path("worker"), Path("model"), root, "next", "cold", "gpu", 8192)


if __name__ == "__main__":
    unittest.main()
