import json
import sqlite3
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import retrieval_runner as runner


class FakeEmbeddingStore:
    def __init__(self, vectors: dict[tuple[str, str], tuple[float, ...]]) -> None:
        self.vectors = vectors
        self.closed = False

    def vector(self, kind: str, text: str) -> tuple[float, ...]:
        return self.vectors[(kind, text.strip())]

    def close(self) -> None:
        self.closed = True


def memory_record(
    *,
    axis: str = "B",
    subtype: str | None = None,
) -> dict:
    expected = {
        "answer": "strawberry",
        "expected_abstention": axis == "D",
        "gold_evidence_turn_ids": (
            ["old::turn-0000", "new::turn-0000"] if axis != "D" else []
        ),
        "partial_evidence_turn_ids": [],
        "answer_session_ids": ["old", "new"],
    }
    if axis == "C":
        expected.update(
            {
                "evaluation_status": "scored",
                "temporal_subtype": subtype or "current_state",
                "target_evidence_turn_ids": ["new::turn-0000"],
                "competing_evidence_turn_ids": ["old::turn-0000"],
                "context_evidence_turn_ids": [],
                "exclusion_reason": None,
                "annotation_rationale": "Fixture annotation.",
            }
        )
    elif axis == "D":
        expected.update({"subtype": subtype or "absent_evidence"})
    return {
        "case_id": f"case-{axis}",
        "axis": axis,
        "task": {
            "B": "single_memory_retrieval",
            "C": "knowledge_update",
            "D": "abstention",
        }[axis],
        "query": "What fruit do I like?",
        "history": [
            {
                "session_id": "old",
                "source_session_id": "old-source",
                "timestamp": "2026/01/01 (Thu) 09:00",
                "turns": [
                    {
                        "turn_id": "old::turn-0000",
                        "role": "user",
                        "content": "I like apples.",
                    }
                ],
            },
            {
                "session_id": "new",
                "source_session_id": "new-source",
                "timestamp": "2026/02/01 (Sun) 09:00",
                "turns": [
                    {
                        "turn_id": "new::turn-0000",
                        "role": "user",
                        "content": "I like strawberries.",
                    }
                ],
            },
        ],
        "expected": expected,
        "source": {"dataset": "fixture"},
    }


class EmbeddingContractTests(unittest.TestCase):
    def test_query_and_document_inputs_use_ios_prefixes(self) -> None:
        query = runner.embedding_input("query", " hello ")
        document = runner.embedding_input("document", "hello")
        self.assertEqual(query["prefix"], runner.QUERY_PREFIX)
        self.assertEqual(document["prefix"], runner.DOCUMENT_PREFIX)
        self.assertNotEqual(query["embedding_id"], document["embedding_id"])
        self.assertEqual(query["text"], "hello")

    def test_cosine_matches_direction_and_float32_result(self) -> None:
        self.assertEqual(runner.cosine_similarity([1, 0], [1, 0]), 1.0)
        self.assertEqual(runner.cosine_similarity([1, 0], [-1, 0]), -1.0)
        self.assertAlmostEqual(
            runner.cosine_similarity([1, 0], [1, 1]),
            runner.float32(2 ** -0.5),
        )

    def test_cosine_rejects_zero_and_mismatched_vectors(self) -> None:
        with self.assertRaises(runner.RetrievalRunnerError):
            runner.cosine_similarity([0, 0], [1, 0])
        with self.assertRaises(runner.RetrievalRunnerError):
            runner.cosine_similarity([1], [1, 0])

    def test_embedding_store_requires_complete_contract_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "embeddings.sqlite3"
            connection = sqlite3.connect(path)
            runner.initialize_embedding_database(
                connection,
                {
                    "status": "complete",
                    "model_id": runner.MODEL_ID,
                    "dimension": str(runner.EXPECTED_DIMENSION),
                    "sequence_length": str(runner.SEQUENCE_LENGTH),
                    "query_prefix": runner.QUERY_PREFIX,
                    "document_prefix": runner.DOCUMENT_PREFIX,
                },
            )
            text = "hello"
            values = [1.0] + [0.0] * (runner.EXPECTED_DIMENSION - 1)
            connection.execute(
                """
                INSERT INTO embeddings(
                  embedding_id, kind, text_sha256, dimension, vector
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    runner.embedding_id("query", text),
                    "query",
                    __import__("hashlib").sha256(text.encode()).hexdigest(),
                    runner.EXPECTED_DIMENSION,
                    struct.pack(
                        f"<{runner.EXPECTED_DIMENSION}f",
                        *values,
                    ),
                ),
            )
            connection.commit()
            connection.close()

            store = runner.EmbeddingStore(path)
            self.assertEqual(store.vector("query", text)[:2], (1.0, 0.0))
            store.close()


class RankingTests(unittest.TestCase):
    def test_rank_uses_score_then_recency_and_deduplicates_like_swift(self) -> None:
        record = memory_record()
        duplicate_turn = {
            "turn_id": "new::turn-0001",
            "role": "user",
            "content": "I  like apples.",
        }
        record["history"][1]["turns"].append(duplicate_turn)
        store = FakeEmbeddingStore(
            {
                ("query", record["query"]): (1.0, 0.0),
                ("document", "I like apples."): (1.0, 0.0),
                ("document", "I like strawberries."): (0.8, 0.2),
                ("document", "I  like apples."): (1.0, 0.0),
            }
        )
        ranked, raw = runner.rank_record(record, store)
        self.assertEqual(len(raw), 3)
        self.assertEqual(
            [candidate.candidate.turn_id for candidate in ranked],
            ["new::turn-0001", "new::turn-0000"],
        )

    def test_b_scoring_uses_any_gold_and_gold_recall(self) -> None:
        record = memory_record()
        ranked = [
            runner.RankedCandidate(
                runner.Candidate(
                    turn_id="new::turn-0000",
                    session_id="new",
                    text="memory",
                    timestamp=(2026, 2, 1, 9, 0),
                ),
                score=0.9,
                rank=1,
            )
        ]
        score = runner.score_record(record, ranked, [1, 3])
        self.assertTrue(score["hit_at_k"]["1"])
        self.assertEqual(score["gold_recall_at_k"]["1"], 0.5)
        self.assertEqual(score["reciprocal_rank"], 1.0)

    def test_c_scoring_detects_target_before_competing(self) -> None:
        record = memory_record(axis="C")
        ranked = [
            runner.RankedCandidate(
                runner.Candidate(
                    turn_id="new::turn-0000",
                    session_id="new",
                    text="new",
                    timestamp=(2026, 2, 1, 9, 0),
                ),
                score=0.9,
                rank=1,
            ),
            runner.RankedCandidate(
                runner.Candidate(
                    turn_id="old::turn-0000",
                    session_id="old",
                    text="old",
                    timestamp=(2026, 1, 1, 9, 0),
                ),
                score=0.8,
                rank=2,
            ),
        ]
        score = runner.score_record(record, ranked, [1, 3])
        self.assertTrue(score["target_hit_at_k"]["1"])
        self.assertEqual(score["target_recall_at_k"]["1"], 1.0)
        self.assertTrue(score["target_before_competing"])

    def test_excluded_c_case_has_no_aggregate_target_score(self) -> None:
        record = memory_record(axis="C")
        record["expected"]["evaluation_status"] = "excluded"
        record["expected"]["exclusion_reason"] = "fixture_exclusion"
        ranked = [
            runner.RankedCandidate(
                runner.Candidate(
                    turn_id="new::turn-0000",
                    session_id="new",
                    text="new",
                    timestamp=(2026, 2, 1, 9, 0),
                ),
                score=0.9,
                rank=1,
            )
        ]
        score = runner.score_record(record, ranked, [1])
        self.assertEqual(score["evaluation_status"], "excluded")
        self.assertNotIn("target_hit_at_k", score)

    def test_auroc_handles_wins_losses_and_ties(self) -> None:
        self.assertEqual(runner.roc_auc([0.9], [0.1]), 1.0)
        self.assertEqual(runner.roc_auc([0.1], [0.9]), 0.0)
        self.assertEqual(runner.roc_auc([0.5], [0.5]), 0.5)


class EndToEndFixtureTests(unittest.TestCase):
    def test_run_writes_results_and_does_not_select_threshold(self) -> None:
        records = [
            memory_record(axis="B"),
            memory_record(axis="C"),
            memory_record(axis="D"),
        ]
        vectors = {
            ("query", "What fruit do I like?"): (1.0, 0.0),
            ("document", "I like apples."): (0.7, 0.3),
            ("document", "I like strawberries."): (1.0, 0.0),
        }
        fake_store = FakeEmbeddingStore(vectors)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact_dir = root / "artifacts"
            artifact_dir.mkdir()
            (artifact_dir / "artifact_manifest.json").write_text(
                "{}\n", encoding="utf-8"
            )
            embeddings = root / "embeddings.sqlite3"
            embeddings.write_bytes(b"fixture")
            output = root / "results"

            with (
                mock.patch.object(
                    runner.prepare,
                    "validate_artifacts",
                    return_value={},
                ),
                mock.patch.object(
                    runner,
                    "iter_retrieval_records",
                    return_value=iter(records),
                ),
                mock.patch.object(
                    runner,
                    "EmbeddingStore",
                    return_value=fake_store,
                ),
            ):
                summary = runner.run_retrieval(
                    artifact_dir,
                    embeddings,
                    output,
                    [1, 2],
                )

            self.assertTrue(fake_store.closed)
            self.assertEqual(summary["metrics"]["retrieval_cases"], 3)
            gate = summary["metrics"]["query_level_gate"]
            self.assertIn("Sweep only", gate["threshold_policy"])
            self.assertNotIn("selected_threshold", gate)
            self.assertTrue((output / "retrieval_results.jsonl").is_file())
            persisted = json.loads(
                (output / "retrieval_summary.json").read_text()
            )
            self.assertEqual(
                persisted["baseline_contract"]["reader"],
                "not run",
            )


if __name__ == "__main__":
    unittest.main()
