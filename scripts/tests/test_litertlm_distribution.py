import hashlib
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPARE_SCRIPT = REPO_ROOT / "scripts" / "prepare-ios-native-dependencies.sh"


class LiteRTLMDistributionTests(unittest.TestCase):
    def test_prefill_patch_identity_and_tampering(self) -> None:
        config = subprocess.run([str(PREPARE_SCRIPT), "--print-config"], check=True,
                                capture_output=True, text=True).stdout
        values = dict(line.split("=", 1) for line in config.splitlines())
        patch = REPO_ROOT / "ios/ThirdParty/LiteRTLM/Patches/cpu-prefill-chunk.patch"
        self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(),
                         values["cpu_prefill_patch_sha256"])
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            script = root / "scripts/prepare-ios-native-dependencies.sh"
            script.parent.mkdir()
            shutil.copy2(PREPARE_SCRIPT, script)
            patches = root / "ios/ThirdParty/LiteRTLM/Patches"
            patches.mkdir(parents=True)
            (patches / patch.name).write_text("modified patch\n")
            result = subprocess.run([str(script), "--print-config"], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("CPU prefill patch checksum mismatch", result.stderr)
            self.assertFalse((root / "ios/.artifacts").exists())

    def test_xnnpack_source_and_backport_are_part_of_framework_identity(self) -> None:
        result = subprocess.run([str(PREPARE_SCRIPT), "--print-config"], cwd=REPO_ROOT,
                                check=True, capture_output=True, text=True)
        config = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual("8388bd78690515166d59f1b28e593a455a41d580", config["xnnpack_revision"])
        self.assertEqual("6ebde53e2dc0af6d16e3e2f46f6e9428a76f4356c2e177c5f558c0b4c5cf9e83",
                         config["xnnpack_source_sha256"])
        self.assertEqual("c72e2a4ae0efb7c648f73835e9a0133e7bf21a23", config["xnnpack_backport"])
        patch = REPO_ROOT / "ios/ThirdParty/LiteRTLM/Patches/xnnpack-channelwise-scale.patch"
        self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(), config["xnnpack_patch_sha256"])

    def test_changed_backport_is_rejected_before_build_or_artifact_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            script = root / "scripts/prepare-ios-native-dependencies.sh"
            script.parent.mkdir()
            shutil.copy2(PREPARE_SCRIPT, script)
            patches = root / "ios/ThirdParty/LiteRTLM/Patches"
            patches.mkdir(parents=True)
            shutil.copy2(REPO_ROOT / "ios/ThirdParty/LiteRTLM/Patches/cpu-prefill-chunk.patch",
                         patches / "cpu-prefill-chunk.patch")
            (patches / "xnnpack-channelwise-scale.patch").write_text("changed patch\n")
            result = subprocess.run([str(script), "--print-config"], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("XNNPACK patch checksum mismatch", result.stderr)
            self.assertFalse((root / "ios/.artifacts").exists())

    @unittest.skipUnless(platform.system() == "Darwin", "Native rebuild path requires macOS")
    def test_rebuild_rejects_a_modified_prepared_xnnpack_source(self) -> None:
        config = subprocess.run([str(PREPARE_SCRIPT), "--print-config"], check=True,
                                capture_output=True, text=True).stdout
        values = dict(line.split("=", 1) for line in config.splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "checkout"
            script = root / "scripts/prepare-ios-native-dependencies.sh"
            script.parent.mkdir(parents=True)
            shutil.copy2(PREPARE_SCRIPT, script)
            patches = root / "ios/ThirdParty/LiteRTLM/Patches"
            patches.mkdir(parents=True)
            shutil.copy2(REPO_ROOT / "ios/ThirdParty/LiteRTLM/Patches/cpu-prefill-chunk.patch",
                         patches / "cpu-prefill-chunk.patch")
            shutil.copy2(REPO_ROOT / "ios/ThirdParty/LiteRTLM/Patches/xnnpack-channelwise-scale.patch",
                         patches / "xnnpack-channelwise-scale.patch")
            source = pathlib.Path(temporary) / "shared-source"
            source.mkdir()
            source.joinpath(".petai-checkpoint-source").write_text(
                "\n".join(line for line in config.splitlines() if not line.startswith(("xnnpack_", "cpu_prefill_"))) + "\n")
            xnnpack = root / "ios/.artifacts/sources" / (
                "XNNPACK-" + values["xnnpack_revision"] + "-" + values["xnnpack_patch_sha256"][:12])
            xnnpack.joinpath("src/subgraph").mkdir(parents=True)
            xnnpack.joinpath(".petai-xnnpack-source").write_text(
                "\n".join(line for line in config.splitlines() if line.startswith("xnnpack_")) + "\n")
            xnnpack.joinpath("src/subgraph/unary.c").write_text("modified source\n")
            result = subprocess.run([str(script)], capture_output=True, text=True,
                                    env={**os.environ, "PETAI_LITERTLM_SOURCE_DIR": str(source)})
            self.assertNotEqual(0, result.returncode)
            self.assertIn("XNNPACK source provenance does not match", result.stderr)
            self.assertNotIn("Building native KV checkpoint API", result.stdout)

    def test_public_checkpoint_source_is_pinned(self) -> None:
        result = subprocess.run(
            [str(PREPARE_SCRIPT), "--print-config"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        config = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual("https://github.com/mornye-minor-gallery/LiteRT-LM.git",
                         config["source_repository"])
        self.assertEqual("939b09f5ac92974bb4a7df430d440c2b8780941e",
                         config["source_revision"])
        self.assertRegex(config["source_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual("//swift:CLiteRTLM", config["bazel_target"])
        self.assertEqual("LITERT_LM_FST_CONSTRAINTS_DISABLED=1", config["bazel_define"])

    def test_product_sources_do_not_depend_on_logits_top_k_telemetry(self) -> None:
        roots = [
            REPO_ROOT / "ios",
            REPO_ROOT / "unity" / "Assets" / "PetAI" / "Scripts",
        ]
        forbidden = (
            "TopKTelemetry",
            "topKTelemetry",
            "telemetryCandidateCount",
            "top_k_telemetry",
        )
        matches: list[str] = []

        for root in roots:
            for path in root.rglob("*"):
                if not path.is_file() or path.suffix not in {".swift", ".cs"}:
                    continue
                text = path.read_text(encoding="utf-8")
                for fragment in forbidden:
                    if fragment in text:
                        matches.append(f"{path.relative_to(REPO_ROOT)}: {fragment}")

        self.assertEqual([], matches)


if __name__ == "__main__":
    unittest.main()
