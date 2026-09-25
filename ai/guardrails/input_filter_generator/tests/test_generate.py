import unittest
import tempfile
import json
from pathlib import Path

from ai.guardrails.input_filter_generator.generate import (
    build_policy,
    collect_candidates,
    extract_english,
    extract_korean,
    write_json,
)


class GenerateTests(unittest.TestCase):
    def test_korean_import_reads_only_literal_target_categories(self):
        source = '''
GENERAL_PROFANITY_PATTERNS = ["가상금칙", "가상.*패턴"]
SEXUAL_PROFANITY_PATTERNS = ["가상성표현"]
MINOR_PROFANITY_PATTERNS = ["가벼운말"]
'''
        self.assertEqual(extract_korean(source), ["가상금칙", "가상성표현"])

    def test_english_import_keeps_words_without_blank_lines_or_duplicates(self):
        self.assertEqual(extract_english("Badword\n\nBADWORD\nodd phrase\n"), ["badword", "odd phrase"])

    def test_only_two_matching_block_reviews_enter_runtime_policy(self):
        candidates = collect_candidates(["가상금칙"], ["badword"])
        first = {candidate["id"]: "block" for candidate in candidates}
        second = {candidate["id"]: "block" for candidate in candidates}
        second[candidates[1]["id"]] = "unsure"

        policy = build_policy(candidates, first, second)

        self.assertEqual(policy, {"version": 1, "koreanContains": ["가상금칙"], "englishWholeWords": []})

    def test_missing_review_is_an_error(self):
        candidates = collect_candidates(["가상금칙"], [])
        with self.assertRaisesRegex(ValueError, "missing review"):
            build_policy(candidates, {}, {})

    def test_single_korean_character_is_not_a_contains_rule(self):
        candidates = collect_candidates(["가", "가상금칙"], [])
        reviews = {candidate["id"]: "block" for candidate in candidates}

        policy = build_policy(candidates, reviews, reviews)

        self.assertEqual(policy["koreanContains"], ["가상금칙"])

    def test_private_outputs_are_atomic_and_tracked_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "policy.json"
            write_json(output, {"version": 1})
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"version": 1})
        tracked_path = Path(__file__).parent / "must-not-write.json"
        with self.assertRaisesRegex(ValueError, "ignored by Git"):
            write_json(tracked_path, {"version": 1})
        self.assertFalse(tracked_path.exists())


if __name__ == "__main__":
    unittest.main()
