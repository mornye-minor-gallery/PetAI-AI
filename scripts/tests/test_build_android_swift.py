import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "build-android-swift.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("build_android_swift", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class AndroidSwiftBuildTests(unittest.TestCase):
    def test_c_sources_use_a_generic_build_path(self):
        scratch = Path("/private/workspace/swift-scratch")
        self.assertEqual(BUILD.c_source_path_map(scratch),
                         "-ffile-prefix-map=/private/workspace/swift-scratch=/petai-build")

    def test_shared_bridge_is_stripped_and_rejects_private_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            strip = root / "toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
            strip.parent.mkdir(parents=True)
            strip.touch()
            library = root / "libPetAIAndroid.so"
            library.write_bytes(b"Linker: /Volumes/Android/buildbot/src/llvm")
            with patch.object(BUILD.subprocess, "run") as run:
                BUILD.finalize_shared_bridge(library, root)
                run.assert_called_once_with([str(strip), "--strip-unneeded", str(library)], check=True)
            library.write_bytes(b"/Volumes/private/workspace/source.cc")
            with patch.object(BUILD.subprocess, "run"):
                with self.assertRaisesRegex(ValueError, "private build path"):
                    BUILD.finalize_shared_bridge(library, root)


if __name__ == "__main__":
    unittest.main()
