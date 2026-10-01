import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from beolmuri_eval.storage import atomic_json, read_json, run_lock, active
from beolmuri_eval.process import execute, Worker


class StorageProcessTests(unittest.TestCase):
    def test_lock_observes_actual_owner_and_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self.assertFalse(active(directory))
            with self.assertRaises(RuntimeError):
                with run_lock(directory):
                    self.assertTrue(active(directory))
                    with run_lock(directory):
                        pass
            self.assertFalse(active(directory))

    def test_atomic_record_replaces_previous_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "records/turn.json"
            atomic_json(path, {"status": "generated"})
            atomic_json(path, {"status": "graded"})
            self.assertEqual(read_json(path), {"status": "graded"})
            self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_timeout_is_observable(self):
        with self.assertRaises(TimeoutError):
            execute([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)

    def test_worker_rejects_wrong_request_id(self):
        script = 'import json,sys; x=json.loads(input()); print(json.dumps({"id":"wrong","protocol_version":1}))'
        with tempfile.TemporaryDirectory() as tmp:
            with Worker([sys.executable, "-c", script], Path(tmp) / "worker.log") as worker:
                with self.assertRaisesRegex(ValueError, "mismatch"):
                    worker.call("probe", timeout=2)
