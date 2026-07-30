#!/usr/bin/env python3
"""Run the EdgeMemBench B-D dense-retrieval baseline."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import platform
import sqlite3
import struct
import sys
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

import prepare


ROOT = Path(__file__).resolve().parent
DEFAULT_ARTIFACT_DIR = prepare.DEFAULT_ARTIFACT_DIR
DEFAULT_RETRIEVAL_DIR = DEFAULT_ARTIFACT_DIR / "retrieval"
DEFAULT_INPUTS_PATH = DEFAULT_RETRIEVAL_DIR / "embedding_inputs.jsonl"
DEFAULT_EMBEDDINGS_PATH = DEFAULT_RETRIEVAL_DIR / "embeddinggemma.sqlite3"
DEFAULT_RESULTS_DIR = DEFAULT_RETRIEVAL_DIR / "baseline"

RUNNER_VERSION = "0.2.0"
MODEL_ID = "litert-community/embeddinggemma-300m-seq256-mixed-precision"
SEQUENCE_LENGTH = 256
EXPECTED_DIMENSION = 768
QUERY_PREFIX = "task: search result | query: "
DOCUMENT_PREFIX = "title: none | text: "
RETRIEVAL_AXES = ("B", "C", "D")


class RetrievalRunnerError(RuntimeError):
    """Raised when retrieval inputs or results violate the baseline contract."""


@dataclass(frozen=True)
class Candidate:
    turn_id: str
    session_id: str
    text: str
    timestamp: tuple[int, int, int, int, int]


@dataclass(frozen=True)
class RankedCandidate:
    candidate: Candidate
    score: float
    rank: int


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_embedding_text(text: Any) -> str:
    if not isinstance(text, str):
        raise RetrievalRunnerError("embedding text must be a string")
    normalized = text.strip()
    if not normalized:
        raise RetrievalRunnerError("embedding text must be non-empty")
    return normalized


def embedding_id(kind: str, text: str) -> str:
    if kind not in {"query", "document"}:
        raise RetrievalRunnerError(f"invalid embedding kind: {kind}")
    normalized = normalized_embedding_text(text)
    return hashlib.sha256(
        f"{kind}\0{normalized}".encode("utf-8")
    ).hexdigest()


def embedding_input(kind: str, text: str) -> dict[str, Any]:
    normalized = normalized_embedding_text(text)
    return {
        "embedding_id": embedding_id(kind, normalized),
        "kind": kind,
        "prefix": QUERY_PREFIX if kind == "query" else DOCUMENT_PREFIX,
        "text": normalized,
        "text_sha256": hashlib.sha256(normalized.encode("utf-8")).hexdigest(),
    }


def iter_retrieval_records(
    artifact_dir: Path,
) -> Iterable[dict[str, Any]]:
    for axis in RETRIEVAL_AXES:
        path = artifact_dir / prepare.OUTPUT_FILES[axis]
        yield from prepare.read_jsonl(path)


def prepare_embedding_inputs(
    artifact_dir: Path,
    output_path: Path,
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    if output_path.exists():
        raise RetrievalRunnerError(
            f"embedding input file already exists: {output_path}"
        )

    unique: dict[str, dict[str, Any]] = {}
    case_count = 0
    turn_count = 0
    for record in iter_retrieval_records(artifact_dir):
        case_count += 1
        query_input = embedding_input("query", record["query"])
        unique.setdefault(query_input["embedding_id"], query_input)
        for session in record["history"]:
            for turn in session["turns"]:
                turn_count += 1
                document_input = embedding_input("document", turn["content"])
                unique.setdefault(document_input["embedding_id"], document_input)

    records = sorted(
        unique.values(),
        key=lambda record: (record["kind"], record["embedding_id"]),
    )
    prepare.write_jsonl_atomic(output_path, records)
    manifest = {
        "phase": "embedding_inputs_prepared",
        "runner_version": RUNNER_VERSION,
        "benchmark_version": prepare.load_manifest()["version"],
        "artifact_manifest_sha256": sha256_file(
            artifact_dir / "artifact_manifest.json"
        ),
        "embedding_inputs": {
            "path": output_path.name,
            "sha256": sha256_file(output_path),
            "records": len(records),
            "queries": sum(record["kind"] == "query" for record in records),
            "documents": sum(
                record["kind"] == "document" for record in records
            ),
        },
        "retrieval_cases": case_count,
        "source_user_turns": turn_count,
        "embedding_contract": {
            "model_id": MODEL_ID,
            "sequence_length": SEQUENCE_LENGTH,
            "dimension": EXPECTED_DIMENSION,
            "query_prefix": QUERY_PREFIX,
            "document_prefix": DOCUMENT_PREFIX,
        },
    }
    manifest_path = output_path.with_suffix(".manifest.json")
    prepare.write_json_atomic(manifest_path, manifest)
    return manifest


def load_embedding_inputs(path: Path) -> list[dict[str, Any]]:
    records = prepare.read_jsonl(path)
    seen: set[str] = set()
    for record in records:
        identifier = record.get("embedding_id")
        kind = record.get("kind")
        text = record.get("text")
        expected = embedding_input(kind, text)
        if record != expected:
            raise RetrievalRunnerError(
                f"{identifier}: embedding input does not match canonical form"
            )
        if identifier in seen:
            raise RetrievalRunnerError(f"duplicate embedding ID: {identifier}")
        seen.add(identifier)
    return records


def initialize_embedding_database(
    connection: sqlite3.Connection,
    metadata: dict[str, str],
) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS embeddings (
          embedding_id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('query', 'document')),
          text_sha256 TEXT NOT NULL,
          dimension INTEGER NOT NULL,
          vector BLOB NOT NULL
        );
        """
    )
    existing = dict(connection.execute("SELECT key, value FROM metadata"))
    for key, value in metadata.items():
        if key in existing and existing[key] != value:
            raise RetrievalRunnerError(
                f"embedding database metadata mismatch for {key}"
            )
        connection.execute(
            "INSERT OR IGNORE INTO metadata(key, value) VALUES (?, ?)",
            (key, value),
        )
    connection.commit()


class EmbeddingGemmaRuntime:
    """Lazy LiteRT runtime matching the current iOS EmbeddingGemma contract."""

    def __init__(self, model_path: Path, tokenizer_path: Path) -> None:
        try:
            import numpy as numpy
            import sentencepiece as sentencepiece
            from ai_edge_litert.compiled_model import (
                CompiledModel,
                HardwareAccelerator,
            )
        except ImportError as exc:
            raise RetrievalRunnerError(
                "Embedding extraction requires the ai/memory-classifier "
                "environment (ai-edge-litert, numpy, sentencepiece)."
            ) from exc

        self._numpy = numpy
        self._tokenizer = sentencepiece.SentencePieceProcessor(
            model_file=str(tokenizer_path)
        )
        self._model = CompiledModel.from_file(
            str(model_path),
            hardware_accel=HardwareAccelerator.CPU,
        )
        signatures = self._model.get_signature_list()
        if len(signatures) != 1:
            raise RetrievalRunnerError(
                f"expected one model signature, found {len(signatures)}"
            )
        signature = next(iter(signatures.values()))
        if len(signature["inputs"]) != 1 or len(signature["outputs"]) != 1:
            raise RetrievalRunnerError(
                "EmbeddingGemma must expose one input and one output tensor"
            )
        self._inputs = self._model.create_input_buffers(0)
        self._outputs = self._model.create_output_buffers(0)

    def embed(self, prefix: str, text: str) -> bytes:
        tokenizer = self._tokenizer
        if min(tokenizer.bos_id(), tokenizer.eos_id(), tokenizer.pad_id()) < 0:
            raise RetrievalRunnerError(
                "tokenizer must define BOS, EOS, and PAD IDs"
            )
        encoded = list(
            tokenizer.encode(prefix + normalized_embedding_text(text), out_type=int)
        )[: SEQUENCE_LENGTH - 2]
        tokens = [tokenizer.bos_id(), *encoded, tokenizer.eos_id()]
        tokens.extend([tokenizer.pad_id()] * (SEQUENCE_LENGTH - len(tokens)))
        token_array = self._numpy.asarray(tokens, dtype=self._numpy.int32)
        self._inputs[0].write(token_array)
        self._model.run_by_index(0, self._inputs, self._outputs)
        vector = self._outputs[0].read(
            EXPECTED_DIMENSION,
            self._numpy.float32,
        )
        if vector.shape != (EXPECTED_DIMENSION,):
            raise RetrievalRunnerError(
                f"expected {EXPECTED_DIMENSION} values, got {vector.shape}"
            )
        if not self._numpy.isfinite(vector).all():
            raise RetrievalRunnerError("embedding contains a non-finite value")
        return vector.astype("<f4", copy=False).tobytes()

    def close(self) -> None:
        for buffer in (*self._inputs, *self._outputs):
            buffer.destroy()


def extract_embeddings(
    inputs_path: Path,
    database_path: Path,
    model_path: Path,
    tokenizer_path: Path,
    batch_size: int = 25,
) -> dict[str, Any]:
    if batch_size < 1:
        raise RetrievalRunnerError("batch size must be positive")
    for path, label in (
        (inputs_path, "embedding inputs"),
        (model_path, "EmbeddingGemma model"),
        (tokenizer_path, "SentencePiece tokenizer"),
    ):
        if not path.is_file():
            raise RetrievalRunnerError(f"{label} was not found: {path}")

    inputs = load_embedding_inputs(inputs_path)
    database_path.parent.mkdir(parents=True, exist_ok=True)
    metadata = {
        "runner_version": RUNNER_VERSION,
        "model_id": MODEL_ID,
        "model_sha256": sha256_file(model_path),
        "tokenizer_sha256": sha256_file(tokenizer_path),
        "inputs_sha256": sha256_file(inputs_path),
        "dimension": str(EXPECTED_DIMENSION),
        "sequence_length": str(SEQUENCE_LENGTH),
        "query_prefix": QUERY_PREFIX,
        "document_prefix": DOCUMENT_PREFIX,
    }
    connection = sqlite3.connect(database_path)
    runtime: EmbeddingGemmaRuntime | None = None
    started = time.perf_counter()
    try:
        initialize_embedding_database(connection, metadata)
        existing = {
            row[0]
            for row in connection.execute(
                "SELECT embedding_id FROM embeddings"
            )
        }
        pending = [
            record for record in inputs
            if record["embedding_id"] not in existing
        ]
        runtime = EmbeddingGemmaRuntime(model_path, tokenizer_path)
        for index, record in enumerate(pending, start=1):
            vector = runtime.embed(record["prefix"], record["text"])
            connection.execute(
                """
                INSERT INTO embeddings(
                  embedding_id, kind, text_sha256, dimension, vector
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    record["embedding_id"],
                    record["kind"],
                    record["text_sha256"],
                    EXPECTED_DIMENSION,
                    vector,
                ),
            )
            if index % batch_size == 0:
                connection.commit()
                print(
                    f"Embedded {len(existing) + index}/{len(inputs)}",
                    flush=True,
                )
        connection.commit()
        completed = int(
            connection.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
        )
        if completed != len(inputs):
            raise RetrievalRunnerError(
                f"expected {len(inputs)} embeddings, found {completed}"
            )
        connection.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('status', 'complete')"
        )
        connection.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('records', ?)",
            (str(completed),),
        )
        connection.commit()
    finally:
        if runtime is not None:
            runtime.close()
        connection.close()

    manifest = {
        "phase": "embedding_extraction_complete",
        "runner_version": RUNNER_VERSION,
        "elapsed_seconds": time.perf_counter() - started,
        "records": len(inputs),
        "database": {
            "path": database_path.name,
            "sha256": sha256_file(database_path),
        },
        "inputs_sha256": sha256_file(inputs_path),
        "model": {
            "id": MODEL_ID,
            "path": str(model_path.resolve()),
            "sha256": metadata["model_sha256"],
        },
        "tokenizer": {
            "path": str(tokenizer_path.resolve()),
            "sha256": metadata["tokenizer_sha256"],
        },
        "runtime": {
            "name": "ai-edge-litert",
            "version": importlib.metadata.version("ai-edge-litert"),
            "backend": "CPU",
            "python": platform.python_version(),
            "platform": platform.platform(),
        },
    }
    prepare.write_json_atomic(
        database_path.with_suffix(".manifest.json"),
        manifest,
    )
    return manifest


class EmbeddingStore:
    def __init__(self, path: Path) -> None:
        if not path.is_file():
            raise RetrievalRunnerError(f"embedding database was not found: {path}")
        self._connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        metadata = dict(
            self._connection.execute("SELECT key, value FROM metadata")
        )
        required = {
            "status": "complete",
            "model_id": MODEL_ID,
            "dimension": str(EXPECTED_DIMENSION),
            "sequence_length": str(SEQUENCE_LENGTH),
            "query_prefix": QUERY_PREFIX,
            "document_prefix": DOCUMENT_PREFIX,
        }
        for key, value in required.items():
            if metadata.get(key) != value:
                raise RetrievalRunnerError(
                    f"embedding database has invalid {key!r} metadata"
                )
        self.metadata = metadata

    def vector(self, kind: str, text: str) -> tuple[float, ...]:
        identifier = embedding_id(kind, text)
        row = self._connection.execute(
            """
            SELECT kind, text_sha256, dimension, vector
            FROM embeddings
            WHERE embedding_id = ?
            """,
            (identifier,),
        ).fetchone()
        if row is None:
            raise RetrievalRunnerError(f"missing embedding: {identifier}")
        normalized = normalized_embedding_text(text)
        expected_text_sha = hashlib.sha256(
            normalized.encode("utf-8")
        ).hexdigest()
        kind_value, text_sha, dimension, blob = row
        if (
            kind_value != kind
            or text_sha != expected_text_sha
            or dimension != EXPECTED_DIMENSION
            or len(blob) != EXPECTED_DIMENSION * 4
        ):
            raise RetrievalRunnerError(
                f"malformed embedding record: {identifier}"
            )
        values = tuple(
            value[0] for value in struct.iter_unpack("<f", blob)
        )
        if any(not math.isfinite(value) for value in values):
            raise RetrievalRunnerError(
                f"non-finite embedding record: {identifier}"
            )
        return values

    def close(self) -> None:
        self._connection.close()


def float32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def cosine_similarity(
    left: Sequence[float],
    right: Sequence[float],
) -> float:
    if not left or not right:
        raise RetrievalRunnerError("embedding vectors must not be empty")
    if len(left) != len(right):
        raise RetrievalRunnerError("embedding vector dimensions differ")
    dot = 0.0
    left_squared = 0.0
    right_squared = 0.0
    for index, (left_value, right_value) in enumerate(
        zip(left, right, strict=True)
    ):
        if not math.isfinite(left_value) or not math.isfinite(right_value):
            raise RetrievalRunnerError(
                f"embedding contains a non-finite value at {index}"
            )
        dot += left_value * right_value
        left_squared += left_value * left_value
        right_squared += right_value * right_value
    if left_squared <= 0 or right_squared <= 0:
        raise RetrievalRunnerError("embedding vector has zero magnitude")
    similarity = dot / math.sqrt(left_squared * right_squared)
    return float32(min(1.0, max(-1.0, similarity)))


def normalized_dedup_text(text: str) -> str:
    return " ".join(
        unicodedata.normalize("NFKC", text).split()
    )


def candidates_for_record(record: dict[str, Any]) -> list[Candidate]:
    candidates: list[Candidate] = []
    for session in record["history"]:
        timestamp = prepare.parse_timestamp(session["timestamp"])
        for turn in session["turns"]:
            candidates.append(
                Candidate(
                    turn_id=turn["turn_id"],
                    session_id=session["session_id"],
                    text=turn["content"],
                    timestamp=timestamp,
                )
            )
    return candidates


def rank_record(
    record: dict[str, Any],
    store: EmbeddingStore,
) -> tuple[list[RankedCandidate], list[tuple[str, float]]]:
    query_vector = store.vector("query", record["query"])
    scored: list[tuple[Candidate, float]] = []
    for candidate in candidates_for_record(record):
        score = cosine_similarity(
            query_vector,
            store.vector("document", candidate.text),
        )
        scored.append((candidate, score))

    # Swift uses score descending, occurredAt descending, then ID ascending.
    scored.sort(key=lambda item: item[0].turn_id)
    scored.sort(key=lambda item: item[0].timestamp, reverse=True)
    scored.sort(key=lambda item: item[1], reverse=True)

    deduplicated: list[tuple[Candidate, float]] = []
    seen_texts: set[str] = set()
    for candidate, score in scored:
        normalized = normalized_dedup_text(candidate.text)
        if normalized in seen_texts:
            continue
        seen_texts.add(normalized)
        deduplicated.append((candidate, score))

    ranked = [
        RankedCandidate(candidate=candidate, score=score, rank=index + 1)
        for index, (candidate, score) in enumerate(deduplicated)
    ]
    return ranked, [
        (candidate.turn_id, score) for candidate, score in scored
    ]


def best_rank(ranked_ids: dict[str, int], expected_ids: set[str]) -> int | None:
    ranks = [
        ranked_ids[identifier]
        for identifier in expected_ids
        if identifier in ranked_ids
    ]
    return min(ranks) if ranks else None


def score_record(
    record: dict[str, Any],
    ranked: Sequence[RankedCandidate],
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    expected = record["expected"]
    ranked_ids = {
        candidate.candidate.turn_id: candidate.rank for candidate in ranked
    }
    gold = set(expected["gold_evidence_turn_ids"])
    score: dict[str, Any] = {
        "top_score": ranked[0].score if ranked else None,
    }
    if record["axis"] == "B":
        best_gold = best_rank(ranked_ids, gold)
        score.update(
            {
                "best_gold_rank": best_gold,
                "reciprocal_rank": 0.0 if best_gold is None else 1 / best_gold,
                "hit_at_k": {
                    str(k): best_gold is not None and best_gold <= k
                    for k in cutoffs
                },
                "gold_recall_at_k": {
                    str(k): sum(
                        ranked_ids.get(identifier, math.inf) <= k
                        for identifier in gold
                    ) / len(gold)
                    for k in cutoffs
                },
            }
        )
    elif record["axis"] == "C":
        status = expected["evaluation_status"]
        score["evaluation_status"] = status
        if status == "excluded":
            return score
        target = set(expected["target_evidence_turn_ids"])
        competing = set(expected["competing_evidence_turn_ids"])
        best_target = best_rank(ranked_ids, target)
        best_competing = best_rank(ranked_ids, competing)
        score.update(
            {
                "best_target_rank": best_target,
                "best_competing_rank": best_competing,
                "reciprocal_rank": (
                    0.0 if best_target is None else 1 / best_target
                ),
                "target_hit_at_k": {
                    str(k): best_target is not None and best_target <= k
                    for k in cutoffs
                },
                "target_recall_at_k": {
                    str(k): sum(
                        ranked_ids.get(identifier, math.inf) <= k
                        for identifier in target
                    ) / len(target)
                    for k in cutoffs
                },
                "target_before_competing": (
                    None if not competing else (
                        best_target is not None
                        and (
                            best_competing is None
                            or best_target < best_competing
                        )
                    )
                ),
            }
        )
    return score


def mean(values: Sequence[float]) -> float | None:
    return None if not values else sum(values) / len(values)


def describe(values: Sequence[float]) -> dict[str, Any]:
    if not values:
        return {"count": 0}
    ordered = sorted(values)

    def quantile(fraction: float) -> float:
        position = (len(ordered) - 1) * fraction
        lower = math.floor(position)
        upper = math.ceil(position)
        if lower == upper:
            return ordered[lower]
        weight = position - lower
        return ordered[lower] * (1 - weight) + ordered[upper] * weight

    return {
        "count": len(ordered),
        "min": ordered[0],
        "p25": quantile(0.25),
        "median": quantile(0.5),
        "p75": quantile(0.75),
        "max": ordered[-1],
        "mean": mean(ordered),
    }


def roc_auc(
    positive_scores: Sequence[float],
    negative_scores: Sequence[float],
) -> float:
    if not positive_scores or not negative_scores:
        raise RetrievalRunnerError("AUROC requires positive and negative scores")
    wins = 0.0
    for positive in positive_scores:
        for negative in negative_scores:
            if positive > negative:
                wins += 1
            elif positive == negative:
                wins += 0.5
    return wins / (len(positive_scores) * len(negative_scores))


def threshold_sweep(
    positive_scores: Sequence[float],
    negative_scores: Sequence[float],
) -> list[dict[str, Any]]:
    thresholds = sorted(
        set(positive_scores) | set(negative_scores),
        reverse=True,
    )
    return [
        {
            "threshold": threshold,
            "true_positive_rate": sum(
                score >= threshold for score in positive_scores
            ) / len(positive_scores),
            "false_positive_rate": sum(
                score >= threshold for score in negative_scores
            ) / len(negative_scores),
            "true_positives": sum(
                score >= threshold for score in positive_scores
            ),
            "false_positives": sum(
                score >= threshold for score in negative_scores
            ),
        }
        for threshold in thresholds
    ]


def summarize(
    rows: Sequence[dict[str, Any]],
    cutoffs: Sequence[int],
    candidate_scores: dict[str, list[float]],
) -> dict[str, Any]:
    by_axis = {
        axis: [row for row in rows if row["axis"] == axis]
        for axis in RETRIEVAL_AXES
    }
    b_rows = by_axis["B"]
    c_rows = by_axis["C"]
    c_scored_rows = [
        row for row in c_rows if row["evaluation_status"] == "scored"
    ]
    c_excluded_rows = [
        row for row in c_rows if row["evaluation_status"] == "excluded"
    ]
    d_rows = by_axis["D"]
    positive_scores = [
        row["score"]["top_score"] for row in (*b_rows, *c_scored_rows)
    ]
    negative_scores = [row["score"]["top_score"] for row in d_rows]

    b_summary = {
        "cases": len(b_rows),
        "any_gold_hit_at_k": {
            str(k): mean([
                float(row["score"]["hit_at_k"][str(k)])
                for row in b_rows
            ])
            for k in cutoffs
        },
        "best_gold_mrr": mean([
            row["score"]["reciprocal_rank"] for row in b_rows
        ]),
        "gold_recall_at_k": {
            str(k): mean([
                row["score"]["gold_recall_at_k"][str(k)]
                for row in b_rows
            ])
            for k in cutoffs
        },
    }
    c_summary: dict[str, Any] = {
        "cases": len(c_rows),
        "scored_cases": len(c_scored_rows),
        "excluded_cases": len(c_excluded_rows),
        "exclusions": [
            {
                "case_id": row["case_id"],
                "reason": row["exclusion_reason"],
            }
            for row in c_excluded_rows
        ],
        "overall": {
            "target_hit_at_k": {
                str(k): mean([
                    float(row["score"]["target_hit_at_k"][str(k)])
                    for row in c_scored_rows
                ])
                for k in cutoffs
            },
            "best_target_mrr": mean([
                row["score"]["reciprocal_rank"] for row in c_scored_rows
            ]),
            "target_recall_at_k": {
                str(k): mean([
                    row["score"]["target_recall_at_k"][str(k)]
                    for row in c_scored_rows
                ])
                for k in cutoffs
            },
        },
    }
    for subtype in (
        "current_state",
        "historical_state",
        "multi_state",
        "single_state",
    ):
        subset = [
            row for row in c_scored_rows if row["subtype"] == subtype
        ]
        c_summary[subtype] = {
            "cases": len(subset),
            "target_hit_at_k": {
                str(k): mean([
                    float(row["score"]["target_hit_at_k"][str(k)])
                    for row in subset
                ])
                for k in cutoffs
            },
            "best_target_mrr": mean([
                row["score"]["reciprocal_rank"] for row in subset
            ]),
            "target_recall_at_k": {
                str(k): mean([
                    row["score"]["target_recall_at_k"][str(k)]
                    for row in subset
                ])
                for k in cutoffs
            },
        }
        comparable = [
            row
            for row in subset
            if row["score"]["target_before_competing"] is not None
        ]
        c_summary[subtype]["target_before_competing"] = mean([
            float(row["score"]["target_before_competing"])
            for row in comparable
        ])

    d_summary: dict[str, Any] = {"cases": len(d_rows)}
    for subtype in ("partial_evidence", "absent_evidence"):
        subset_scores = [
            row["score"]["top_score"]
            for row in d_rows
            if row["subtype"] == subtype
        ]
        d_summary[subtype] = describe(subset_scores)

    return {
        "retrieval_cases": len(rows),
        "B": b_summary,
        "C": c_summary,
        "D": d_summary,
        "query_level_gate": {
            "positive_cases": len(positive_scores),
            "negative_cases": len(negative_scores),
            "auroc": roc_auc(positive_scores, negative_scores),
            "threshold_policy": (
                "Sweep only; no operating threshold is selected on v0."
            ),
            "threshold_sweep": threshold_sweep(
                positive_scores,
                negative_scores,
            ),
        },
        "candidate_score_distributions": {
            label: describe(scores)
            for label, scores in candidate_scores.items()
        },
    }


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    prepare.write_jsonl_atomic(path, records)


def run_retrieval(
    artifact_dir: Path,
    embeddings_path: Path,
    output_dir: Path,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    normalized_cutoffs = sorted(set(cutoffs))
    if not normalized_cutoffs or normalized_cutoffs[0] < 1:
        raise RetrievalRunnerError("retrieval cutoffs must be positive")
    if output_dir.exists():
        raise RetrievalRunnerError(
            f"output directory already exists: {output_dir}"
        )

    store = EmbeddingStore(embeddings_path)
    rows: list[dict[str, Any]] = []
    candidate_scores: dict[str, list[float]] = {
        "gold": [],
        "non_gold": [],
        "target": [],
        "competing": [],
        "context": [],
    }
    try:
        for record in iter_retrieval_records(artifact_dir):
            ranked, raw_scores = rank_record(record, store)
            expected = record["expected"]
            gold = set(expected["gold_evidence_turn_ids"])
            status = expected.get("evaluation_status")
            target = set(expected.get("target_evidence_turn_ids", []))
            competing = set(expected.get("competing_evidence_turn_ids", []))
            context = set(expected.get("context_evidence_turn_ids", []))
            for turn_id_value, score in raw_scores:
                candidate_scores[
                    "gold" if turn_id_value in gold else "non_gold"
                ].append(score)
                if status == "scored":
                    if turn_id_value in target:
                        candidate_scores["target"].append(score)
                    if turn_id_value in competing:
                        candidate_scores["competing"].append(score)
                    if turn_id_value in context:
                        candidate_scores["context"].append(score)

            row = {
                "case_id": record["case_id"],
                "axis": record["axis"],
                "task": record["task"],
                "subtype": (
                    expected.get("temporal_subtype")
                    if record["axis"] == "C"
                    else expected.get("subtype")
                ),
                "evaluation_status": status,
                "exclusion_reason": expected.get("exclusion_reason"),
                "score": score_record(
                    record,
                    ranked,
                    normalized_cutoffs,
                ),
                "top_k": [
                    {
                        "rank": candidate.rank,
                        "turn_id": candidate.candidate.turn_id,
                        "session_id": candidate.candidate.session_id,
                        "score": candidate.score,
                    }
                    for candidate in ranked[: normalized_cutoffs[-1]]
                ],
            }
            rows.append(row)
    finally:
        store.close()

    summary = {
        "phase": "retrieval_baseline_complete",
        "runner_version": RUNNER_VERSION,
        "benchmark_version": prepare.load_manifest()["version"],
        "baseline_contract": {
            "swift_source": (
                "ios/EdgeLLM/Sources/EdgeLLM/Memory/"
                "DenseMemoryRetriever.swift"
            ),
            "similarity": "cosine",
            "sort": "score desc, occurredAt desc, observation ID asc",
            "observation_id": "benchmark turn_id",
            "dedup": "NFKC + whitespace collapse after sorting",
            "admission": "bypassed for B-D",
            "cutoffs": normalized_cutoffs,
            "reader": "not run",
        },
        "inputs": {
            "artifact_manifest_sha256": sha256_file(
                artifact_dir / "artifact_manifest.json"
            ),
            "embeddings_sha256": sha256_file(embeddings_path),
            "embedding_model_id": MODEL_ID,
        },
        "metrics": summarize(rows, normalized_cutoffs, candidate_scores),
    }

    output_dir.mkdir(parents=True)
    write_jsonl(output_dir / "retrieval_results.jsonl", rows)
    prepare.write_json_atomic(
        output_dir / "retrieval_summary.json",
        summary,
    )
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    prepare_parser = commands.add_parser(
        "prepare-embeddings",
        help="Export deduplicated query/document texts for EmbeddingGemma",
    )
    prepare_parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=DEFAULT_ARTIFACT_DIR,
    )
    prepare_parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_INPUTS_PATH,
    )

    extract_parser = commands.add_parser(
        "extract-embeddings",
        help="Run the exact iOS EmbeddingGemma prefix contract on macOS",
    )
    extract_parser.add_argument("--inputs", type=Path, default=DEFAULT_INPUTS_PATH)
    extract_parser.add_argument(
        "--database",
        type=Path,
        default=DEFAULT_EMBEDDINGS_PATH,
    )
    extract_parser.add_argument("--model", type=Path, required=True)
    extract_parser.add_argument("--tokenizer", type=Path, required=True)
    extract_parser.add_argument("--batch-size", type=int, default=25)

    run_parser = commands.add_parser(
        "run",
        help="Run Swift-equivalent dense retrieval and score B-D",
    )
    run_parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=DEFAULT_ARTIFACT_DIR,
    )
    run_parser.add_argument(
        "--embeddings",
        type=Path,
        default=DEFAULT_EMBEDDINGS_PATH,
    )
    run_parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_RESULTS_DIR,
    )
    run_parser.add_argument(
        "--cutoffs",
        type=int,
        nargs="+",
        default=[1, 3, 5, 10, 20],
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "prepare-embeddings":
            result = prepare_embedding_inputs(
                arguments.artifact_dir,
                arguments.output,
            )
        elif arguments.command == "extract-embeddings":
            result = extract_embeddings(
                arguments.inputs,
                arguments.database,
                arguments.model,
                arguments.tokenizer,
                arguments.batch_size,
            )
        else:
            result = run_retrieval(
                arguments.artifact_dir,
                arguments.embeddings,
                arguments.output_dir,
                arguments.cutoffs,
            )
    except (
        RetrievalRunnerError,
        prepare.BenchmarkError,
        OSError,
        sqlite3.Error,
        KeyError,
        TypeError,
        ValueError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(prepare.canonical_json(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
