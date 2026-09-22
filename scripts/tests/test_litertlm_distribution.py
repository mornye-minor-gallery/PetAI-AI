import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPARE_SCRIPT = REPO_ROOT / "scripts" / "prepare-ios-native-dependencies.sh"


class LiteRTLMDistributionTests(unittest.TestCase):
    def test_official_stable_release_is_pinned(self) -> None:
        result = subprocess.run(
            [str(PREPARE_SCRIPT), "--print-config"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertIn("source_repository=https://github.com/google-ai-edge/LiteRT-LM.git", result.stdout)
        self.assertIn("release_tag=v0.17.1", result.stdout)
        self.assertIn(
            "release_url=https://github.com/google-ai-edge/LiteRT-LM/releases/download/"
            "v0.17.1/CLiteRTLM.xcframework.zip",
            result.stdout,
        )

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
