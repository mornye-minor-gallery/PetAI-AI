from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from beolmuri_eval.native_worker import NativeRuntime


class NativeWorkerTests(unittest.TestCase):
    def test_gpu_engine_receives_existing_cache_directory(self):
        library = Mock()
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "nested" / "cache"
            def engine(model, **options):
                self.assertTrue(cache.is_dir())
                self.assertEqual(options["backend"], library.Backend.GPU.return_value)
                self.assertFalse(options["enable_speculative_decoding"])
                return Mock()
            library.Engine.side_effect = engine
            with patch.dict("sys.modules", {"litert_lm": library}), patch(
                    "importlib.metadata.version", return_value="0.13.1"):
                runtime = NativeRuntime("model.litertlm", str(cache))
                runtime.close()

    def test_gpu_failure_is_exposed_without_cpu_retry(self):
        library = Mock()
        library.Engine.side_effect = RuntimeError("GPU unavailable")
        with tempfile.TemporaryDirectory() as tmp, patch.dict(
                "sys.modules", {"litert_lm": library}), patch(
                "importlib.metadata.version", return_value="0.13.1"):
            with self.assertRaisesRegex(RuntimeError, "GPU unavailable"):
                NativeRuntime("model.litertlm", tmp)
        self.assertEqual(library.Engine.call_count, 1)
        library.Backend.CPU.assert_not_called()
