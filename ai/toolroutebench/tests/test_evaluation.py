from __future__ import annotations

import unittest

from toolroutebench.common import ToolRouteBenchError
from toolroutebench.evaluation import (
    aggregate_similarity,
    multilabel_metrics,
    positive_vs_normal_margin,
    route_state,
    select_safe_candidate,
)


TOOLS = ["alarm", "timer"]


class EvaluationTests(unittest.TestCase):
    def test_route_state_is_derived_from_active_axis_count(self) -> None:
        self.assertEqual(route_state([]), "normal")
        self.assertEqual(route_state(["alarm"]), "tool")
        self.assertEqual(route_state(["alarm", "timer"]), "conflict")

    def test_all_three_prototype_aggregations_are_deterministic(self) -> None:
        query = [1.0, 0.0]
        prototypes = [[1.0, 0.0], [0.8, 0.2], [0.6, 0.4], [0.0, 1.0]]
        for method in (
            "max_similarity",
            "centroid_similarity",
            "top3_mean_similarity",
        ):
            first = aggregate_similarity(query, prototypes, method)
            second = aggregate_similarity(query, prototypes, method)
            self.assertEqual(first, second)
            self.assertTrue(-1.0 <= first <= 1.0)

    def test_margin_prefers_tool_or_normal_by_relative_similarity(self) -> None:
        query = [1.0, 0.0]
        positive = [[1.0, 0.0]]
        normal = [[0.0, 1.0]]
        self.assertGreater(
            positive_vs_normal_margin(query, positive, normal, "max_similarity"),
            0,
        )

    def test_metrics_count_normal_false_activation(self) -> None:
        result = multilabel_metrics(
            gold_rows=[[], ["alarm"], ["alarm", "timer"]],
            predicted_rows=[["timer"], ["alarm"], ["alarm"]],
            tool_order=TOOLS,
        )
        self.assertEqual(result["normal_false_activation_count"], 1)
        self.assertEqual(result["normal_false_activation_rate"], 1.0)
        self.assertAlmostEqual(result["exact_match"], 1 / 3)

    def test_candidate_must_be_safer_than_regex_and_improve_macro_f1(self) -> None:
        baseline = {
            "normal_false_activation_rate": 0.10,
            "single_track_macro_f1": 0.70,
        }
        candidates = [
            {
                "candidate_id": "unsafe",
                "oof_metrics": {
                    "normal_false_activation_rate": 0.20,
                    "single_track_macro_f1": 0.90,
                },
            },
            {
                "candidate_id": "always-normal-like",
                "oof_metrics": {
                    "normal_false_activation_rate": 0.0,
                    "single_track_macro_f1": 0.20,
                },
            },
            {
                "candidate_id": "safe-improvement",
                "oof_metrics": {
                    "normal_false_activation_rate": 0.05,
                    "single_track_macro_f1": 0.80,
                },
            },
        ]
        selected = select_safe_candidate(baseline, candidates)
        self.assertIsNotNone(selected)
        self.assertEqual(selected["candidate_id"], "safe-improvement")

    def test_no_candidate_is_a_valid_pilot_result(self) -> None:
        baseline = {
            "normal_false_activation_rate": 0.0,
            "single_track_macro_f1": 0.8,
        }
        self.assertIsNone(
            select_safe_candidate(
                baseline,
                [
                    {
                        "candidate_id": "regression",
                        "oof_metrics": {
                            "normal_false_activation_rate": 0.0,
                            "single_track_macro_f1": 0.7,
                        },
                    }
                ],
            )
        )

    def test_training_metrics_cannot_override_oof_selection(self) -> None:
        baseline = {
            "normal_false_activation_rate": 0.10,
            "single_track_macro_f1": 0.70,
        }
        selected = select_safe_candidate(
            baseline,
            [
                {
                    "candidate_id": "overfit",
                    "training_metrics": {
                        "normal_false_activation_rate": 0.0,
                        "single_track_macro_f1": 1.0,
                    },
                    "oof_metrics": {
                        "normal_false_activation_rate": 0.20,
                        "single_track_macro_f1": 0.60,
                    },
                },
                {
                    "candidate_id": "generalizes",
                    "training_metrics": {
                        "normal_false_activation_rate": 0.0,
                        "single_track_macro_f1": 0.85,
                    },
                    "oof_metrics": {
                        "normal_false_activation_rate": 0.05,
                        "single_track_macro_f1": 0.80,
                    },
                },
            ],
        )
        self.assertIsNotNone(selected)
        self.assertEqual(selected["candidate_id"], "generalizes")

    def test_candidate_without_oof_metrics_fails_closed(self) -> None:
        baseline = {
            "normal_false_activation_rate": 0.10,
            "single_track_macro_f1": 0.70,
        }
        with self.assertRaisesRegex(ToolRouteBenchError, "oof_metrics"):
            select_safe_candidate(
                baseline,
                [
                    {
                        "candidate_id": "legacy",
                        "normal_false_activation_rate": 0.0,
                        "single_track_macro_f1": 1.0,
                    }
                ],
            )

    def test_zero_norm_vectors_fail_closed(self) -> None:
        with self.assertRaises(ToolRouteBenchError):
            aggregate_similarity(
                [0.0, 0.0],
                [[1.0, 0.0]],
                "max_similarity",
            )


if __name__ == "__main__":
    unittest.main()
