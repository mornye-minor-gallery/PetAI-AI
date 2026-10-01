import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPARE_SCRIPT = REPO_ROOT / "scripts" / "prepare-ios-native-dependencies.sh"


class LiteRTLMDistributionTests(unittest.TestCase):
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
