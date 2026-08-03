from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cohort_gate_diagnostic as gate
import retrieval_runner as dense


def candidate(
    turn_id: str,
    score: float,
    rank: int,
    vector: tuple[float, ...],
) -> dense.RankedCandidate:
    return dense.RankedCandidate(
        candidate=dense.Candidate(
            turn_id=turn_id,
            session_id=turn_id,
            text=turn_id,
            timestamp=(2026, 1, rank, 0, 0),
        ),
        score=score,
        rank=rank,
    )


class FakeStore:
    def __init__(self, vectors: dict[str, tuple[float, ...]]) -> None:
        self.vectors = vectors

    def vector(self, kind: str, text: str) -> tuple[float, ...]:
        if kind != "document":
            raise AssertionError("fixture only supports documents")
        return self.vectors[text]


class PartnerProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.anchor = candidate("anchor", 0.70, 1, (1.0, 0.0))
        self.close = candidate("close", 0.68, 2, (0.99, 0.1))
        self.other = candidate("other", 0.67, 3, (0.0, 1.0))
        self.store = FakeStore({
            "anchor": (1.0, 0.0),
            "close": (0.99, 0.1),
            "other": (0.0, 1.0),
        })

    def test_profile_reports_margin_and_mutual_nearest(self) -> None:
        profile = gate.partner_profile(
            [self.anchor, self.close, self.other],
            self.store,  # type: ignore[arg-type]
            0.05,
        )
        self.assertIsNotNone(profile)
        assert profile is not None
        self.assertEqual(profile.partner_id, "close")
        self.assertTrue(profile.mutual_nearest)
        self.assertIsNotNone(profile.pair_margin)
        assert profile.pair_margin is not None
        self.assertGreater(profile.pair_margin, 0.8)

    def test_margin_fails_closed_without_runner_up(self) -> None:
        profile = gate.partner_profile(
            [self.anchor, self.close],
            self.store,  # type: ignore[arg-type]
            0.05,
        )
        assert profile is not None
        self.assertIsNone(profile.pair_margin)
        self.assertFalse(
            gate.gate_accepts(profile, gate.GateConfig("margin", False, 0.0))
        )
        self.assertTrue(
            gate.gate_accepts(profile, gate.GateConfig("baseline", False, None))
        )

    def test_mutual_gate_rejects_non_mutual_profile(self) -> None:
        profile = gate.PartnerProfile(
            "anchor",
            "partner",
            ("anchor", "partner"),
            0.8,
            0.7,
            0.1,
            False,
            0.01,
            3,
        )
        self.assertFalse(
            gate.gate_accepts(profile, gate.GateConfig("mutual", True, None))
        )


class GateConfigTests(unittest.TestCase):
    def test_configs_include_baseline_mutual_and_combined_rows(self) -> None:
        configs = gate.gate_configs([0.05])
        self.assertEqual(
            [config.config_id for config in configs],
            ["baseline", "mutual_only", "margin_0.05", "mutual_margin_0.05"],
        )


if __name__ == "__main__":
    unittest.main()
