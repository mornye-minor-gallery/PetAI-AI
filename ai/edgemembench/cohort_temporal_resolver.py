#!/usr/bin/env python3
"""Evaluate cohort-local deterministic temporal resolution on axis C.

This runner reuses the frozen EmbeddingGemma SQLite database. It never runs a
model or extracts a new embedding. EdgeMemBench v0 is a retrospective
regression set: no threshold or operating constant is selected here.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, Iterable, Sequence

import prepare
import retrieval_runner as dense
import temporal_rerank_runner as temporal_v1


ROOT = Path(__file__).resolve().parent
RUNNER_VERSION = "0.1.0"
DEFAULT_TOP_K = 20
DEFAULT_QUERY_SCORE_DELTA = 0.05
DEFAULT_GLOBAL_ALPHA = 0.10
DEFAULT_VIEW_CONTRACT_PATH = ROOT / "data" / "temporal_view_contract.json"
DEFAULT_OUTPUT_DIR = (
    dense.DEFAULT_RETRIEVAL_DIR / "cohort-temporal-resolution-v1"
)
POLICY_IDS = ("R0", "R1", "R2", "R3", "O1", "O2", "O3")


class CohortTemporalError(RuntimeError):
    """Raised when the cohort-local temporal contract is violated."""


class QueryView(str, Enum):
    CURRENT = "current"
    HISTORICAL_PREVIOUS = "historical_previous"
    TRANSITION = "transition"
    AS_OF = "as_of"
    NEUTRAL = "neutral"


@dataclass(frozen=True)
class QueryViewResult:
    view: QueryView
    matched_rule: str
    cutoff_month_day: tuple[int, int] | None = None
    cutoff_inclusive: bool | None = None


@dataclass(frozen=True)
class GoldView:
    case_id: str
    source_temporal_subtype: str
    view: QueryView
    cutoff_month_day: tuple[int, int] | None
    cutoff_inclusive: bool | None


@dataclass(frozen=True)
class CohortSelection:
    member_ids: tuple[str, ...]
    anchor_id: str | None
    partner_id: str | None
    partner_cosine: float | None
    query_score_gap: float | None


TRANSITION_PATTERNS = (
    (
        "transition_previous_and_now",
        re.compile(
            r"\b(previous(?:ly)?|before|initial(?:ly)?|start(?:ed|ing)?)\b"
            r".*\b(now|current(?:ly)?)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "transition_change_direction",
        re.compile(
            r"\b(switch(?:ed)?|increase(?:d)?|decrease(?:d)?|changed?|"
            r"more frequently than|less frequently than)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "transition_korean",
        re.compile(
            r"(어떻게\s*바뀌|변화|예전.*(?:지금|현재)|"
            r"(?:지금|현재).*예전|늘었|줄었)"
        ),
    ),
)

STRICT_BEFORE_DATE_PATTERN = re.compile(
    r"\b(?:before|prior\s+to)\b(?:[^\d]{0,80})"
    r"(?P<month>1[0-2]|0?[1-9])\s*/\s*"
    r"(?P<day>3[01]|[12]\d|0?[1-9])",
    re.IGNORECASE,
)
AS_OF_DATE_PATTERN = re.compile(
    r"\b(?:as\s+of|on|by)\b(?:[^\d]{0,80})"
    r"(?P<month>1[0-2]|0?[1-9])\s*/\s*"
    r"(?P<day>3[01]|[12]\d|0?[1-9])",
    re.IGNORECASE,
)

HISTORICAL_PATTERNS = (
    (
        "historical_explicit",
        re.compile(
            r"\b(previous|previously|initially|earlier|former|old|prior|"
            r"before|at the time|first three months)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "historical_korean",
        re.compile(r"(예전|이전|과거|그때|처음|당시|바꾸기\s*전)"),
    ),
)

CURRENT_PATTERNS = (
    (
        "current_explicit",
        re.compile(
            r"\b(current|currently|now|recent|recently|latest|most recent|"
            r"so far|these days|usually)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "current_cumulative",
        re.compile(
            r"\b(have I|has my|have my|do I|does my|did I finish|since I|"
            r"how long have|how many .* have)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "current_korean",
        re.compile(r"(현재|지금|요즘|최근|지금까지|현재까지|보통)"),
    ),
)


def infer_query_view(query: str) -> QueryViewResult:
    """Infer a high-precision temporal view without benchmark labels."""
    if not isinstance(query, str) or not query.strip():
        raise CohortTemporalError("query must be a non-empty string")
    normalized = " ".join(query.split())
    for rule, pattern in TRANSITION_PATTERNS:
        if pattern.search(normalized):
            return QueryViewResult(QueryView.TRANSITION, rule)
    strict = STRICT_BEFORE_DATE_PATTERN.search(normalized)
    if strict:
        return QueryViewResult(
            QueryView.AS_OF,
            "as_of_strict_before_date",
            (int(strict.group("month")), int(strict.group("day"))),
            False,
        )
    inclusive = AS_OF_DATE_PATTERN.search(normalized)
    if inclusive:
        return QueryViewResult(
            QueryView.AS_OF,
            "as_of_inclusive_date",
            (int(inclusive.group("month")), int(inclusive.group("day"))),
            True,
        )
    for rule, pattern in HISTORICAL_PATTERNS:
        if pattern.search(normalized):
            return QueryViewResult(QueryView.HISTORICAL_PREVIOUS, rule)
    for rule, pattern in CURRENT_PATTERNS:
        if pattern.search(normalized):
            return QueryViewResult(QueryView.CURRENT, rule)
    return QueryViewResult(
        QueryView.NEUTRAL,
        "fail_closed_no_temporal_marker",
    )


def load_view_contract(
    path: Path,
    annotations_path: Path,
) -> dict[str, GoldView]:
    if not path.is_file():
        raise CohortTemporalError(f"view contract was not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != "temporal-view-contract-v1":
        raise CohortTemporalError("unsupported temporal view contract")
    if payload.get("source") != "data/knowledge_update_annotations.jsonl":
        raise CohortTemporalError("unexpected temporal view annotation source")
    mapping = payload.get("default_mapping")
    if not isinstance(mapping, dict):
        raise CohortTemporalError("default_mapping must be an object")
    overrides = payload.get("overrides")
    if not isinstance(overrides, dict):
        raise CohortTemporalError("overrides must be an object")

    rows = prepare.read_jsonl(annotations_path)
    scored = [row for row in rows if row["evaluation_status"] == "scored"]
    if len(scored) != payload.get("scored_case_count"):
        raise CohortTemporalError(
            "scored case count does not match temporal view contract"
        )
    result: dict[str, GoldView] = {}
    for row in scored:
        case_id = row["case_id"]
        subtype = row["temporal_subtype"]
        try:
            view = QueryView(mapping[subtype])
        except (KeyError, ValueError) as error:
            raise CohortTemporalError(
                f"{case_id}: temporal subtype has no valid view mapping"
            ) from error
        cutoff: tuple[int, int] | None = None
        cutoff_inclusive: bool | None = None
        override = overrides.get(case_id)
        if override is not None:
            if not isinstance(override, dict):
                raise CohortTemporalError(f"{case_id}: invalid override")
            view = QueryView(override["gold_view"])
            raw_cutoff = override.get("cutoff_month_day")
            if raw_cutoff is not None:
                if (
                    not isinstance(raw_cutoff, list)
                    or len(raw_cutoff) != 2
                    or not all(isinstance(value, int) for value in raw_cutoff)
                ):
                    raise CohortTemporalError(f"{case_id}: invalid cutoff")
                cutoff = (raw_cutoff[0], raw_cutoff[1])
                datetime(2000, *cutoff)
            cutoff_inclusive = override.get("cutoff_inclusive")
            if cutoff_inclusive is not None and not isinstance(
                cutoff_inclusive, bool
            ):
                raise CohortTemporalError(
                    f"{case_id}: cutoff_inclusive must be boolean"
                )
        if view is QueryView.AS_OF and (
            cutoff is None or cutoff_inclusive is None
        ):
            raise CohortTemporalError(
                f"{case_id}: as_of view requires an explicit cutoff"
            )
        if view is not QueryView.AS_OF and (
            cutoff is not None or cutoff_inclusive is not None
        ):
            raise CohortTemporalError(
                f"{case_id}: only as_of may define a cutoff"
            )
        if case_id in result:
            raise CohortTemporalError(f"duplicate gold view: {case_id}")
        result[case_id] = GoldView(
            case_id=case_id,
            source_temporal_subtype=subtype,
            view=view,
            cutoff_month_day=cutoff,
            cutoff_inclusive=cutoff_inclusive,
        )
    unknown_overrides = set(overrides) - set(result)
    if unknown_overrides:
        raise CohortTemporalError(
            f"view overrides reference unscored cases: {sorted(unknown_overrides)}"
        )
    return result


def effective_view(
    inferred: QueryViewResult,
    cohort_size: int,
) -> QueryViewResult:
    """Default an unmarked query to current only for a version cohort."""
    if inferred.view is QueryView.NEUTRAL and cohort_size >= 2:
        return QueryViewResult(
            QueryView.CURRENT,
            "neutral_with_version_cohort_defaults_current",
        )
    return inferred


def predict_local_cohort(
    candidates: Sequence[dense.RankedCandidate],
    store: dense.EmbeddingStore,
    query_score_delta: float,
) -> CohortSelection:
    """Select one partner around the Dense Top-1 seed using frozen policy C."""
    if query_score_delta < 0 or not math.isfinite(query_score_delta):
        raise CohortTemporalError("query score delta must be finite and non-negative")
    if not candidates:
        return CohortSelection((), None, None, None, None)
    anchor = candidates[0]
    eligible = [
        candidate
        for candidate in candidates[1:]
        if anchor.score - candidate.score <= query_score_delta + 1e-12
    ]
    if not eligible:
        return CohortSelection(
            (anchor.candidate.turn_id,),
            anchor.candidate.turn_id,
            None,
            None,
            None,
        )
    anchor_vector = store.vector("document", anchor.candidate.text)
    scored = [
        (
            dense.cosine_similarity(
                anchor_vector,
                store.vector("document", candidate.candidate.text),
            ),
            candidate,
        )
        for candidate in eligible
    ]
    scored.sort(key=lambda item: item[1].candidate.turn_id)
    cosine, partner = max(
        scored,
        key=lambda item: (item[0], item[1].score),
    )
    return CohortSelection(
        (anchor.candidate.turn_id, partner.candidate.turn_id),
        anchor.candidate.turn_id,
        partner.candidate.turn_id,
        cosine,
        anchor.score - partner.score,
    )


def gold_local_cohort(
    record: dict[str, Any],
    candidates: Sequence[dense.RankedCandidate],
) -> CohortSelection:
    expected = record["expected"]
    gold_ids = set(expected["target_evidence_turn_ids"]) | set(
        expected["competing_evidence_turn_ids"]
    )
    member_ids = tuple(
        candidate.candidate.turn_id
        for candidate in candidates
        if candidate.candidate.turn_id in gold_ids
    )
    return CohortSelection(member_ids, None, None, None, None)


def cutoff_value(
    candidates: Sequence[dense.RankedCandidate],
    month_day: tuple[int, int],
) -> tuple[int, int, int, int, int]:
    if not candidates:
        raise CohortTemporalError("cannot infer cutoff year without candidates")
    year = max(candidate.candidate.timestamp[0] for candidate in candidates)
    return (year, month_day[0], month_day[1], 0, 0)


def ordered_cohort_ids(
    candidates: Sequence[dense.RankedCandidate],
    cohort: CohortSelection,
    view: QueryViewResult,
) -> tuple[str, ...]:
    by_id = {
        candidate.candidate.turn_id: candidate
        for candidate in candidates
        if candidate.candidate.turn_id in set(cohort.member_ids)
    }
    members = list(by_id.values())
    members.sort(
        key=lambda candidate: (
            candidate.candidate.timestamp,
            candidate.candidate.turn_id,
        )
    )
    if not members or view.view is QueryView.NEUTRAL:
        return ()
    if view.view is QueryView.CURRENT:
        return (members[-1].candidate.turn_id,)
    if view.view is QueryView.HISTORICAL_PREVIOUS:
        selected = members[-2] if len(members) >= 2 else members[0]
        return (selected.candidate.turn_id,)
    if view.view is QueryView.TRANSITION:
        return tuple(member.candidate.turn_id for member in members)
    if view.view is QueryView.AS_OF:
        if view.cutoff_month_day is None or view.cutoff_inclusive is None:
            raise CohortTemporalError("as_of view is missing cutoff semantics")
        cutoff = cutoff_value(candidates, view.cutoff_month_day)
        eligible = [
            member
            for member in members
            if (
                member.candidate.timestamp <= cutoff
                if view.cutoff_inclusive
                else member.candidate.timestamp < cutoff
            )
        ]
        return () if not eligible else (eligible[-1].candidate.turn_id,)
    raise CohortTemporalError(f"unsupported query view: {view.view}")


def promote_ids(
    candidates: Sequence[dense.RankedCandidate],
    ordered_ids: Sequence[str],
) -> list[dense.RankedCandidate]:
    if len(set(ordered_ids)) != len(ordered_ids):
        raise CohortTemporalError("promoted IDs must be unique")
    indexed = {candidate.candidate.turn_id: candidate for candidate in candidates}
    missing = set(ordered_ids) - set(indexed)
    if missing:
        raise CohortTemporalError(f"promoted IDs are not candidates: {sorted(missing)}")
    promoted = [indexed[identifier] for identifier in ordered_ids]
    promoted_set = set(ordered_ids)
    ordered = promoted + [
        candidate
        for candidate in candidates
        if candidate.candidate.turn_id not in promoted_set
    ]
    if {item.candidate.turn_id for item in ordered} != set(indexed):
        raise CohortTemporalError("candidate set changed during promotion")
    return [
        dense.RankedCandidate(
            candidate=item.candidate,
            score=item.score,
            rank=index,
        )
        for index, item in enumerate(ordered, start=1)
    ]


def resolve_local(
    candidates: Sequence[dense.RankedCandidate],
    cohort: CohortSelection,
    view: QueryViewResult,
) -> list[dense.RankedCandidate]:
    effective = effective_view(view, len(cohort.member_ids))
    return promote_ids(
        candidates,
        ordered_cohort_ids(candidates, cohort, effective),
    )


def as_query_view(gold: GoldView) -> QueryViewResult:
    return QueryViewResult(
        gold.view,
        "gold_view",
        gold.cutoff_month_day,
        gold.cutoff_inclusive,
    )


def scored_metrics(
    rows: Sequence[dict[str, Any]],
    policy_id: str,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    scores = [row["policies"][policy_id]["score"] for row in rows]
    return {
        "cases": len(rows),
        "target_hit_at_k": {
            str(k): sum(score["target_hit_at_k"][str(k)] for score in scores)
            / len(scores)
            for k in cutoffs
        },
        "target_recall_at_k": {
            str(k): sum(score["target_recall_at_k"][str(k)] for score in scores)
            / len(scores)
            for k in cutoffs
        },
        "best_target_mrr": sum(score["reciprocal_rank"] for score in scores)
        / len(scores),
        "target_before_competing": mean_optional([
            score["target_before_competing"] for score in scores
        ]),
    }


def rank_comparison(
    rows: Sequence[dict[str, Any]],
    policy_id: str,
) -> dict[str, int]:
    counts = {"improved": 0, "regressed": 0, "unchanged": 0}
    for row in rows:
        baseline = row["policies"]["R0"]["score"]["best_target_rank"]
        candidate = row["policies"][policy_id]["score"]["best_target_rank"]
        if candidate < baseline:
            counts["improved"] += 1
        elif candidate > baseline:
            counts["regressed"] += 1
        else:
            counts["unchanged"] += 1
    return counts


def metrics_by_view(
    rows: Sequence[dict[str, Any]],
    policy_id: str,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    return {
        view.value: scored_metrics(
            [row for row in rows if row["gold_view"] == view.value],
            policy_id,
            cutoffs,
        )
        for view in QueryView
        if any(row["gold_view"] == view.value for row in rows)
    }


def mean_optional(values: Iterable[bool | float | None]) -> float | None:
    numeric = [float(value) for value in values if value is not None]
    return None if not numeric else sum(numeric) / len(numeric)


def view_confusion(rows: Sequence[dict[str, Any]], field: str) -> dict[str, Any]:
    pairs: dict[str, int] = {}
    correct = 0
    for row in rows:
        predicted = row[field]
        gold = row["gold_view"]
        pairs[f"{gold}->{predicted}"] = pairs.get(f"{gold}->{predicted}", 0) + 1
        correct += predicted == gold
    return {
        "accuracy": correct / len(rows),
        "correct": correct,
        "cases": len(rows),
        "confusion": dict(sorted(pairs.items())),
    }


def build_failure_analysis(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    def compact(row: dict[str, Any]) -> dict[str, Any]:
        return {
            "case_id": row["case_id"],
            "query": row["query"],
            "gold_view": row["gold_view"],
            "predicted_view": row["predicted_view"],
            "predicted_effective_view": row["predicted_effective_view"],
            "matched_rule": row["matched_rule"],
            "predicted_cohort": row["predicted_cohort"],
        }

    parser_failures = [
        compact(row)
        for row in rows
        if row["predicted_effective_view"] != row["gold_view"]
    ]
    oracle_misses = [
        {
            **compact(row),
            "gold_cohort_ids": row["gold_cohort_ids"],
            "oracle_top_ids": row["policies"]["O1"]["top_ids"],
            "oracle_score": row["policies"]["O1"]["score"],
        }
        for row in rows
        if not row["policies"]["O1"]["score"]["target_hit_at_k"]["1"]
    ]
    r3_changes = {"improved": [], "regressed": []}
    for row in rows:
        baseline = row["policies"]["R0"]["score"]["best_target_rank"]
        candidate = row["policies"]["R3"]["score"]["best_target_rank"]
        if baseline == candidate:
            continue
        direction = "improved" if candidate < baseline else "regressed"
        r3_changes[direction].append({
            **compact(row),
            "dense_target_rank": baseline,
            "r3_target_rank": candidate,
            "dense_top_ids": row["policies"]["R0"]["top_ids"],
            "r3_top_ids": row["policies"]["R3"]["top_ids"],
        })
    cohort_buckets: dict[str, list[dict[str, Any]]] = {
        "gold_anchor_gold_partner": [],
        "gold_anchor_bad_partner": [],
        "gold_anchor_no_partner": [],
        "bad_anchor_gold_partner": [],
        "bad_anchor_bad_partner": [],
        "bad_anchor_no_partner": [],
    }
    for row in rows:
        cohort = row["predicted_cohort"]
        anchor = "gold_anchor" if cohort["anchor_is_gold_version"] else "bad_anchor"
        if cohort["partner_id"] is None:
            partner = "no_partner"
        else:
            partner = (
                "gold_partner"
                if cohort["partner_is_gold_version"]
                else "bad_partner"
            )
        cohort_buckets[f"{anchor}_{partner}"].append(compact(row))
    return {
        "parser_failures": parser_failures,
        "oracle_hit_at_1_failures": oracle_misses,
        "r3_rank_changes_vs_dense": r3_changes,
        "predicted_cohort_buckets": cohort_buckets,
    }


def run(
    *,
    artifact_dir: Path,
    embeddings_path: Path,
    view_contract_path: Path,
    output_dir: Path,
    query_score_delta: float,
    global_alpha: float,
    top_k: int,
    cutoffs: Sequence[int],
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    if output_dir.exists():
        raise CohortTemporalError(f"output directory already exists: {output_dir}")
    if top_k < max(cutoffs):
        raise CohortTemporalError("top-k must cover every scoring cutoff")
    annotations_path = ROOT / "data" / "knowledge_update_annotations.jsonl"
    gold_views = load_view_contract(view_contract_path, annotations_path)
    records = prepare.read_jsonl(artifact_dir / prepare.OUTPUT_FILES["C"])
    scored_records = [
        record
        for record in records
        if record["expected"]["evaluation_status"] == "scored"
    ]
    if {record["case_id"] for record in scored_records} != set(gold_views):
        raise CohortTemporalError("gold view cases do not match scored C records")

    store = dense.EmbeddingStore(embeddings_path)
    rows: list[dict[str, Any]] = []
    try:
        for record in scored_records:
            ranked, _ = dense.rank_record(record, store)
            candidates = ranked[:top_k]
            predicted_cohort = predict_local_cohort(
                candidates,
                store,
                query_score_delta,
            )
            gold_cohort = gold_local_cohort(record, candidates)
            inferred = infer_query_view(record["query"])
            gold = gold_views[record["case_id"]]
            predicted_effective = effective_view(
                inferred,
                len(predicted_cohort.member_ids),
            )
            gold_effective_for_predicted = effective_view(
                as_query_view(gold),
                len(predicted_cohort.member_ids),
            )

            temporal_intent = temporal_v1.infer_temporal_intent(record["query"])
            global_reranked = temporal_v1.rerank_candidates(
                candidates,
                temporal_intent,
                global_alpha,
            )
            policies = {
                "R0": list(candidates),
                "R1": temporal_v1.as_dense_ranked(global_reranked),
                "R2": resolve_local(
                    candidates,
                    predicted_cohort,
                    QueryViewResult(QueryView.CURRENT, "always_latest"),
                ),
                "R3": resolve_local(candidates, predicted_cohort, inferred),
                "O1": resolve_local(candidates, gold_cohort, as_query_view(gold)),
                "O2": resolve_local(
                    candidates,
                    predicted_cohort,
                    gold_effective_for_predicted,
                ),
                "O3": resolve_local(candidates, gold_cohort, inferred),
            }
            target_or_competing = set(
                record["expected"]["target_evidence_turn_ids"]
            ) | set(record["expected"]["competing_evidence_turn_ids"])
            target_ids = set(record["expected"]["target_evidence_turn_ids"])
            competing_ids = set(
                record["expected"]["competing_evidence_turn_ids"]
            )
            predicted_set = set(predicted_cohort.member_ids)
            row: dict[str, Any] = {
                "case_id": record["case_id"],
                "query": record["query"],
                "source_temporal_subtype": gold.source_temporal_subtype,
                "gold_view": gold.view.value,
                "predicted_view": inferred.view.value,
                "predicted_effective_view": predicted_effective.view.value,
                "matched_rule": inferred.matched_rule,
                "gold_cohort_ids": list(gold_cohort.member_ids),
                "predicted_cohort": {
                    "member_ids": list(predicted_cohort.member_ids),
                    "anchor_id": predicted_cohort.anchor_id,
                    "partner_id": predicted_cohort.partner_id,
                    "partner_cosine": predicted_cohort.partner_cosine,
                    "query_score_gap": predicted_cohort.query_score_gap,
                    "anchor_is_target": predicted_cohort.anchor_id in target_ids,
                    "anchor_is_competing": (
                        predicted_cohort.anchor_id in competing_ids
                    ),
                    "anchor_is_gold_version": (
                        predicted_cohort.anchor_id in target_or_competing
                    ),
                    "partner_is_gold_version": (
                        predicted_cohort.partner_id in target_or_competing
                        if predicted_cohort.partner_id is not None
                        else False
                    ),
                    "gold_aligned": (
                        len(predicted_set) >= 2
                        and predicted_set.issubset(target_or_competing)
                    ),
                },
                "policies": {},
            }
            for policy_id, policy_ranked in policies.items():
                score = dense.score_record(record, policy_ranked, cutoffs)
                row["policies"][policy_id] = {
                    "score": score,
                    "top_ids": [
                        item.candidate.turn_id for item in policy_ranked[:5]
                    ],
                }
            rows.append(row)
    finally:
        store.close()

    aligned = sum(row["predicted_cohort"]["gold_aligned"] for row in rows)
    selected_partner_rows = [
        row
        for row in rows
        if row["predicted_cohort"]["partner_id"] is not None
    ]
    anchor_gold_rows = [
        row
        for row in rows
        if row["predicted_cohort"]["anchor_is_gold_version"]
    ]
    summary = {
        "phase": "cohort_temporal_resolution_complete",
        "runner_version": RUNNER_VERSION,
        "benchmark_version": prepare.load_manifest()["version"],
        "contract": {
            "candidate_source": f"frozen Dense Top-{top_k}",
            "candidate_set_mutation": "forbidden; ordering only",
            "query_score_delta": query_score_delta,
            "query_score_delta_source": "frozen Korean calibration v1",
            "global_timestamp_alpha": global_alpha,
            "v0_usage": "retrospective regression only; no tuning",
            "policies": {
                "R0": "Dense only",
                "R1": "global timestamp reranking v1",
                "R2": "predicted local cohort plus always latest",
                "R3": "predicted local cohort plus predicted query view",
                "O1": "gold local cohort plus gold query view",
                "O2": "predicted local cohort plus gold query view",
                "O3": "gold local cohort plus predicted query view",
            },
        },
        "inputs": {
            "artifact_manifest_sha256": dense.sha256_file(
                artifact_dir / "artifact_manifest.json"
            ),
            "embeddings_sha256": dense.sha256_file(embeddings_path),
            "view_contract_sha256": dense.sha256_file(view_contract_path),
            "knowledge_update_annotations_sha256": dense.sha256_file(
                annotations_path
            ),
        },
        "cases": len(rows),
        "parser": {
            "raw": view_confusion(rows, "predicted_view"),
            "effective_after_cohort_default": view_confusion(
                rows,
                "predicted_effective_view",
            ),
        },
        "predicted_cohort": {
            "anchor_gold_version_cases": len(anchor_gold_rows),
            "anchor_gold_version_rate": len(anchor_gold_rows) / len(rows),
            "partner_selected_cases": len(selected_partner_rows),
            "partner_coverage": len(selected_partner_rows) / len(rows),
            "gold_aligned_cases": aligned,
            "gold_aligned_rate": aligned / len(rows),
            "false_or_unresolved_cases": len(rows) - aligned,
            "selected_pair_precision": (
                None
                if not selected_partner_rows
                else aligned / len(selected_partner_rows)
            ),
            "gold_aligned_given_gold_anchor": (
                None
                if not anchor_gold_rows
                else aligned / len(anchor_gold_rows)
            ),
        },
        "metrics": {
            policy_id: {
                **scored_metrics(rows, policy_id, cutoffs),
                "rank_change_vs_dense": rank_comparison(rows, policy_id),
                "by_gold_view": metrics_by_view(
                    rows,
                    policy_id,
                    cutoffs,
                ),
            }
            for policy_id in POLICY_IDS
        },
        "limitations": [
            "EdgeMemBench v0 informed the design and is not a fresh holdout.",
            "The predicted cohort is a two-member star around Dense Top-1.",
            "Gold views derive from the existing manually reviewed subtype contract, with one explicit strict as-of override.",
            "The runner measures retrieval ordering only; no Gemma reader is invoked.",
            "occurredAt is used as event time because recorded-time metadata is unavailable.",
        ],
    }
    output_dir.mkdir(parents=True)
    prepare.write_jsonl_atomic(output_dir / "results.jsonl", rows)
    failure_analysis = build_failure_analysis(rows)
    prepare.write_json_atomic(
        output_dir / "failure_analysis.json",
        failure_analysis,
    )
    summary["outputs"] = {
        "results_sha256": dense.sha256_file(output_dir / "results.jsonl"),
        "failure_analysis_sha256": dense.sha256_file(
            output_dir / "failure_analysis.json"
        ),
    }
    prepare.write_json_atomic(output_dir / "summary.json", summary)
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
        "--view-contract",
        type=Path,
        default=DEFAULT_VIEW_CONTRACT_PATH,
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--query-score-delta",
        type=float,
        default=DEFAULT_QUERY_SCORE_DELTA,
    )
    parser.add_argument(
        "--global-alpha",
        type=float,
        default=DEFAULT_GLOBAL_ALPHA,
    )
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    parser.add_argument(
        "--cutoffs",
        type=int,
        nargs="+",
        default=[1, 2, 3, 5, 10, 20],
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        summary = run(
            artifact_dir=arguments.artifact_dir,
            embeddings_path=arguments.embeddings,
            view_contract_path=arguments.view_contract,
            output_dir=arguments.output_dir,
            query_score_delta=arguments.query_score_delta,
            global_alpha=arguments.global_alpha,
            top_k=arguments.top_k,
            cutoffs=arguments.cutoffs,
        )
    except (
        CohortTemporalError,
        temporal_v1.TemporalRerankError,
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
