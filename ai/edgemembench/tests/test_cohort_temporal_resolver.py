from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cohort_temporal_resolver as resolver
import retrieval_runner as dense


def candidate(
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


class QueryViewParserTests(unittest.TestCase):
    def test_transition_precedes_historical_and_current(self) -> None:
        result = resolver.infer_query_view(
            "How often did I play previously, and how often do I play now?"
        )
        self.assertEqual(result.view, resolver.QueryView.TRANSITION)

    def test_strict_as_of_extracts_cutoff(self) -> None:
        result = resolver.infer_query_view(
            "What happened on the earlier trip before the 7/22 trip?"
        )
        self.assertEqual(result.view, resolver.QueryView.AS_OF)
        self.assertEqual(result.cutoff_month_day, (7, 22))
        self.assertFalse(result.cutoff_inclusive)

    def test_historical_current_and_neutral(self) -> None:
        self.assertEqual(
            resolver.infer_query_view("What was my previous goal?").view,
            resolver.QueryView.HISTORICAL_PREVIOUS,
        )
        self.assertEqual(
            resolver.infer_query_view("What is my current goal?").view,
            resolver.QueryView.CURRENT,
        )
        self.assertEqual(
            resolver.infer_query_view("What goal did I mention?").view,
            resolver.QueryView.NEUTRAL,
        )

    def test_neutral_defaults_current_only_for_version_cohort(self) -> None:
        neutral = resolver.QueryViewResult(
            resolver.QueryView.NEUTRAL,
            "fixture",
        )
        self.assertEqual(
            resolver.effective_view(neutral, 1).view,
            resolver.QueryView.NEUTRAL,
        )
        self.assertEqual(
            resolver.effective_view(neutral, 2).view,
            resolver.QueryView.CURRENT,
        )


class TemporalOperatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.old = candidate("old", 0.60, 1, (2026, 1, 1, 0, 0))
        self.middle = candidate("middle", 0.59, 2, (2026, 2, 1, 0, 0))
        self.new = candidate("new", 0.58, 3, (2026, 3, 1, 0, 0))
        self.other = candidate("other", 0.57, 4, (2026, 4, 1, 0, 0))
        self.candidates = [self.old, self.middle, self.new, self.other]
        self.cohort = resolver.CohortSelection(
            ("old", "middle", "new"),
            None,
            None,
            None,
            None,
        )

    def resolved(self, view: resolver.QueryViewResult) -> list[str]:
        return [
            item.candidate.turn_id
            for item in resolver.resolve_local(
                self.candidates,
                self.cohort,
                view,
            )
        ]

    def test_current_selects_latest_version(self) -> None:
        self.assertEqual(
            self.resolved(resolver.QueryViewResult(
                resolver.QueryView.CURRENT, "fixture"
            ))[0],
            "new",
        )

    def test_historical_selects_immediate_predecessor_not_oldest(self) -> None:
        self.assertEqual(
            self.resolved(resolver.QueryViewResult(
                resolver.QueryView.HISTORICAL_PREVIOUS, "fixture"
            ))[0],
            "middle",
        )

    def test_transition_promotes_chronological_versions(self) -> None:
        self.assertEqual(
            self.resolved(resolver.QueryViewResult(
                resolver.QueryView.TRANSITION, "fixture"
            ))[:3],
            ["old", "middle", "new"],
        )

    def test_as_of_never_selects_future_version(self) -> None:
        resolved = self.resolved(resolver.QueryViewResult(
            resolver.QueryView.AS_OF,
            "fixture",
            (2, 15),
            True,
        ))
        self.assertEqual(resolved[0], "middle")

    def test_candidate_set_is_never_changed(self) -> None:
        resolved = self.resolved(resolver.QueryViewResult(
            resolver.QueryView.CURRENT, "fixture"
        ))
        self.assertEqual(set(resolved), {"old", "middle", "new", "other"})

    def test_neutral_singleton_preserves_dense_order(self) -> None:
        singleton = resolver.CohortSelection(
            ("middle",), None, None, None, None
        )
        ranked = resolver.resolve_local(
            self.candidates,
            singleton,
            resolver.QueryViewResult(resolver.QueryView.NEUTRAL, "fixture"),
        )
        self.assertEqual(
            [item.candidate.turn_id for item in ranked],
            ["old", "middle", "new", "other"],
        )


class ViewContractTests(unittest.TestCase):
    def test_repo_contract_covers_exactly_69_scored_cases(self) -> None:
        views = resolver.load_view_contract(
            resolver.DEFAULT_VIEW_CONTRACT_PATH,
            resolver.ROOT / "data" / "knowledge_update_annotations.jsonl",
        )
        self.assertEqual(len(views), 69)
        strict = views["edgemem-c-10e09553"]
        self.assertEqual(strict.view, resolver.QueryView.AS_OF)
        self.assertEqual(strict.cutoff_month_day, (7, 22))
        self.assertFalse(strict.cutoff_inclusive)

        manifest = json.loads(
            (resolver.ROOT / "benchmark_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        source = manifest["sources"]["temporal_view_contract"]
        self.assertEqual(source["expected_scored_cases"], len(views))
        self.assertEqual(
            source["sha256"],
            dense.sha256_file(resolver.DEFAULT_VIEW_CONTRACT_PATH),
        )

    def test_contract_rejects_wrong_case_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            payload = json.loads(
                resolver.DEFAULT_VIEW_CONTRACT_PATH.read_text(encoding="utf-8")
            )
            payload["scored_case_count"] = 68
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(resolver.CohortTemporalError):
                resolver.load_view_contract(
                    path,
                    resolver.ROOT / "data" / "knowledge_update_annotations.jsonl",
                )


if __name__ == "__main__":
    unittest.main()
