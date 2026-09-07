import unittest
from beolmuri_eval.metrics import summarize, compare_results


def row(key, label, kind="wrong_name", correction=None, status="graded"):
    return {"key": key, "case": {"kind": kind}, "status": status,
            "judgment": {"label": label, "incorrect_name_correction": correction}}


class MetricsTests(unittest.TestCase):
    def test_unjudgeable_stays_in_denominator_errors_are_separate(self):
        records = [row("1", "identity_maintained"), row("2", "explicit_acceptance"),
                   row("3", "uncorrected_response"), row("4", "unjudgeable"),
                   row("5", None, status="judge_error"), row("6", None, status="generation_error")]
        result = summarize(records, planned=6)
        self.assertEqual(result["wrong_name"]["identity_maintained_pct"], 25)
        self.assertEqual(result["wrong_name"]["denominator"], 4)
        self.assertEqual(result["judge_errors"], 1)
        self.assertEqual(result["generation_errors"], 1)
        self.assertFalse(result["complete"])

    def test_control_unknown_is_not_false_correction(self):
        result = summarize([row("a", "identity_maintained", "correct_name", False),
                            row("b", "unjudgeable", "correct_name", None)], planned=2)
        self.assertEqual(result["correct_name"]["incorrect_correction_pct"], 0)
        self.assertEqual(result["correct_name"]["unjudgeable_pct"], 50)

    def test_pairwise_changes_match_keys_not_positions(self):
        old = [row("a", "uncorrected_response"), row("b", "identity_maintained")]
        new = [row("b", "explicit_acceptance"), row("a", "identity_maintained")]
        result = compare_results(old, new)
        self.assertEqual(result["improved"], 1)
        self.assertEqual(result["regressed"], 1)

    def test_duplicate_keys_rejected(self):
        with self.assertRaises(ValueError):
            summarize([row("a", "identity_maintained"), row("a", "identity_maintained")], planned=2)
