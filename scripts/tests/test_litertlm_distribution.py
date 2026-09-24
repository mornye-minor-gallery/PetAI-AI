import pathlib
import re
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPARE_SCRIPT = REPO_ROOT / "scripts" / "prepare-ios-native-dependencies.sh"


class LiteRTLMDistributionTests(unittest.TestCase):
    def test_engine_state_transfer_has_no_app_or_file_policy(self) -> None:
        patch = (REPO_ROOT / "ios/ThirdParty/LiteRTLM/native/kv-checkpoint.patch").read_text()
        additions = "\n".join(line[1:] for line in patch.splitlines()
                              if line.startswith("+") and not line.startswith("+++"))
        for forbidden in ("<cstdio>", "<unistd.h>", "<fcntl.h>", "FILE*", "fopen(",
                          "fsync(", "rename(", "unlink(", "PETAI_", "identity", "SHA256"):
            self.assertNotIn(forbidden, additions)
        self.assertIn("litert_lm_session_transfer_state", additions)

    def test_native_patches_do_not_change_comments(self) -> None:
        for path in (REPO_ROOT / "ios/ThirdParty/LiteRTLM/native").glob("*.patch"):
            for line in path.read_text().splitlines():
                if line.startswith(("---", "+++")) or not line.startswith(("+", "-")):
                    continue
                code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line[1:])
                self.assertNotIn("//", code, (path.name, line))
                self.assertNotIn("/*", code, (path.name, line))

    def test_checkpoint_source_and_patch_are_pinned(self) -> None:
        result = subprocess.run(
            [str(PREPARE_SCRIPT), "--print-config"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("source_repository=https://github.com/google-ai-edge/LiteRT-LM.git", result.stdout)
        self.assertIn("source_revision=a327b494f874a319605e6fd7e3439678daa4d07d", result.stdout)
        import hashlib
        patch = REPO_ROOT / "ios/ThirdParty/LiteRTLM/native/kv-checkpoint.patch"
        self.assertIn("patch_sha256=" + hashlib.sha256(patch.read_bytes()).hexdigest(), result.stdout)
        patch = REPO_ROOT / "ios/ThirdParty/LiteRTLM/native/pending-prefill.patch"
        self.assertIn("prefill_patch_sha256=" + hashlib.sha256(patch.read_bytes()).hexdigest(), result.stdout)

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
