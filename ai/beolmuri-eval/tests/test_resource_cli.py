import unittest
from contextlib import redirect_stderr
from io import StringIO

from beolmuri_eval.cli import parser


class ResourceCLIContractTests(unittest.TestCase):
    def test_kv_cache_requires_canonical_content_and_dialogue_turns(self):
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit):
                parser().parse_args([
                    "resource", "kv-cache",
                    "--config", "experiment.yaml",
                    "--device", "device",
                    "--app", "ResourceBench.app",
                ])

        parsed = parser().parse_args([
            "resource", "kv-cache",
            "--config", "experiment.yaml",
            "--device", "device",
            "--app", "ResourceBench.app",
            "--content", "dialogue-content.json",
            "--turns", "turns.json",
        ])
        self.assertEqual(parsed.content, "dialogue-content.json")
        self.assertEqual(parsed.turns, "turns.json")


if __name__ == "__main__":
    unittest.main()
