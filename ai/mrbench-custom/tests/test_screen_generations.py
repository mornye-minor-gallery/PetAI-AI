import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from screen_generations import f1_score, screen_run  # noqa: E402


class ScreenGenerationTests(unittest.TestCase):
    def test_f1_score(self):
        self.assertEqual(f1_score(0, 0, 5), 0.0)
        self.assertAlmostEqual(f1_score(5, 0, 0), 1.0)
        self.assertAlmostEqual(f1_score(1, 1, 4), 2 / 7)

    def test_screen_tracks_compass_false_positives(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            run = Path(temporary_directory)
            records = []
            for index in range(1, 31):
                response = "알겠어."
                if index in {1, 11}:
                    response = "나침반을 볼게."
                if index in range(1, 5):
                    response += " 엘레나야."
                if index in range(6, 11):
                    response += " 무슨 뜻이야?"
                records.append(
                    {
                        "case_id": f"custom-ms-{index:03d}",
                        "ability": "MS",
                        "response": response,
                        "timing": {"elapsed_ms": 10},
                    }
                )
            (run / "results.jsonl").write_text(
                "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in records),
                encoding="utf-8",
            )
            (run / "run_manifest.json").write_text(
                json.dumps({"persona_format": "test", "prompt": "test.md"}),
                encoding="utf-8",
            )
            result = screen_run(run)
        self.assertEqual(result["compass_routing"]["true_positive"], 1)
        self.assertEqual(result["compass_routing"]["false_positive"], 1)
        self.assertEqual(result["first_contact_intro"]["passed"], 4)
        self.assertEqual(result["earth_question"]["passed"], 5)


if __name__ == "__main__":
    unittest.main()
