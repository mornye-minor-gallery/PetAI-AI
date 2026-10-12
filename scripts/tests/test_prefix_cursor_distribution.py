import importlib.util
import pathlib
import json
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cursor", ROOT / "scripts/litertlm_prefix_cursor.py")
cursor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cursor)


class PrefixCursorDistributionTests(unittest.TestCase):
    def make_ios_fixture(self, root):
        config = subprocess.run(["bash", str(ROOT / "scripts/prepare-ios-native-dependencies.sh"),
                                 "--print-config"], check=True, capture_output=True, text=True).stdout
        (root / "CLiteRTLM.provenance").write_text(config)
        lines = []
        for arch in ("ios-arm64", "ios-arm64-simulator"):
            name = f"CLiteRTLM.xcframework/{arch}/CLiteRTLM.framework/CLiteRTLM"
            binary = root / name
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixture framework slice")
            lines.append(f"{cursor.sha(binary)}  {name}")
        (root / "CLiteRTLM.binary-sha256").write_text("\n".join(lines) + "\n")

    def test_patch_hash_matches_identity(self):
        self.assertEqual(cursor.PATCH_SHA, cursor.sha(cursor.PATCH))

    def test_ios_artifact_identity_contains_cursor_fix(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/prepare-ios-native-dependencies.sh"),
                                 "--print-config"], capture_output=True, text=True, check=True)
        self.assertIn("prefix_cursor_patch_sha256=" + cursor.PATCH_SHA, result.stdout)

    def test_unrecognized_source_is_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            target = source / cursor.RELATIVE
            target.parent.mkdir(parents=True)
            target.write_text("unrecognized source")
            with self.assertRaises(ValueError):
                cursor.prepare(source)
            self.assertEqual("unrecognized source", target.read_text())

    def test_android_missing_or_stale_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaises((ValueError, FileNotFoundError)):
                cursor.verify_android(root)
            (root / "liblitert-lm.so").write_bytes(b"test engine")
            cursor.write_android_manifest(root)
            cursor.verify_android(root)
            (root / "liblitert-lm.so").write_bytes(b"different engine")
            with self.assertRaises(ValueError):
                cursor.verify_android(root)

    def test_android_old_patch_identity_is_rejected_even_with_correct_binary_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "liblitert-lm.so").write_bytes(b"test engine")
            cursor.write_android_manifest(root)
            path = root / "liblitert-lm.provenance.json"
            manifest = json.loads(path.read_text())
            manifest["prefix_cursor_patch_sha256"] = "old patch"
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "prefix_cursor_patch_sha256"):
                cursor.verify_android(root)

    def test_ios_current_identity_and_slices_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_ios_fixture(root)
            cursor.verify_ios(root)

    def test_android_bridge_and_resources_must_match_native_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "liblitert-lm.so").write_bytes(b"engine")
            (root / "libPetAIAndroid.so").write_bytes(b"bridge")
            bundle = root / "EdgeLLM_EdgeLLM.bundle"
            bundle.mkdir()
            resource = bundle / "slm-runtime-defaults.json"
            resource.write_text("{}")
            cursor.write_android_manifest(root)
            bridge = {"backend": "cpu",
                      "native_manifest_sha256": cursor.sha(root / "liblitert-lm.provenance.json"),
                      "bridge_sha256": cursor.sha(root / "libPetAIAndroid.so"),
                      "resources": {resource.name: cursor.sha(resource)}}
            (root / "libPetAIAndroid.provenance.json").write_text(json.dumps(bridge))
            cursor.verify_android_product(root, "cpu")
            resource.write_text('{"changed":true}')
            with self.assertRaisesRegex(ValueError, "resources mismatch"):
                cursor.verify_android_product(root, "cpu")
            resource.write_text("{}")
            (root / "libPetAIAndroid.so").write_bytes(b"different bridge")
            with self.assertRaisesRegex(ValueError, "bridge binary checksum"):
                cursor.verify_android_product(root, "cpu")
            (root / "libPetAIAndroid.so").write_bytes(b"bridge")
            (root / "liblitert-lm.so").write_bytes(b"different engine")
            cursor.write_android_manifest(root)
            with self.assertRaisesRegex(ValueError, "Swift/native profile mismatch"):
                cursor.verify_android_product(root, "cpu")

    def test_ios_old_framework_provenance_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_ios_fixture(root)
            path = root / "CLiteRTLM.provenance"
            path.write_text("\n".join(line for line in path.read_text().splitlines()
                                      if not line.startswith("prefix_cursor_")) + "\n")
            with self.assertRaisesRegex(ValueError, "provenance mismatch"):
                cursor.verify_ios(root)

    def test_ios_changed_binary_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_ios_fixture(root)
            (root / "CLiteRTLM.xcframework/ios-arm64/CLiteRTLM.framework/CLiteRTLM").write_bytes(b"old binary")
            with self.assertRaisesRegex(ValueError, "binary checksum mismatch"):
                cursor.verify_ios(root)

    def test_ios_incomplete_binary_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_ios_fixture(root)
            (root / "CLiteRTLM.binary-sha256").write_text("")
            with self.assertRaisesRegex(ValueError, "both expected slices"):
                cursor.verify_ios(root)


if __name__ == "__main__":
    unittest.main()
