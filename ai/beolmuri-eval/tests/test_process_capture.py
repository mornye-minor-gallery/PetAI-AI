import sys
import tempfile
from pathlib import Path
import unittest
from beolmuri_eval.process import execute

class CaptureTests(unittest.TestCase):
    def test_failed_exit_retains_both_streams(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RuntimeError):
                execute([sys.executable, '-c', 'import sys; print("partial"); print("cause",file=sys.stderr); sys.exit(2)'], capture_directory=d)
            self.assertEqual((Path(d)/'stdout.jsonl').read_text(), 'partial\n')
            self.assertEqual((Path(d)/'stderr.txt').read_text(), 'cause\n')

    def test_timeout_retains_partial_stdout(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(TimeoutError):
                execute([sys.executable, '-c', 'import time; print("partial",flush=True); time.sleep(5)'], timeout=0.2, capture_directory=d)
            self.assertEqual((Path(d)/'stdout.jsonl').read_text(), 'partial\n')

    def test_capture_is_optional(self):
        self.assertEqual(execute([sys.executable,'-c','print("ok")']),('ok\n',''))
