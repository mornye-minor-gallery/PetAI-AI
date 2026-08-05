import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from common import METRICS, load_json, load_jsonl, sha256_file  # noqa: E402
from validate import (  # noqa: E402
    validate_all,
    validate_cases,
    validate_counter_facet_control,
    validate_no_scene_ablation,
    validate_persona,
)


class ValidateTests(unittest.TestCase):
    def test_committed_inputs_validate(self):
        summary = validate_all(ROOT)
        self.assertEqual(summary["case_count"], 60)
        self.assertEqual(set(summary["metric_counts"]), set(METRICS))

    def test_persona_and_cases_cover_every_metric(self):
        persona = load_json(ROOT / "persona/canonical.json")
        cases = load_jsonl(ROOT / "data/evaluation.jsonl")
        validate_persona(persona)
        counts = validate_cases(cases, persona)
        self.assertTrue(all(counts[metric] > 0 for metric in METRICS))

    def test_counter_facet_changes_only_controlled_scene_behaviors(self):
        validate_counter_facet_control(ROOT)

    def test_no_scene_removes_only_scene_facets(self):
        validate_no_scene_ablation(ROOT)

    def test_existing_mrprompt_baseline_stays_pinned(self):
        self.assertEqual(
            "e18d90e8a968c9020519c9ad5ffec6d27a11ae0c298b1ebd94030175ac10f6c3",
            sha256_file(ROOT / "prompts/mrprompt/full.md"),
        )


if __name__ == "__main__":
    unittest.main()
