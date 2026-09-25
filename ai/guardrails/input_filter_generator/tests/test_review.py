import unittest
import subprocess
from unittest.mock import patch

from ai.guardrails.input_filter_generator.review import parse_response, review_batch, review_prompt


class ReviewTests(unittest.TestCase):
    def test_prompt_limits_worker_to_supplied_batch(self):
        prompt = review_prompt([{"id": "a1", "language": "ko", "term": "가상금칙"}])
        self.assertIn("가상금칙", prompt)
        self.assertIn("Do not call tools", prompt)
        self.assertIn("Do not read files", prompt)

    def test_response_requires_exact_ids_once(self):
        expected = {"a1", "b2"}
        self.assertEqual(
            parse_response('{"decisions":[{"id":"a1","decision":"block"},'
                           '{"id":"b2","decision":"allow"}]}', expected),
            {"a1": "block", "b2": "allow"},
        )
        with self.assertRaises(ValueError):
            parse_response('{"decisions":[{"id":"a1","decision":"block"}]}', expected)

    def test_timeout_splits_batch_without_dropping_candidates(self):
        batch = [{"id": "a1"}, {"id": "b2"}]

        def run(rows):
            if len(rows) > 1:
                raise subprocess.TimeoutExpired("codex", 120)
            return {rows[0]["id"]: "allow"}

        with patch("ai.guardrails.input_filter_generator.review.run_batch", side_effect=run):
            self.assertEqual(review_batch(batch), {"a1": "allow", "b2": "allow"})


if __name__ == "__main__":
    unittest.main()
