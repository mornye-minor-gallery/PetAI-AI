#!/usr/bin/env python3
"""Evaluate deterministic timestamp-aware reranking on EdgeMemBench axis C.

The frozen Dense Top-20 candidate set is the only input to this reranker.
Temporal intent is inferred from the query text without reading benchmark gold
labels. The alpha grid is an exploratory sweep on v0 test data; this runner
does not select or publish an operating value.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Sequence

import prepare
import retrieval_runner as dense


RUNNER_VERSION = "0.1.0"
DEFAULT_ALPHAS = (0.0, 0.01, 0.025, 0.05, 0.10)
DEFAULT_TOP_K = 20
DEFAULT_OUTPUT_DIR = (
    dense.DEFAULT_RETRIEVAL_DIR / "temporal-rerank-v1"
)


class TemporalRerankError(RuntimeError):
    """Raised when the temporal reranking contract is violated."""


class TemporalIntent(str, Enum):
    CURRENT = "current"
    HISTORICAL = "historical"
    MULTI = "multi"
    UNSPECIFIED = "unspecified"


@dataclass(frozen=True)
class TemporalIntentResult:
    intent: TemporalIntent
    matched_rule: str
    cutoff_month_day: tuple[int, int] | None = None


@dataclass(frozen=True)
class TemporalCandidate:
    dense_candidate: dense.RankedCandidate
    temporal_score: float
    final_score: float
    reranked_rank: int


MULTI_PATTERNS = (
    (
        "multi_previous_now",
        re.compile(
            r"\b(previous(?:ly)?|before|initial(?:ly)?)\b.*"
            r"\b(now|current(?:ly)?)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "multi_start_now",
        re.compile(
            r"\b(start(?:ed|ing)?|first)\b.*\bnow\b",
            re.IGNORECASE,
        ),
    ),
    (
        "multi_change",
        re.compile(
            r"\b(switch(?:ed)?|increase(?:d)?|decrease(?:d)?|"
            r"change(?:d)?|more frequently than|less frequently than)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "multi_korean",
        re.compile(
            r"(어떻게\s*바뀌|변화|예전.*(?:지금|현재)|"
            r"(?:지금|현재).*예전|늘었|줄었)"
        ),
    ),
)

HISTORICAL_PATTERNS = (
    (
        "historical_explicit",
        re.compile(
            r"\b(previous|previously|initially|earlier|former|old|"
            r"before|at the time|first three months)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "historical_korean",
        re.compile(r"(예전|이전|과거|그때|처음|당시|전에)"),
    ),
)

CURRENT_PATTERNS = (
    (
        "current_explicit",
        re.compile(
            r"\b(current|currently|now|recent|recently|latest|"
            r"most recent|so far|these days|usually)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "current_cumulative",
        re.compile(
            r"\b(have I|has my|have my|do I|does my|did I finish|"
            r"since I|how long have|how many .* have)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "current_korean",
        re.compile(r"(현재|지금|요즘|최근|지금까지|현재까지|보통)"),
    ),
)

MONTH_DAY_PATTERN = re.compile(
    r"(?<!\d)(1[0-2]|0?[1-9])\s*/\s*(3[01]|[12]\d|0?[1-9])(?!\d)"
)


def infer_temporal_intent(query: str) -> TemporalIntentResult:
    normalized = " ".join(query.split())
    month_day_match = MONTH_DAY_PATTERN.search(normalized)
    cutoff = (
        (int(month_day_match.group(1)), int(month_day_match.group(2)))
        if month_day_match
        else None
    )
    for rule, pattern in MULTI_PATTERNS:
        if pattern.search(normalized):
            return TemporalIntentResult(
                TemporalIntent.MULTI,
                rule,
                cutoff,
            )
    for rule, pattern in HISTORICAL_PATTERNS:
        if pattern.search(normalized):
            return TemporalIntentResult(
                TemporalIntent.HISTORICAL,
                rule,
                cutoff,
            )
    for rule, pattern in CURRENT_PATTERNS:
        if pattern.search(normalized):
            return TemporalIntentResult(
                TemporalIntent.CURRENT,
                rule,
                cutoff,
            )
    return TemporalIntentResult(
        TemporalIntent.UNSPECIFIED,
        "fail_closed_no_temporal_marker",
        cutoff,
    )


def normalize_recency(
    candidates: Sequence[dense.RankedCandidate],
) -> dict[str, float]:
    if not candidates:
        return {}
    numeric = [
        timestamp_value(candidate.candidate.timestamp)
        for candidate in candidates
    ]
    minimum = min(numeric)
    maximum = max(numeric)
    if minimum == maximum:
        return {
            candidate.candidate.turn_id: 0.5 for candidate in candidates
        }
    return {
        candidate.candidate.turn_id: (value - minimum) / (maximum - minimum)
        for candidate, value in zip(candidates, numeric, strict=True)
    }


def timestamp_value(value: tuple[int, int, int, int, int]) -> float:
    return datetime(*value, tzinfo=timezone.utc).timestamp()


def historical_cutoff_score(
    candidate: dense.RankedCandidate,
    candidates: Sequence[dense.RankedCandidate],
    cutoff_month_day: tuple[int, int],
) -> float:
    years = [item.candidate.timestamp[0] for item in candidates]
    cutoff = datetime(
        max(years),
        *cutoff_month_day,
        tzinfo=timezone.utc,
    ).timestamp()
    value = timestamp_value(candidate.candidate.timestamp)
    eligible = [
        timestamp_value(item.candidate.timestamp)
        for item in candidates
        if timestamp_value(item.candidate.timestamp) <= cutoff
    ]
    if value > cutoff or not eligible:
        return 0.0
    oldest = min(eligible)
    if cutoff == oldest:
        return 1.0
    return (value - oldest) / (cutoff - oldest)


def temporal_scores(
    candidates: Sequence[dense.RankedCandidate],
    intent: TemporalIntentResult,
) -> dict[str, float]:
    recency = normalize_recency(candidates)
    if intent.intent is TemporalIntent.CURRENT:
        return recency
    if intent.intent is TemporalIntent.HISTORICAL:
        if intent.cutoff_month_day is not None:
            return {
                candidate.candidate.turn_id: historical_cutoff_score(
                    candidate,
                    candidates,
                    intent.cutoff_month_day,
                )
                for candidate in candidates
            }
        return {
            turn_id: 1.0 - score for turn_id, score in recency.items()
        }
    # A single scalar time direction cannot safely solve multi-state queries.
    # Unspecified queries also fail closed to the original Dense order.
    return {candidate.candidate.turn_id: 0.0 for candidate in candidates}


def rerank_candidates(
    candidates: Sequence[dense.RankedCandidate],
    intent: TemporalIntentResult,
    alpha: float,
) -> list[TemporalCandidate]:
    if alpha < 0 or not math.isfinite(alpha):
        raise TemporalRerankError("alpha must be finite and non-negative")
    scores = temporal_scores(candidates, intent)
    provisional = [
        (
            candidate,
            scores[candidate.candidate.turn_id],
            candidate.score
            + alpha * scores[candidate.candidate.turn_id],
        )
        for candidate in candidates
    ]
    provisional.sort(key=lambda item: item[0].rank)
    provisional.sort(key=lambda item: item[2], reverse=True)
    return [
        TemporalCandidate(
            dense_candidate=candidate,
            temporal_score=temporal_score,
            final_score=final_score,
            reranked_rank=index,
        )
        for index, (candidate, temporal_score, final_score) in enumerate(
            provisional,
            start=1,
        )
    ]


def as_dense_ranked(
    candidates: Sequence[TemporalCandidate],
) -> list[dense.RankedCandidate]:
    return [
        dense.RankedCandidate(
            candidate=item.dense_candidate.candidate,
            score=item.dense_candidate.score,
            rank=item.reranked_rank,
        )
        for item in candidates
    ]


def mean(values: Sequence[float]) -> float | None:
    return statistics_fmean(values) if values else None


def statistics_fmean(values: Sequence[float]) -> float:
    return sum(values) / len(values)


def summarize_rows(
    rows: Sequence[dict[str, Any]],
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    scored = [
        row for row in rows if row["evaluation_status"] == "scored"
    ]
    result: dict[str, Any] = {
        "cases": len(rows),
        "scored_cases": len(scored),
        "intent_counts": dict(sorted(
            {
                intent: sum(row["inferred_intent"] == intent for row in rows)
                for intent in {row["inferred_intent"] for row in rows}
            }.items()
        )),
        "intent_agreement_with_annotation": mean([
            float(
                (
                    row["inferred_intent"] == "current"
                    and row["annotated_subtype"] == "current_state"
                )
                or (
                    row["inferred_intent"] == "historical"
                    and row["annotated_subtype"] == "historical_state"
                )
                or (
                    row["inferred_intent"] == "multi"
                    and row["annotated_subtype"] == "multi_state"
                )
            )
            for row in scored
            if row["annotated_subtype"] != "single_state"
        ]),
    }
    for alpha_key in rows[0]["scores"] if rows else []:
        alpha_summary: dict[str, Any] = {
            "overall": aggregate_score_rows(scored, alpha_key, cutoffs),
        }
        for subtype in (
            "current_state",
            "historical_state",
            "multi_state",
            "single_state",
        ):
            subset = [
                row for row in scored
                if row["annotated_subtype"] == subtype
            ]
            alpha_summary[subtype] = aggregate_score_rows(
                subset,
                alpha_key,
                cutoffs,
            )
        if alpha_key != "0":
            alpha_summary["rank_changes_vs_dense"] = compare_to_dense(
                scored,
                alpha_key,
            )
        result.setdefault("alphas", {})[alpha_key] = alpha_summary
    return result


def aggregate_score_rows(
    rows: Sequence[dict[str, Any]],
    alpha_key: str,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    if not rows:
        return {"cases": 0}
    return {
        "cases": len(rows),
        "target_hit_at_k": {
            str(k): mean([
                float(row["scores"][alpha_key]["target_hit_at_k"][str(k)])
                for row in rows
            ])
            for k in cutoffs
        },
        "target_recall_at_k": {
            str(k): mean([
                row["scores"][alpha_key]["target_recall_at_k"][str(k)]
                for row in rows
            ])
            for k in cutoffs
        },
        "best_target_mrr": mean([
            row["scores"][alpha_key]["reciprocal_rank"] for row in rows
        ]),
        "target_before_competing": mean([
            float(row["scores"][alpha_key]["target_before_competing"])
            for row in rows
            if row["scores"][alpha_key]["target_before_competing"] is not None
        ]),
    }


def compare_to_dense(
    rows: Sequence[dict[str, Any]],
    alpha_key: str,
) -> dict[str, int]:
    improved = regressed = unchanged = 0
    for row in rows:
        baseline = row["scores"]["0"]["best_target_rank"]
        candidate = row["scores"][alpha_key]["best_target_rank"]
        if candidate < baseline:
            improved += 1
        elif candidate > baseline:
            regressed += 1
        else:
            unchanged += 1
    return {
        "improved_best_target_rank": improved,
        "regressed_best_target_rank": regressed,
        "unchanged_best_target_rank": unchanged,
    }


def alpha_key(value: float) -> str:
    return f"{value:g}"


def run(
    *,
    artifact_dir: Path,
    embeddings_path: Path,
    output_dir: Path,
    alphas: Sequence[float],
    top_k: int,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    if output_dir.exists():
        raise TemporalRerankError(
            f"output directory already exists: {output_dir}"
        )
    normalized_alphas = sorted(set(alphas))
    if not normalized_alphas or normalized_alphas[0] != 0.0:
        raise TemporalRerankError("alpha sweep must include Dense alpha 0")
    normalized_cutoffs = sorted(set(cutoffs))
    if top_k < max(normalized_cutoffs):
        raise TemporalRerankError("top-k must cover every scoring cutoff")

    store = dense.EmbeddingStore(embeddings_path)
    rows: list[dict[str, Any]] = []
    try:
        records = prepare.read_jsonl(
            artifact_dir / prepare.OUTPUT_FILES["C"]
        )
        for record in records:
            dense_ranked, _ = dense.rank_record(record, store)
            candidate_pool = dense_ranked[:top_k]
            intent = infer_temporal_intent(record["query"])
            expected = record["expected"]
            row: dict[str, Any] = {
                "case_id": record["case_id"],
                "query": record["query"],
                "evaluation_status": expected["evaluation_status"],
                "annotated_subtype": expected["temporal_subtype"],
                "inferred_intent": intent.intent.value,
                "matched_rule": intent.matched_rule,
                "cutoff_month_day": intent.cutoff_month_day,
                "candidate_turn_ids": [
                    item.candidate.turn_id for item in candidate_pool
                ],
                "scores": {},
                "rankings": {},
            }
            for alpha in normalized_alphas:
                reranked = rerank_candidates(candidate_pool, intent, alpha)
                ranked_for_score = as_dense_ranked(reranked)
                row["scores"][alpha_key(alpha)] = dense.score_record(
                    record,
                    ranked_for_score,
                    normalized_cutoffs,
                )
                row["rankings"][alpha_key(alpha)] = [
                    {
                        "rank": item.reranked_rank,
                        "turn_id": item.dense_candidate.candidate.turn_id,
                        "dense_rank": item.dense_candidate.rank,
                        "dense_score": item.dense_candidate.score,
                        "temporal_score": item.temporal_score,
                        "final_score": item.final_score,
                        "timestamp": list(
                            item.dense_candidate.candidate.timestamp
                        ),
                    }
                    for item in reranked
                ]
                if {
                    item["turn_id"]
                    for item in row["rankings"][alpha_key(alpha)]
                } != set(row["candidate_turn_ids"]):
                    raise TemporalRerankError(
                        f"{record['case_id']}: candidate set changed"
                    )
            rows.append(row)
    finally:
        store.close()

    summary = {
        "phase": "temporal_rerank_sweep_complete",
        "runner_version": RUNNER_VERSION,
        "benchmark_version": prepare.load_manifest()["version"],
        "contract": {
            "candidate_source": f"frozen Dense Top-{top_k}",
            "candidate_set_mutation": "forbidden",
            "intent_source": "query regex only; benchmark labels forbidden",
            "unspecified_policy": "preserve Dense order",
            "multi_state_policy": "preserve Dense order in v1",
            "score": "dense cosine + alpha * normalized temporal score",
            "alpha_policy": (
                "exploratory sweep only; no v0 test operating value selected"
            ),
            "alphas": normalized_alphas,
            "cutoffs": normalized_cutoffs,
        },
        "inputs": {
            "artifact_manifest_sha256": dense.sha256_file(
                artifact_dir / "artifact_manifest.json"
            ),
            "embeddings_sha256": dense.sha256_file(embeddings_path),
        },
        "metrics": summarize_rows(rows, normalized_cutoffs),
        "limitations": [
            (
                "Regex rules were authored after inspecting repo-local C "
                "queries, so intent agreement is exploratory rather than a "
                "held-out generalization estimate."
            ),
            (
                "Historical age direction is not a structured conflict "
                "resolver and can promote an unrelated old candidate."
            ),
            (
                "Multi-state questions are unchanged because one scalar "
                "recency direction cannot select both states safely."
            ),
            "No alpha is selected on the v0 test set.",
        ],
    }
    output_dir.mkdir(parents=True)
    prepare.write_jsonl_atomic(
        output_dir / "temporal_rerank_results.jsonl",
        rows,
    )
    prepare.write_json_atomic(
        output_dir / "temporal_rerank_summary.json",
        summary,
    )
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=prepare.DEFAULT_ARTIFACT_DIR,
    )
    parser.add_argument(
        "--embeddings",
        type=Path,
        default=dense.DEFAULT_EMBEDDINGS_PATH,
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
    )
    parser.add_argument(
        "--alphas",
        type=float,
        nargs="+",
        default=list(DEFAULT_ALPHAS),
    )
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    parser.add_argument(
        "--cutoffs",
        type=int,
        nargs="+",
        default=[1, 3, 5, 10, 20],
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        summary = run(
            artifact_dir=arguments.artifact_dir,
            embeddings_path=arguments.embeddings,
            output_dir=arguments.output_dir,
            alphas=arguments.alphas,
            top_k=arguments.top_k,
            cutoffs=arguments.cutoffs,
        )
    except (
        TemporalRerankError,
        dense.RetrievalRunnerError,
        prepare.BenchmarkError,
        OSError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(prepare.canonical_json(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
