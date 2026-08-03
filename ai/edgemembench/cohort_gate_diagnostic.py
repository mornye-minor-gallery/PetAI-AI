#!/usr/bin/env python3
"""Measure mutual-nearest and margin abstention for local cohorts.

The runner reads the frozen EdgeMemBench embedding SQLite database. It does
not invoke EmbeddingGemma or any reader model. All gate sweeps on v0 are
diagnostic only and must not select an operating threshold.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import cohort_similarity_runner as cohort_labels
import cohort_temporal_resolver as resolver
import prepare
import retrieval_runner as dense


ROOT = Path(__file__).resolve().parent
RUNNER_VERSION = "0.1.0"
DEFAULT_TOP_K = 20
DEFAULT_QUERY_SCORE_DELTA = 0.05
DEFAULT_MARGINS = (0.0, 0.01, 0.02, 0.03, 0.05, 0.075, 0.10, 0.15)
DEFAULT_OUTPUT_DIR = dense.DEFAULT_RETRIEVAL_DIR / "cohort-gate-diagnostic-v1"
DEFAULT_BASE_ANNOTATIONS = ROOT / "data" / "cohort_pair_annotations.jsonl"
DEFAULT_ABC_ANNOTATIONS = (
    ROOT / "data" / "cohort_abc_candidate_annotations.jsonl"
)


class CohortGateError(RuntimeError):
    """Raised when a cohort gate diagnostic contract is violated."""


@dataclass(frozen=True)
class PartnerProfile:
    anchor_id: str
    partner_id: str | None
    member_ids: tuple[str, ...]
    pair_cosine: float | None
    second_pair_cosine: float | None
    pair_margin: float | None
    mutual_nearest: bool
    query_score_gap: float | None
    band_size: int


@dataclass(frozen=True)
class GateConfig:
    config_id: str
    require_mutual: bool
    minimum_margin: float | None


def candidate_pair_cosine(
    left: dense.RankedCandidate,
    right: dense.RankedCandidate,
    store: dense.EmbeddingStore,
) -> float:
    return dense.cosine_similarity(
        store.vector("document", left.candidate.text),
        store.vector("document", right.candidate.text),
    )


def strongest_partner(
    anchor: dense.RankedCandidate,
    candidates: Sequence[dense.RankedCandidate],
    store: dense.EmbeddingStore,
) -> tuple[dense.RankedCandidate, float] | None:
    alternatives = [
        candidate
        for candidate in candidates
        if candidate.candidate.turn_id != anchor.candidate.turn_id
    ]
    if not alternatives:
        return None
    scored = [
        (candidate_pair_cosine(anchor, candidate, store), candidate)
        for candidate in alternatives
    ]
    scored.sort(key=lambda item: item[1].candidate.turn_id)
    cosine, partner = max(
        scored,
        key=lambda item: (item[0], item[1].score),
    )
    return partner, cosine


def partner_profile(
    candidates: Sequence[dense.RankedCandidate],
    store: dense.EmbeddingStore,
    query_score_delta: float,
) -> PartnerProfile | None:
    if query_score_delta < 0 or not math.isfinite(query_score_delta):
        raise CohortGateError("query score delta must be finite and non-negative")
    if not candidates:
        return None
    anchor = candidates[0]
    band = [
        candidate
        for candidate in candidates
        if anchor.score - candidate.score <= query_score_delta + 1e-12
    ]
    partner_scores = [
        (candidate_pair_cosine(anchor, candidate, store), candidate)
        for candidate in band
        if candidate.candidate.turn_id != anchor.candidate.turn_id
    ]
    if not partner_scores:
        return PartnerProfile(
            anchor.candidate.turn_id,
            None,
            (anchor.candidate.turn_id,),
            None,
            None,
            None,
            False,
            None,
            len(band),
        )
    partner_scores.sort(key=lambda item: item[1].candidate.turn_id)
    ordered = sorted(
        partner_scores,
        key=lambda item: (item[0], item[1].score, item[1].candidate.turn_id),
        reverse=True,
    )
    pair_cosine, partner = ordered[0]
    second = ordered[1][0] if len(ordered) >= 2 else None
    margin = None if second is None else pair_cosine - second
    reverse = strongest_partner(partner, band, store)
    mutual = (
        reverse is not None
        and reverse[0].candidate.turn_id == anchor.candidate.turn_id
    )
    return PartnerProfile(
        anchor.candidate.turn_id,
        partner.candidate.turn_id,
        (anchor.candidate.turn_id, partner.candidate.turn_id),
        pair_cosine,
        second,
        margin,
        mutual,
        anchor.score - partner.score,
        len(band),
    )


def gate_configs(margins: Sequence[float]) -> list[GateConfig]:
    normalized = sorted(set(margins))
    if any(value < 0 or not math.isfinite(value) for value in normalized):
        raise CohortGateError("margins must be finite and non-negative")
    configs = [
        GateConfig("baseline", False, None),
        GateConfig("mutual_only", True, None),
    ]
    for margin in normalized:
        label = f"{margin:g}"
        configs.append(GateConfig(f"margin_{label}", False, margin))
        configs.append(GateConfig(f"mutual_margin_{label}", True, margin))
    return configs


def gate_accepts(profile: PartnerProfile, config: GateConfig) -> bool:
    if profile.partner_id is None:
        return False
    if config.require_mutual and not profile.mutual_nearest:
        return False
    if config.minimum_margin is not None:
        if profile.pair_margin is None:
            return False
        if profile.pair_margin + 1e-12 < config.minimum_margin:
            return False
    return True


def accepted_selection(
    profile: PartnerProfile,
    config: GateConfig,
) -> resolver.CohortSelection:
    if not gate_accepts(profile, config):
        return resolver.CohortSelection(
            (),
            profile.anchor_id,
            profile.partner_id,
            profile.pair_cosine,
            profile.query_score_gap,
        )
    return resolver.CohortSelection(
        profile.member_ids,
        profile.anchor_id,
        profile.partner_id,
        profile.pair_cosine,
        profile.query_score_gap,
    )


def annotation_map() -> dict[tuple[str, str, str], dict[str, Any]]:
    return cohort_labels.merge_cohort_annotations(
        cohort_labels.load_cohort_annotations(DEFAULT_BASE_ANNOTATIONS),
        cohort_labels.load_cohort_annotations(DEFAULT_ABC_ANNOTATIONS),
    )


def summarize_config(
    rows: Sequence[dict[str, Any]],
    config: GateConfig,
) -> dict[str, Any]:
    accepted = [row for row in rows if row["configs"][config.config_id]["accepted"]]
    labels = [
        row["configs"][config.config_id]["semantic_label"]
        for row in accepted
    ]
    label_counts = {
        label: sum(value == label for value in labels)
        for label in ("same_cohort", "different_cohort", "ambiguous", "unannotated")
    }
    decided = label_counts["same_cohort"] + label_counts["different_cohort"]
    policy_scores = [row["configs"][config.config_id]["score"] for row in rows]
    dense_scores = [row["dense_score"] for row in rows]
    rank_changes = {"improved": 0, "regressed": 0, "unchanged": 0}
    dense_hit1_regressions = 0
    for baseline, candidate in zip(dense_scores, policy_scores, strict=True):
        old_rank = baseline["best_target_rank"]
        new_rank = candidate["best_target_rank"]
        direction = (
            "improved" if new_rank < old_rank
            else "regressed" if new_rank > old_rank
            else "unchanged"
        )
        rank_changes[direction] += 1
        dense_hit1_regressions += old_rank == 1 and new_rank > 1
    return {
        "config_id": config.config_id,
        "require_mutual": config.require_mutual,
        "minimum_margin": config.minimum_margin,
        "accepted_cases": len(accepted),
        "coverage": len(accepted) / len(rows),
        "semantic_annotation": {
            **label_counts,
            "annotation_coverage": (
                (len(accepted) - label_counts["unannotated"]) / len(accepted)
                if accepted else 0.0
            ),
            "decided_precision": (
                None if decided == 0 else label_counts["same_cohort"] / decided
            ),
        },
        "exact_target_competing_alignment": {
            "cases": sum(
                row["configs"][config.config_id]["exact_gold_aligned"]
                for row in accepted
            ),
            "rate_among_accepted": (
                None
                if not accepted
                else sum(
                    row["configs"][config.config_id]["exact_gold_aligned"]
                    for row in accepted
                ) / len(accepted)
            ),
        },
        "downstream": {
            "hit_at_1": sum(score["target_hit_at_k"]["1"] for score in policy_scores)
            / len(policy_scores),
            "mrr": sum(score["reciprocal_rank"] for score in policy_scores)
            / len(policy_scores),
            "target_before_competing": resolver.mean_optional([
                score["target_before_competing"] for score in policy_scores
            ]),
            "rank_change_vs_dense": rank_changes,
            "dense_hit1_regressions": dense_hit1_regressions,
        },
    }


def run(
    *,
    artifact_dir: Path,
    embeddings_path: Path,
    output_dir: Path,
    query_score_delta: float,
    margins: Sequence[float],
    top_k: int,
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    if output_dir.exists():
        raise CohortGateError(f"output directory already exists: {output_dir}")
    annotations_path = ROOT / "data" / "knowledge_update_annotations.jsonl"
    gold_views = resolver.load_view_contract(
        resolver.DEFAULT_VIEW_CONTRACT_PATH,
        annotations_path,
    )
    semantic_annotations = annotation_map()
    configs = gate_configs(margins)
    records = [
        record
        for record in prepare.read_jsonl(
            artifact_dir / prepare.OUTPUT_FILES["C"]
        )
        if record["expected"]["evaluation_status"] == "scored"
    ]
    store = dense.EmbeddingStore(embeddings_path)
    rows: list[dict[str, Any]] = []
    try:
        for record in records:
            ranked, _ = dense.rank_record(record, store)
            candidates = ranked[:top_k]
            profile = partner_profile(candidates, store, query_score_delta)
            if profile is None:
                raise CohortGateError(f"{record['case_id']}: no Dense candidates")
            inferred = resolver.infer_query_view(record["query"])
            target_or_competing = set(
                record["expected"]["target_evidence_turn_ids"]
            ) | set(record["expected"]["competing_evidence_turn_ids"])
            dense_score = dense.score_record(record, candidates, [1, 2, 3, 5, 10, 20])
            row: dict[str, Any] = {
                "case_id": record["case_id"],
                "query": record["query"],
                "gold_view": gold_views[record["case_id"]].view.value,
                "predicted_view": inferred.view.value,
                "profile": {
                    "anchor_id": profile.anchor_id,
                    "partner_id": profile.partner_id,
                    "pair_cosine": profile.pair_cosine,
                    "second_pair_cosine": profile.second_pair_cosine,
                    "pair_margin": profile.pair_margin,
                    "mutual_nearest": profile.mutual_nearest,
                    "query_score_gap": profile.query_score_gap,
                    "band_size": profile.band_size,
                },
                "dense_score": dense_score,
                "configs": {},
            }
            annotation = (
                None
                if profile.partner_id is None
                else semantic_annotations.get(cohort_labels.annotation_key(
                    record["case_id"],
                    profile.anchor_id,
                    profile.partner_id,
                ))
            )
            semantic_label = "unannotated" if annotation is None else annotation["label"]
            for config in configs:
                selection = accepted_selection(profile, config)
                reranked = resolver.resolve_local(candidates, selection, inferred)
                accepted = gate_accepts(profile, config)
                member_set = set(profile.member_ids)
                row["configs"][config.config_id] = {
                    "accepted": accepted,
                    "semantic_label": semantic_label if accepted else None,
                    "exact_gold_aligned": (
                        accepted
                        and len(member_set) >= 2
                        and member_set.issubset(target_or_competing)
                    ),
                    "score": dense.score_record(
                        record,
                        reranked,
                        [1, 2, 3, 5, 10, 20],
                    ),
                    "top_ids": [item.candidate.turn_id for item in reranked[:5]],
                }
            rows.append(row)
    finally:
        store.close()

    config_summaries = [summarize_config(rows, config) for config in configs]
    summary = {
        "phase": "cohort_gate_diagnostic_complete",
        "runner_version": RUNNER_VERSION,
        "cases": len(rows),
        "contract": {
            "candidate_source": f"frozen Dense Top-{top_k}",
            "query_score_delta": query_score_delta,
            "gate_role": "abstention only; the baseline partner never changes",
            "v0_usage": "retrospective diagnostic only; no gate selected",
            "semantic_label_source": "existing blind AI-assisted annotations when available",
            "answer_bearing_label_source": "manual target/competing partition",
        },
        "inputs": {
            "embeddings_sha256": dense.sha256_file(embeddings_path),
            "base_annotations_sha256": dense.sha256_file(DEFAULT_BASE_ANNOTATIONS),
            "abc_annotations_sha256": dense.sha256_file(DEFAULT_ABC_ANNOTATIONS),
        },
        "configs": config_summaries,
        "limitations": [
            "The diagnostic reuses EdgeMemBench v0 and cannot select a deployment margin.",
            "Semantic annotations do not cover every selected pair.",
            "A same-cohort label does not guarantee that the partner contains the answer-bearing state.",
            "The gate only accepts or rejects the existing partner; it does not repair a wrong partner choice.",
            "No model, new embedding extraction, or reader generation is run.",
        ],
    }
    output_dir.mkdir(parents=True)
    prepare.write_jsonl_atomic(output_dir / "results.jsonl", rows)
    summary["outputs"] = {
        "results_sha256": dense.sha256_file(output_dir / "results.jsonl")
    }
    prepare.write_json_atomic(output_dir / "summary.json", summary)
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, default=prepare.DEFAULT_ARTIFACT_DIR)
    parser.add_argument("--embeddings", type=Path, default=dense.DEFAULT_EMBEDDINGS_PATH)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--query-score-delta",
        type=float,
        default=DEFAULT_QUERY_SCORE_DELTA,
    )
    parser.add_argument("--margins", type=float, nargs="+", default=DEFAULT_MARGINS)
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        summary = run(
            artifact_dir=arguments.artifact_dir,
            embeddings_path=arguments.embeddings,
            output_dir=arguments.output_dir,
            query_score_delta=arguments.query_score_delta,
            margins=arguments.margins,
            top_k=arguments.top_k,
        )
    except (
        CohortGateError,
        resolver.CohortTemporalError,
        cohort_labels.CohortSimilarityError,
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
