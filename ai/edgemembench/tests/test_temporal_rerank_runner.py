from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import retrieval_runner as dense
import temporal_rerank_runner as temporal


def candidate(
    *,
    turn_id: str,
    score: float,
    rank: int,
    timestamp: tuple[int, int, int, int, int],
) -> dense.RankedCandidate:
    return dense.RankedCandidate(
        candidate=dense.Candidate(
            turn_id=turn_id,
            session_id=turn_id,
            text=turn_id,
            timestamp=timestamp,
        ),
        score=score,
        rank=rank,
    )


class TemporalIntentTests(unittest.TestCase):
    def test_multi_intent_has_precedence_over_current_and_historical(self) -> None:
        result = temporal.infer_temporal_intent(
            "How often did I play previously, and how often do I play now?"
        )
        self.assertEqual(result.intent, temporal.TemporalIntent.MULTI)

    def test_current_historical_and_unspecified_intents(self) -> None:
        self.assertEqual(
            temporal.infer_temporal_intent(
                "What is my current score?"
            ).intent,
            temporal.TemporalIntent.CURRENT,
        )
        self.assertEqual(
            temporal.infer_temporal_intent(
                "What was my previous score?"
            ).intent,
            temporal.TemporalIntent.HISTORICAL,
        )
        self.assertEqual(
            temporal.infer_temporal_intent(
                "What score did I mention?"
            ).intent,
            temporal.TemporalIntent.UNSPECIFIED,
        )

    def test_cutoff_month_day_is_extracted(self) -> None:
        result = temporal.infer_temporal_intent(
            "What happened before the 7/22 trip?"
        )
        self.assertEqual(result.intent, temporal.TemporalIntent.HISTORICAL)
        self.assertEqual(result.cutoff_month_day, (7, 22))


class TemporalRankingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.old = candidate(
            turn_id="old",
            score=0.60,
            rank=1,
            timestamp=(2026, 1, 1, 0, 0),
        )
        self.new = candidate(
            turn_id="new",
            score=0.59,
            rank=2,
            timestamp=(2026, 2, 1, 0, 0),
        )

    def test_current_intent_can_promote_recent_candidate(self) -> None:
        reranked = temporal.rerank_candidates(
            [self.old, self.new],
            temporal.TemporalIntentResult(
                temporal.TemporalIntent.CURRENT,
                "fixture",
            ),
            alpha=0.05,
        )
        self.assertEqual(
            [item.dense_candidate.candidate.turn_id for item in reranked],
            ["new", "old"],
        )

    def test_historical_intent_preserves_old_candidate(self) -> None:
        reranked = temporal.rerank_candidates(
            [self.old, self.new],
            temporal.TemporalIntentResult(
                temporal.TemporalIntent.HISTORICAL,
                "fixture",
            ),
            alpha=0.05,
        )
        self.assertEqual(
            [item.dense_candidate.candidate.turn_id for item in reranked],
            ["old", "new"],
        )

    def test_unspecified_and_multi_fail_closed(self) -> None:
        for intent in (
            temporal.TemporalIntent.UNSPECIFIED,
            temporal.TemporalIntent.MULTI,
        ):
            reranked = temporal.rerank_candidates(
                [self.old, self.new],
                temporal.TemporalIntentResult(intent, "fixture"),
                alpha=0.10,
            )
            self.assertEqual(
                [item.dense_candidate.candidate.turn_id for item in reranked],
                ["old", "new"],
            )

    def test_candidate_set_never_changes(self) -> None:
        reranked = temporal.rerank_candidates(
            [self.old, self.new],
            temporal.TemporalIntentResult(
                temporal.TemporalIntent.CURRENT,
                "fixture",
            ),
            alpha=0.10,
        )
        self.assertEqual(
            {
                item.dense_candidate.candidate.turn_id for item in reranked
            },
            {"old", "new"},
        )

    def test_timestamp_normalization_is_fixed_to_utc(self) -> None:
        self.assertEqual(
            temporal.timestamp_value((1970, 1, 1, 0, 0)),
            0.0,
        )


if __name__ == "__main__":
    unittest.main()
