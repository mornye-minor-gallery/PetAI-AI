import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import litertlm_prefix_cursor as native
import litertlm_android_profile as profile


class AndroidGpuDistributionTests(unittest.TestCase):
    def fixture(self, root, backend):
        for name in ("liblitert-lm.so", "libPetAIAndroid.so", "libLiteRt.so", *profile.GPU_LIBRARIES):
            (root / name).write_bytes(name.encode())
        digests = {name: native.sha(root / name) for name in profile.GPU_LIBRARIES}
        with patch.dict(profile.GPU_LIBRARIES, digests):
            native.write_android_manifest(root, backend)
        bundle = root / "EdgeLLM_EdgeLLM.bundle"
        bundle.mkdir()
        (bundle / "fixture.json").write_text("{}")
        (root / "libPetAIAndroid.provenance.json").write_text(json.dumps({
            "backend": backend, "native_manifest_sha256": native.sha(root / "liblitert-lm.provenance.json"),
            "bridge_sha256": native.sha(root / "libPetAIAndroid.so"),
            "resources": {"fixture.json": native.sha(bundle / "fixture.json")}}))
        return digests

    def test_cpu_and_gpu_both_verify_with_matching_swift_resources(self):
        for backend in ("cpu", "gpu"):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                digests = self.fixture(root, backend)
                with patch.dict(profile.GPU_LIBRARIES, digests):
                    native.verify_android_product(root, backend)
                    with self.assertRaisesRegex(ValueError, "backend mismatch"):
                        native.verify_android_product(root, "gpu" if backend == "cpu" else "cpu")

    def test_changed_bridge_resources_or_gpu_library_are_rejected(self):
        for name in ("libPetAIAndroid.so", "libLiteRt.so", "libLiteRtOpenClAccelerator.so",
                     "EdgeLLM_EdgeLLM.bundle/fixture.json"):
            with self.subTest(file=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                digests = self.fixture(root, "gpu")
                (root / name).write_bytes(b"changed")
                with patch.dict(profile.GPU_LIBRARIES, digests), self.assertRaises(ValueError):
                    native.verify_android_product(root, "gpu")

    def test_gpu_manifest_must_include_every_runtime_dependency(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            digests = self.fixture(root, "gpu")
            path = root / "liblitert-lm.provenance.json"
            manifest = json.loads(path.read_text())
            manifest["libraries"].pop("libLiteRt.so")
            path.write_text(json.dumps(manifest))
            with patch.dict(profile.GPU_LIBRARIES, digests), self.assertRaisesRegex(ValueError, "libraries missing"):
                native.verify_android(root)

    def test_new_engine_cannot_use_old_swift_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root, "cpu")
            (root / "liblitert-lm.so").write_bytes(b"new engine")
            native.write_android_manifest(root)
            with self.assertRaisesRegex(ValueError, "Swift/native profile mismatch"):
                native.verify_android_product(root, "cpu")


if __name__ == "__main__": unittest.main()
