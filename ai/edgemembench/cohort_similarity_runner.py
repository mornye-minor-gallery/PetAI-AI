#!/usr/bin/env python3
"""Test whether pairwise cosine can identify temporal fact versions.

This is a diagnostic runner, not a reranker. It uses the manually reviewed
axis-C target/competing partition as positive same-fact-version pairs and
compares those scores with non-evidence candidates from the frozen Dense
Top-K pool. It never changes candidate order or selects an operating
threshold on the v0 test set.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any, Iterable, Sequence

import prepare
import retrieval_runner as dense


RUNNER_VERSION = "0.2.0"
DEFAULT_TOP_K = 20
DEFAULT_THRESHOLDS = tuple(index / 100 for index in range(50, 100, 5))
DEFAULT_OVERLAP_THRESHOLDS = (1, 2, 3, 4, 5)
DEFAULT_QUERY_SCORE_DELTAS = (0.0, 0.02, 0.05, 0.10, 0.15, 0.20, 0.30, math.inf)
DEFAULT_OUTPUT_DIR = (
    dense.DEFAULT_RETRIEVAL_DIR / "cohort-similarity"
)
DEFAULT_ANNOTATIONS_PATH = (
    Path(__file__).resolve().parent / "data" / "cohort_pair_annotations.jsonl"
)
DEFAULT_ABC_ANNOTATIONS_PATH = (
    Path(__file__).resolve().parent
    / "data"
    / "cohort_abc_candidate_annotations.jsonl"
)
DEFAULT_RETRIEVAL_RESULTS_PATH = (
    dense.DEFAULT_RETRIEVAL_DIR
    / "baseline-curated-v1"
    / "retrieval_results.jsonl"
)

VALUE_PATTERN = re.compile(
    r"(?<!\w)[+-]?(?:[$€£₩¥]\s*)?\d+(?:[.,:/-]\d+)*"
    r"(?:%|st|nd|rd|th|am|pm)?(?!\w)",
    re.IGNORECASE,
)
TOKEN_PATTERN = re.compile(
    r"[^\W_]+(?:['’-][^\W_]+)*",
    re.UNICODE,
)
ENGLISH_STOPWORDS = frozenset({
    "a", "about", "after", "again", "against", "all", "also", "am",
    "an", "and", "any", "are", "as", "at", "be", "because", "been",
    "before", "being", "between", "both", "but", "by", "can", "could",
    "current", "currently", "did", "do", "does", "doing", "during",
    "each", "earlier", "for", "from", "further", "had", "has", "have",
    "having", "he", "her", "here", "hers", "herself", "him", "himself",
    "his", "how", "i", "if", "in", "into", "is", "it", "its", "itself",
    "latest", "later", "me", "more", "most", "my", "myself", "new",
    "newer", "no", "nor", "not", "now", "of", "off", "old", "older",
    "on", "once", "only", "or", "other", "our", "ours", "ourselves",
    "out", "over", "previous", "previously", "recent", "recently", "same",
    "she", "should", "so", "some", "such", "than", "that", "the", "their",
    "theirs", "them", "themselves", "then", "there", "these", "they",
    "this", "those", "through", "to", "today", "tomorrow", "too", "under",
    "until", "up", "very", "was", "we", "were", "what", "when", "where",
    "which", "while", "who", "whom", "why", "will", "with", "would",
    "yesterday", "you", "your", "yours", "yourself", "yourselves",
    "i'd", "i'll", "i'm", "i've", "you're", "you've", "we're", "we've",
    "they're", "they've", "he's", "she's", "it's", "that's",
    "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december",
})


class CohortSimilarityError(RuntimeError):
    """Raised when the cohort diagnostic contract is violated."""


def percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        raise CohortSimilarityError("percentile requires at least one value")
    if not 0 <= fraction <= 1:
        raise CohortSimilarityError("percentile fraction must be within [0, 1]")
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def describe(values: Sequence[float]) -> dict[str, Any]:
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "min": min(values),
        "p10": percentile(values, 0.10),
        "p25": percentile(values, 0.25),
        "median": percentile(values, 0.50),
        "p75": percentile(values, 0.75),
        "p90": percentile(values, 0.90),
        "max": max(values),
        "mean": sum(values) / len(values),
    }


def content_tokens(text: str) -> frozenset[str]:
    """Extract deterministic English content tokens for the v0 diagnostic."""
    normalized = unicodedata.normalize("NFKC", text).casefold()
    normalized = normalized.translate(
        str.maketrans({"’": "'", "–": "-", "—": "-"})
    )
    without_values = VALUE_PATTERN.sub(" ", normalized)
    return frozenset(
        token
        for token in TOKEN_PATTERN.findall(without_values)
        if len(token) > 1
        and token not in ENGLISH_STOPWORDS
        and not token.isdecimal()
    )


def shared_content_tokens(left: str, right: str) -> tuple[str, ...]:
    return tuple(sorted(content_tokens(left) & content_tokens(right)))


def average_precision(
    positive_scores: Sequence[float],
    negative_scores: Sequence[float],
) -> float:
    """Return tie-aware average precision over pair-level scores."""
    if not positive_scores or not negative_scores:
        raise CohortSimilarityError(
            "average precision requires positive and negative scores"
        )
    grouped: dict[float, list[int]] = {}
    for score in positive_scores:
        grouped.setdefault(score, [0, 0])[0] += 1
    for score in negative_scores:
        grouped.setdefault(score, [0, 0])[1] += 1

    true_positive = 0
    false_positive = 0
    previous_recall = 0.0
    area = 0.0
    for score in sorted(grouped, reverse=True):
        positive_count, negative_count = grouped[score]
        true_positive += positive_count
        false_positive += negative_count
        recall = true_positive / len(positive_scores)
        precision = true_positive / (true_positive + false_positive)
        area += (recall - previous_recall) * precision
        previous_recall = recall
    return area


def threshold_metrics(
    positive_scores: Sequence[float],
    negative_scores_by_case: dict[str, Sequence[float]],
    thresholds: Sequence[float],
) -> list[dict[str, Any]]:
    negative_scores = [
        score
        for case_scores in negative_scores_by_case.values()
        for score in case_scores
    ]
    if not positive_scores or not negative_scores:
        raise CohortSimilarityError(
            "threshold sweep requires positive and negative scores"
        )

    rows: list[dict[str, Any]] = []
    for threshold in sorted(set(thresholds)):
        if not math.isfinite(threshold) or not -1 <= threshold <= 1:
            raise CohortSimilarityError(
                "thresholds must be finite cosine values within [-1, 1]"
            )
        true_positive = sum(score >= threshold for score in positive_scores)
        false_negative = len(positive_scores) - true_positive
        false_positive = sum(score >= threshold for score in negative_scores)
        true_negative = len(negative_scores) - false_positive
        predicted_positive = true_positive + false_positive
        false_pairs_per_case = {
            case_id: sum(score >= threshold for score in scores)
            for case_id, scores in negative_scores_by_case.items()
        }
        rows.append(
            {
                "threshold": threshold,
                "true_positive": true_positive,
                "false_positive": false_positive,
                "false_negative": false_negative,
                "true_negative": true_negative,
                "precision": (
                    None
                    if predicted_positive == 0
                    else true_positive / predicted_positive
                ),
                "recall": true_positive / len(positive_scores),
                "false_positive_rate": false_positive / len(negative_scores),
                "cases_with_false_pair": sum(
                    count > 0 for count in false_pairs_per_case.values()
                ),
                "mean_false_pairs_per_case": (
                    sum(false_pairs_per_case.values())
                    / len(false_pairs_per_case)
                ),
            }
        )
    return rows


def combined_gate_metrics(
    positive_pairs: Sequence[dict[str, Any]],
    negative_pairs_by_case: dict[str, Sequence[dict[str, Any]]],
    cosine_thresholds: Sequence[float],
    overlap_thresholds: Sequence[int],
) -> list[dict[str, Any]]:
    negative_pairs = [
        pair
        for case_pairs in negative_pairs_by_case.values()
        for pair in case_pairs
    ]
    if not positive_pairs or not negative_pairs:
        raise CohortSimilarityError(
            "combined sweep requires positive and negative pairs"
        )

    rows: list[dict[str, Any]] = []
    for cosine_threshold in sorted(set(cosine_thresholds)):
        if (
            not math.isfinite(cosine_threshold)
            or not -1 <= cosine_threshold <= 1
        ):
            raise CohortSimilarityError(
                "cosine thresholds must be finite values within [-1, 1]"
            )
        for overlap_threshold in sorted(set(overlap_thresholds)):
            if overlap_threshold < 1:
                raise CohortSimilarityError(
                    "overlap thresholds must be positive integers"
                )

            def accepted(pair: dict[str, Any]) -> bool:
                return (
                    pair["cosine"] >= cosine_threshold
                    and pair["overlap_count"] >= overlap_threshold
                )

            true_positive = sum(accepted(pair) for pair in positive_pairs)
            false_negative = len(positive_pairs) - true_positive
            false_positive = sum(accepted(pair) for pair in negative_pairs)
            true_negative = len(negative_pairs) - false_positive
            predicted_positive = true_positive + false_positive
            false_pairs_per_case = {
                case_id: sum(accepted(pair) for pair in pairs)
                for case_id, pairs in negative_pairs_by_case.items()
            }
            rows.append(
                {
                    "cosine_threshold": cosine_threshold,
                    "overlap_threshold": overlap_threshold,
                    "true_positive": true_positive,
                    "false_positive": false_positive,
                    "false_negative": false_negative,
                    "true_negative": true_negative,
                    "precision": (
                        None
                        if predicted_positive == 0
                        else true_positive / predicted_positive
                    ),
                    "recall": true_positive / len(positive_pairs),
                    "false_positive_rate": (
                        false_positive / len(negative_pairs)
                    ),
                    "cases_with_false_pair": sum(
                        count > 0 for count in false_pairs_per_case.values()
                    ),
                    "mean_false_pairs_per_case": (
                        sum(false_pairs_per_case.values())
                        / len(false_pairs_per_case)
                    ),
                }
            )
    return rows


def pair_ids(pair: dict[str, Any]) -> tuple[str, str]:
    return pair["left"]["turn_id"], pair["right"]["turn_id"]


def partner_for_anchor(pair: dict[str, Any], anchor_id: str) -> str:
    left_id, right_id = pair_ids(pair)
    if left_id == anchor_id:
        return right_id
    if right_id == anchor_id:
        return left_id
    raise CohortSimilarityError(
        f"pair does not contain anchor {anchor_id!r}"
    )


def partner_top1_selections(
    case_rows: Sequence[dict[str, Any]],
    cosine_threshold: float,
    overlap_threshold: int,
) -> list[dict[str, Any]]:
    if not math.isfinite(cosine_threshold) or not -1 <= cosine_threshold <= 1:
        raise CohortSimilarityError(
            "cosine threshold must be a finite value within [-1, 1]"
        )
    if overlap_threshold < 0:
        raise CohortSimilarityError(
            "partner overlap threshold must be non-negative"
        )
    selections: list[dict[str, Any]] = []
    for case in case_rows:
        positive_pairs = [
            pair
            for pair in case["positive_pairs"]
            if pair["operational"]
        ]
        positive_pair_ids = {
            canonical_pair(*pair_ids(pair))
            for pair in positive_pairs
        }
        anchors = sorted({
            identifier
            for pair in positive_pairs
            for identifier in pair_ids(pair)
        })
        candidate_pairs = positive_pairs + case["negative_pairs"]
        for anchor_id in anchors:
            eligible = [
                pair
                for pair in candidate_pairs
                if anchor_id in pair_ids(pair)
                and pair["cosine"] >= cosine_threshold
                and pair["overlap_count"] >= overlap_threshold
            ]
            if not eligible:
                selections.append({
                    "case_id": case.get("case_id"),
                    "anchor_id": anchor_id,
                    "selected_partner_id": None,
                    "selected_pair": None,
                    "correct": False,
                })
                continue
            eligible.sort(
                key=lambda pair: partner_for_anchor(pair, anchor_id)
            )
            selected = max(
                eligible,
                key=lambda pair: (
                    pair["cosine"],
                    pair["overlap_count"],
                ),
            )
            partner_id = partner_for_anchor(selected, anchor_id)
            selections.append({
                "case_id": case.get("case_id"),
                "anchor_id": anchor_id,
                "selected_partner_id": partner_id,
                "selected_pair": selected,
                "correct": (
                    canonical_pair(anchor_id, partner_id)
                    in positive_pair_ids
                ),
            })
    return selections


def partner_top1_metrics(
    case_rows: Sequence[dict[str, Any]],
    cosine_thresholds: Sequence[float],
    overlap_thresholds: Sequence[int],
) -> list[dict[str, Any]]:
    """Score one highest-cosine partner for every gold-version anchor."""
    if not case_rows:
        raise CohortSimilarityError("partner Top-1 requires case rows")
    rows: list[dict[str, Any]] = []
    for cosine_threshold in sorted(set(cosine_thresholds)):
        if (
            not math.isfinite(cosine_threshold)
            or not -1 <= cosine_threshold <= 1
        ):
            raise CohortSimilarityError(
                "cosine thresholds must be finite values within [-1, 1]"
            )
        for overlap_threshold in sorted(set(overlap_thresholds)):
            selections = partner_top1_selections(
                case_rows,
                cosine_threshold,
                overlap_threshold,
            )
            anchor_count = len(selections)
            selected_count = sum(
                row["selected_pair"] is not None for row in selections
            )
            correct_count = sum(row["correct"] for row in selections)
            incorrect_count = selected_count - correct_count
            abstained_count = anchor_count - selected_count
            if anchor_count == 0:
                raise CohortSimilarityError(
                    "partner Top-1 found no operational positive anchors"
                )
            rows.append(
                {
                    "cosine_threshold": cosine_threshold,
                    "overlap_threshold": overlap_threshold,
                    "anchor_count": anchor_count,
                    "selected_count": selected_count,
                    "correct_count": correct_count,
                    "incorrect_count": incorrect_count,
                    "abstained_count": abstained_count,
                    "precision": (
                        None
                        if selected_count == 0
                        else correct_count / selected_count
                    ),
                    "recall": correct_count / anchor_count,
                    "coverage": selected_count / anchor_count,
                    "incorrect_selection_rate": (
                        incorrect_count / anchor_count
                    ),
                }
            )
    return rows


def canonical_pair(left_id: str, right_id: str) -> tuple[str, str]:
    if left_id == right_id:
        raise CohortSimilarityError("a candidate cannot be paired with itself")
    return tuple(sorted((left_id, right_id)))


def annotation_key(
    case_id: str,
    left_id: str,
    right_id: str,
) -> tuple[str, str, str]:
    return (case_id, *canonical_pair(left_id, right_id))


def load_cohort_annotations(path: Path) -> dict[tuple[str, str, str], dict[str, Any]]:
    rows = prepare.read_jsonl(path)
    if not rows:
        raise CohortSimilarityError("cohort annotations must not be empty")
    annotations: dict[tuple[str, str, str], dict[str, Any]] = {}
    allowed_labels = {"same_cohort", "different_cohort", "ambiguous"}
    for row in rows:
        key = annotation_key(
            row["case_id"],
            row["left_turn_id"],
            row["right_turn_id"],
        )
        if key in annotations:
            raise CohortSimilarityError(f"duplicate cohort annotation: {key}")
        if row.get("label") not in allowed_labels:
            raise CohortSimilarityError(
                f"{row.get('pair_id')}: invalid cohort annotation label"
            )
        annotations[key] = row
    return annotations


def merge_cohort_annotations(
    *annotation_sets: dict[tuple[str, str, str], dict[str, Any]],
) -> dict[tuple[str, str, str], dict[str, Any]]:
    merged: dict[tuple[str, str, str], dict[str, Any]] = {}
    for annotation_set in annotation_sets:
        overlap = set(merged) & set(annotation_set)
        if overlap:
            raise CohortSimilarityError(
                f"duplicate annotations across sources: {sorted(overlap)[:3]}"
            )
        merged.update(annotation_set)
    return merged


def load_query_candidate_scores(path: Path) -> dict[tuple[str, str], float]:
    scores: dict[tuple[str, str], float] = {}
    for row in prepare.read_jsonl(path):
        case_id = row["case_id"]
        for candidate in row["top_k"]:
            key = (case_id, candidate["turn_id"])
            if key in scores:
                raise CohortSimilarityError(
                    f"duplicate query-candidate score: {key}"
                )
            score = candidate["score"]
            if not isinstance(score, (int, float)) or not math.isfinite(score):
                raise CohortSimilarityError(
                    f"non-finite query-candidate score: {key}"
                )
            scores[key] = float(score)
    return scores


def annotated_pair_rows(
    pair_rows: Sequence[dict[str, Any]],
    annotations: dict[tuple[str, str, str], dict[str, Any]],
) -> list[dict[str, Any]]:
    indexed_pairs: dict[tuple[str, str, str], dict[str, Any]] = {}
    for pair in pair_rows:
        key = annotation_key(pair["case_id"], *pair_ids(pair))
        if key in indexed_pairs:
            raise CohortSimilarityError(f"duplicate scored pair: {key}")
        indexed_pairs[key] = pair
    missing = sorted(set(annotations) - set(indexed_pairs))
    if missing:
        raise CohortSimilarityError(
            f"{len(missing)} annotations are missing from pair scores"
        )
    rows = []
    for key, annotation in annotations.items():
        pair = dict(indexed_pairs[key])
        pair["annotation_label"] = annotation["label"]
        pair["annotation_reason"] = annotation["reason"]
        pair["annotation_pair_id"] = annotation["pair_id"]
        rows.append(pair)
    return rows


def group_case_pair_rows(
    pair_rows: Sequence[dict[str, Any]],
) -> list[dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for pair in pair_rows:
        case = grouped.setdefault(
            pair["case_id"],
            {
                "case_id": pair["case_id"],
                "positive_pairs": [],
                "negative_pairs": [],
            },
        )
        if pair["label"] == "same_fact_version":
            case["positive_pairs"].append(pair)
        elif pair["label"] == "non_evidence_top_k":
            case["negative_pairs"].append(pair)
        else:
            raise CohortSimilarityError(
                f"unexpected source pair label: {pair['label']!r}"
            )
    return [grouped[case_id] for case_id in sorted(grouped)]


def annotation_partner_top1_metrics(
    case_rows: Sequence[dict[str, Any]],
    annotations: dict[tuple[str, str, str], dict[str, Any]],
    configs: Sequence[tuple[float, int]],
) -> list[dict[str, Any]]:
    rows = []
    for cosine_threshold, overlap_threshold in sorted(set(configs)):
        selections = partner_top1_selections(
            case_rows,
            cosine_threshold,
            overlap_threshold,
        )
        counts = {
            "same_cohort": 0,
            "different_cohort": 0,
            "ambiguous": 0,
        }
        abstained = 0
        for selection in selections:
            pair = selection["selected_pair"]
            if pair is None:
                abstained += 1
                continue
            key = annotation_key(selection["case_id"], *pair_ids(pair))
            annotation = annotations.get(key)
            if annotation is None:
                raise CohortSimilarityError(
                    "selected partner pair is missing a blind annotation: "
                    f"{key}"
                )
            counts[annotation["label"]] += 1
        anchor_count = len(selections)
        selected_count = anchor_count - abstained
        decided_count = counts["same_cohort"] + counts["different_cohort"]
        rows.append({
            "cosine_threshold": cosine_threshold,
            "overlap_threshold": overlap_threshold,
            "anchor_count": anchor_count,
            "selected_count": selected_count,
            "same_cohort_count": counts["same_cohort"],
            "different_cohort_count": counts["different_cohort"],
            "ambiguous_count": counts["ambiguous"],
            "abstained_count": abstained,
            "decided_precision": (
                None
                if decided_count == 0
                else counts["same_cohort"] / decided_count
            ),
            "strict_precision": (
                None
                if selected_count == 0
                else counts["same_cohort"] / selected_count
            ),
            "anchor_success_rate": counts["same_cohort"] / anchor_count,
            "coverage": selected_count / anchor_count,
            "different_cohort_rate": (
                counts["different_cohort"] / anchor_count
            ),
        })
    return rows


def query_band_partner_selections(
    case_rows: Sequence[dict[str, Any]],
    query_candidate_scores: dict[tuple[str, str], float],
    delta: float,
) -> list[dict[str, Any]]:
    if delta < 0 or (not math.isfinite(delta) and delta != math.inf):
        raise CohortSimilarityError(
            "query-score delta must be non-negative or positive infinity"
        )
    selections = []
    for case in case_rows:
        positive_pairs = [
            pair for pair in case["positive_pairs"] if pair["operational"]
        ]
        anchors = sorted({
            identifier
            for pair in positive_pairs
            for identifier in pair_ids(pair)
        })
        candidate_pairs = positive_pairs + case["negative_pairs"]
        for anchor_id in anchors:
            eligible = [
                pair for pair in candidate_pairs
                if anchor_id in pair_ids(pair)
            ]
            if not eligible:
                raise CohortSimilarityError(
                    f"{case['case_id']}/{anchor_id}: no partner candidates"
                )

            def query_score(pair: dict[str, Any]) -> float:
                partner_id = partner_for_anchor(pair, anchor_id)
                key = (case["case_id"], partner_id)
                if key not in query_candidate_scores:
                    raise CohortSimilarityError(
                        f"missing query-candidate score: {key}"
                    )
                return query_candidate_scores[key]

            best_query_score = max(query_score(pair) for pair in eligible)
            band = [
                pair for pair in eligible
                if best_query_score - query_score(pair) <= delta
            ]
            band.sort(key=lambda pair: partner_for_anchor(pair, anchor_id))
            selected = max(
                band,
                key=lambda pair: (
                    pair["cosine"],
                    pair["overlap_count"],
                ),
            )
            selections.append({
                "case_id": case["case_id"],
                "anchor_id": anchor_id,
                "selected_partner_id": partner_for_anchor(
                    selected, anchor_id
                ),
                "selected_pair": selected,
                "selected_query_score": query_score(selected),
                "best_query_score": best_query_score,
                "query_score_gap": best_query_score - query_score(selected),
                "band_candidate_count": len(band),
            })
    return selections


def annotation_abc_policy_metrics(
    case_rows: Sequence[dict[str, Any]],
    annotations: dict[tuple[str, str, str], dict[str, Any]],
    query_candidate_scores: dict[tuple[str, str], float],
    deltas: Sequence[float] = DEFAULT_QUERY_SCORE_DELTAS,
) -> list[dict[str, Any]]:
    rows = []
    for delta in deltas:
        selections = query_band_partner_selections(
            case_rows,
            query_candidate_scores,
            delta,
        )
        counts = {
            "same_cohort": 0,
            "different_cohort": 0,
            "ambiguous": 0,
            "missing_annotation": 0,
        }
        for selection in selections:
            annotation = annotations.get(annotation_key(
                selection["case_id"],
                *pair_ids(selection["selected_pair"]),
            ))
            if annotation is None:
                counts["missing_annotation"] += 1
            else:
                counts[annotation["label"]] += 1
        anchor_count = len(selections)
        annotated_count = anchor_count - counts["missing_annotation"]
        decided_count = counts["same_cohort"] + counts["different_cohort"]
        policy = "B_query_only" if delta == 0 else (
            "A_pair_only" if delta == math.inf else "C_query_band_then_pair"
        )
        rows.append({
            "policy": policy,
            "query_score_delta": "inf" if delta == math.inf else delta,
            "anchor_count": anchor_count,
            "annotated_count": annotated_count,
            "missing_annotation_count": counts["missing_annotation"],
            "same_cohort_count": counts["same_cohort"],
            "different_cohort_count": counts["different_cohort"],
            "ambiguous_count": counts["ambiguous"],
            "annotation_coverage": annotated_count / anchor_count,
            "decided_precision": (
                None
                if decided_count == 0
                else counts["same_cohort"] / decided_count
            ),
            "strict_precision": (
                None
                if annotated_count == 0
                else counts["same_cohort"] / annotated_count
            ),
            "anchor_success_rate": counts["same_cohort"] / anchor_count,
        })
    return rows


def annotation_abc_policy_transitions(
    case_rows: Sequence[dict[str, Any]],
    annotations: dict[tuple[str, str, str], dict[str, Any]],
    query_candidate_scores: dict[tuple[str, str], float],
    deltas: Sequence[float] = DEFAULT_QUERY_SCORE_DELTAS,
) -> dict[str, dict[str, int]]:
    labels_by_delta: dict[float, dict[tuple[str, str], str]] = {}
    for delta in deltas:
        labels = {}
        for selection in query_band_partner_selections(
            case_rows, query_candidate_scores, delta
        ):
            annotation = annotations.get(annotation_key(
                selection["case_id"],
                *pair_ids(selection["selected_pair"]),
            ))
            if annotation is None:
                raise CohortSimilarityError(
                    "A/B/C transition selection lacks annotation"
                )
            labels[(selection["case_id"], selection["anchor_id"])] = (
                annotation["label"]
            )
        labels_by_delta[delta] = labels

    transitions = {}
    for source_name, source_delta in (
        ("A_pair_only", math.inf),
        ("B_query_only", 0.0),
    ):
        source = labels_by_delta[source_delta]
        for target_delta in deltas:
            if target_delta == source_delta:
                continue
            target = labels_by_delta[target_delta]
            counts: dict[str, int] = {}
            for key, source_label in source.items():
                transition = f"{source_label}->{target[key]}"
                counts[transition] = counts.get(transition, 0) + 1
            target_name = (
                "inf" if target_delta == math.inf else f"{target_delta:g}"
            )
            transitions[f"{source_name}_to_delta_{target_name}"] = counts
    return transitions


def pair_member(pair: dict[str, Any], turn_id: str) -> dict[str, Any]:
    for member in (pair["left"], pair["right"]):
        if member["turn_id"] == turn_id:
            return member
    raise CohortSimilarityError(f"pair does not contain turn {turn_id!r}")


def analyze_partner_failures(
    case_rows: Sequence[dict[str, Any]],
    annotations: dict[tuple[str, str, str], dict[str, Any]],
    *,
    baseline: tuple[float, int] = (-1.0, 0),
    comparison_gate: tuple[float, int] = (-1.0, 5),
    query_candidate_scores: dict[tuple[str, str], float] | None = None,
) -> dict[str, Any]:
    baseline_rows = partner_top1_selections(case_rows, *baseline)
    comparison_rows = {
        (row["case_id"], row["anchor_id"]): row
        for row in partner_top1_selections(case_rows, *comparison_gate)
    }
    annotated_by_anchor: dict[
        tuple[str, str], list[tuple[dict[str, Any], dict[str, Any]]]
    ] = {}
    for case in case_rows:
        for pair in case["positive_pairs"] + case["negative_pairs"]:
            key = annotation_key(case["case_id"], *pair_ids(pair))
            annotation = annotations.get(key)
            if annotation is None:
                continue
            for anchor_id in pair_ids(pair):
                annotated_by_anchor.setdefault(
                    (case["case_id"], anchor_id), []
                ).append((pair, annotation))

    reason_counts: dict[str, int] = {}
    transition_counts: dict[str, int] = {}
    alternative_counts = {"available": 0, "missing": 0}
    query_overlap_comparison = {
        "alternative_higher": 0,
        "equal": 0,
        "wrong_higher": 0,
    }
    cosine_gaps: list[float] = []
    query_score_comparison = {
        "alternative_higher": 0,
        "equal": 0,
        "wrong_higher": 0,
    }
    wrong_minus_alternative_query_scores: list[float] = []
    failures = []
    for selection in baseline_rows:
        selected = selection["selected_pair"]
        if selected is None:
            continue
        selected_key = annotation_key(
            selection["case_id"], *pair_ids(selected)
        )
        annotation = annotations.get(selected_key)
        if annotation is None:
            raise CohortSimilarityError(
                f"baseline selection lacks annotation: {selected_key}"
            )
        if annotation["label"] != "different_cohort":
            continue
        reason = annotation["reason"]
        reason_counts[reason] = reason_counts.get(reason, 0) + 1
        anchor_key = (selection["case_id"], selection["anchor_id"])
        alternatives = [
            (pair, candidate_annotation)
            for pair, candidate_annotation in annotated_by_anchor.get(
                anchor_key, []
            )
            if candidate_annotation["label"] == "same_cohort"
        ]
        best_alternative = (
            max(
                alternatives,
                key=lambda item: (
                    item[0]["cosine"],
                    item[0]["overlap_count"],
                    partner_for_anchor(item[0], selection["anchor_id"]),
                ),
            )
            if alternatives
            else None
        )
        selected_partner_id = partner_for_anchor(
            selected, selection["anchor_id"]
        )
        selected_partner = pair_member(selected, selected_partner_id)
        query = selected["query"]
        selected_query_overlap = len(
            shared_content_tokens(query, selected_partner["text"])
        )
        selected_query_score = (
            None
            if query_candidate_scores is None
            else query_candidate_scores.get(
                (selection["case_id"], selected_partner_id)
            )
        )
        alternative_payload = None
        if best_alternative is None:
            alternative_counts["missing"] += 1
        else:
            alternative_counts["available"] += 1
            alternative, alternative_annotation = best_alternative
            alternative_partner_id = partner_for_anchor(
                alternative, selection["anchor_id"]
            )
            alternative_partner = pair_member(
                alternative, alternative_partner_id
            )
            alternative_query_overlap = len(
                shared_content_tokens(query, alternative_partner["text"])
            )
            if alternative_query_overlap > selected_query_overlap:
                query_overlap_comparison["alternative_higher"] += 1
            elif alternative_query_overlap == selected_query_overlap:
                query_overlap_comparison["equal"] += 1
            else:
                query_overlap_comparison["wrong_higher"] += 1
            cosine_gap = selected["cosine"] - alternative["cosine"]
            cosine_gaps.append(cosine_gap)
            alternative_query_score = (
                None
                if query_candidate_scores is None
                else query_candidate_scores.get(
                    (selection["case_id"], alternative_partner_id)
                )
            )
            if query_candidate_scores is not None:
                if selected_query_score is None or alternative_query_score is None:
                    raise CohortSimilarityError(
                        "failure candidate is missing from retrieval results"
                    )
                if alternative_query_score > selected_query_score:
                    query_score_comparison["alternative_higher"] += 1
                elif alternative_query_score == selected_query_score:
                    query_score_comparison["equal"] += 1
                else:
                    query_score_comparison["wrong_higher"] += 1
                wrong_minus_alternative_query_scores.append(
                    selected_query_score - alternative_query_score
                )
            alternative_payload = {
                "pair_id": alternative_annotation["pair_id"],
                "partner_id": alternative_partner_id,
                "partner_text": alternative_partner["text"],
                "cosine": alternative["cosine"],
                "pair_overlap": alternative["overlap_count"],
                "query_partner_overlap": alternative_query_overlap,
                "query_candidate_score": alternative_query_score,
                "selected_minus_alternative_cosine": cosine_gap,
            }

        comparison = comparison_rows[anchor_key]
        comparison_pair = comparison["selected_pair"]
        if comparison_pair is None:
            transition = "abstained"
        else:
            comparison_annotation = annotations.get(annotation_key(
                comparison["case_id"], *pair_ids(comparison_pair)
            ))
            if comparison_annotation is None:
                raise CohortSimilarityError(
                    "comparison-gate selection lacks a blind annotation"
                )
            transition = comparison_annotation["label"]
        transition_counts[transition] = transition_counts.get(transition, 0) + 1
        failures.append({
            "case_id": selection["case_id"],
            "query": query,
            "anchor_id": selection["anchor_id"],
            "anchor_text": pair_member(
                selected, selection["anchor_id"]
            )["text"],
            "selected_wrong": {
                "pair_id": annotation["pair_id"],
                "reason": reason,
                "partner_id": selected_partner_id,
                "partner_text": selected_partner["text"],
                "cosine": selected["cosine"],
                "pair_overlap": selected["overlap_count"],
                "query_partner_overlap": selected_query_overlap,
                "query_candidate_score": selected_query_score,
            },
            "best_annotated_same_cohort": alternative_payload,
            "comparison_gate_transition": transition,
        })

    return {
        "baseline": {
            "cosine_threshold": baseline[0],
            "overlap_threshold": baseline[1],
        },
        "comparison_gate": {
            "cosine_threshold": comparison_gate[0],
            "overlap_threshold": comparison_gate[1],
        },
        "failure_count": len(failures),
        "reason_counts": reason_counts,
        "comparison_gate_transitions": transition_counts,
        "annotated_same_cohort_alternative": alternative_counts,
        "query_partner_overlap_comparison": query_overlap_comparison,
        "query_candidate_score_comparison": query_score_comparison,
        "wrong_minus_best_alternative_cosine": describe(cosine_gaps),
        "wrong_minus_best_alternative_query_score": describe(
            wrong_minus_alternative_query_scores
        ),
        "failures": failures,
    }


def rescore_blind_annotations(
    *,
    pair_scores_path: Path,
    source_partner_sweep_path: Path,
    annotations_path: Path,
    output_dir: Path,
    retrieval_results_path: Path | None = None,
    abc_annotations_path: Path | None = None,
) -> dict[str, Any]:
    pair_rows = prepare.read_jsonl(pair_scores_path)
    annotations = load_cohort_annotations(annotations_path)
    abc_annotations = (
        {}
        if abc_annotations_path is None or not abc_annotations_path.is_file()
        else load_cohort_annotations(abc_annotations_path)
    )
    combined_annotations = merge_cohort_annotations(
        annotations, abc_annotations
    )
    annotated = annotated_pair_rows(pair_rows, annotations)
    positives = [
        pair for pair in annotated
        if pair["annotation_label"] == "same_cohort"
    ]
    negatives = [
        pair for pair in annotated
        if pair["annotation_label"] == "different_cohort"
    ]
    ambiguous = [
        pair for pair in annotated
        if pair["annotation_label"] == "ambiguous"
    ]
    if not positives or not negatives:
        raise CohortSimilarityError(
            "annotation rescore requires same- and different-cohort pairs"
        )
    negative_scores_by_case: dict[str, list[float]] = {}
    negative_pairs_by_case: dict[str, list[dict[str, Any]]] = {}
    for pair in negatives:
        negative_scores_by_case.setdefault(pair["case_id"], []).append(
            pair["cosine"]
        )
        negative_pairs_by_case.setdefault(pair["case_id"], []).append(pair)

    threshold_rows = threshold_metrics(
        [pair["cosine"] for pair in positives],
        negative_scores_by_case,
        DEFAULT_THRESHOLDS,
    )
    combined_rows = combined_gate_metrics(
        positives,
        negative_pairs_by_case,
        (-1.0, *DEFAULT_THRESHOLDS),
        DEFAULT_OVERLAP_THRESHOLDS,
    )
    source_partner_sweep = json.loads(
        source_partner_sweep_path.read_text(encoding="utf-8")
    )["rows"]
    configs = [
        (row["cosine_threshold"], row["overlap_threshold"])
        for row in source_partner_sweep
    ]
    case_rows = group_case_pair_rows(pair_rows)
    partner_rows = annotation_partner_top1_metrics(
        case_rows,
        annotations,
        configs,
    )
    query_candidate_scores = (
        None
        if retrieval_results_path is None
        else load_query_candidate_scores(retrieval_results_path)
    )
    failure_analysis = analyze_partner_failures(
        case_rows,
        annotations,
        query_candidate_scores=query_candidate_scores,
    )
    abc_policy_rows = (
        []
        if query_candidate_scores is None
        else annotation_abc_policy_metrics(
            case_rows,
            combined_annotations,
            query_candidate_scores,
        )
    )
    abc_policy_transitions = (
        {}
        if query_candidate_scores is None or not abc_annotations
        else annotation_abc_policy_transitions(
            case_rows,
            combined_annotations,
            query_candidate_scores,
        )
    )
    summary = {
        "phase": "blind_annotation_rescore_complete",
        "runner_version": RUNNER_VERSION,
        "inputs": {
            "pair_scores_sha256": dense.sha256_file(pair_scores_path),
            "annotations_sha256": dense.sha256_file(annotations_path),
            "source_partner_sweep_sha256": dense.sha256_file(
                source_partner_sweep_path
            ),
            "retrieval_results_sha256": (
                None
                if retrieval_results_path is None
                else dense.sha256_file(retrieval_results_path)
            ),
            "abc_annotations_sha256": (
                None
                if not abc_annotations
                else dense.sha256_file(abc_annotations_path)
            ),
        },
        "annotation_contract": {
            "positive": "same_cohort",
            "negative": "different_cohort",
            "excluded_from_binary_metrics": "ambiguous",
            "threshold_policy": (
                "Diagnostic sweep only; do not select an operating threshold "
                "on EdgeMemBench v0."
            ),
        },
        "coverage": {
            "annotated_pairs": len(annotated),
            "same_cohort_pairs": len(positives),
            "different_cohort_pairs": len(negatives),
            "ambiguous_pairs": len(ambiguous),
        },
        "distributions": {
            "same_cohort_cosine": describe([
                pair["cosine"] for pair in positives
            ]),
            "different_cohort_cosine": describe([
                pair["cosine"] for pair in negatives
            ]),
            "same_cohort_overlap": describe([
                pair["overlap_count"] for pair in positives
            ]),
            "different_cohort_overlap": describe([
                pair["overlap_count"] for pair in negatives
            ]),
        },
        "separation": {
            "cosine_auroc": dense.roc_auc(
                [pair["cosine"] for pair in positives],
                [pair["cosine"] for pair in negatives],
            ),
            "cosine_average_precision": average_precision(
                [pair["cosine"] for pair in positives],
                [pair["cosine"] for pair in negatives],
            ),
            "overlap_auroc": dense.roc_auc(
                [pair["overlap_count"] for pair in positives],
                [pair["overlap_count"] for pair in negatives],
            ),
            "overlap_average_precision": average_precision(
                [pair["overlap_count"] for pair in positives],
                [pair["overlap_count"] for pair in negatives],
            ),
        },
        "limitations": [
            (
                "The 178-pair queue is a selected union of reviewed seeds "
                "and partner candidates, not an IID sample of all Top-20 pairs."
            ),
            (
                "The labels are GPT-5.6-sol multi-rater silver annotations, "
                "not human-validated ground truth."
            ),
            (
                "EdgeMemBench v0 remains a test set; threshold selection "
                "requires a separate calibration split."
            ),
        ],
    }
    prepare.write_json_atomic(
        output_dir / "annotation_rescore_summary.json",
        summary,
    )
    prepare.write_json_atomic(
        output_dir / "annotation_threshold_sweep.json",
        {
            "cosine_only": threshold_rows,
            "cosine_and_overlap": combined_rows,
        },
    )
    prepare.write_json_atomic(
        output_dir / "annotation_partner_top1_sweep.json",
        {"rows": partner_rows},
    )
    prepare.write_json_atomic(
        output_dir / "annotation_partner_failure_analysis.json",
        failure_analysis,
    )
    prepare.write_json_atomic(
        output_dir / "annotation_abc_policy_sweep.json",
        {
            "rows": abc_policy_rows,
            "transitions": abc_policy_transitions,
        },
    )
    return summary


def usable_conflict_record(record: dict[str, Any]) -> bool:
    expected = record["expected"]
    return (
        record["axis"] == "C"
        and expected["evaluation_status"] == "scored"
        and bool(expected["target_evidence_turn_ids"])
        and bool(expected["competing_evidence_turn_ids"])
    )


def pair_row(
    *,
    record: dict[str, Any],
    label: str,
    left: dense.Candidate,
    right: dense.Candidate,
    score: float,
    operational: bool,
) -> dict[str, Any]:
    shared_tokens = shared_content_tokens(left.text, right.text)
    return {
        "case_id": record["case_id"],
        "query": record["query"],
        "temporal_subtype": record["expected"]["temporal_subtype"],
        "label": label,
        "operational": operational,
        "left": {
            "turn_id": left.turn_id,
            "text": left.text,
            "timestamp": list(left.timestamp),
        },
        "right": {
            "turn_id": right.turn_id,
            "text": right.text,
            "timestamp": list(right.timestamp),
        },
        "cosine": score,
        "shared_tokens": list(shared_tokens),
        "overlap_count": len(shared_tokens),
    }


def analyze_record(
    record: dict[str, Any],
    store: dense.EmbeddingStore,
    *,
    top_k: int,
    vector_cache: dict[str, tuple[float, ...]],
) -> dict[str, Any] | None:
    if not usable_conflict_record(record):
        return None

    ranked, _ = dense.rank_record(record, store)
    candidate_pool = ranked[:top_k]
    pool_ids = {item.candidate.turn_id for item in candidate_pool}
    candidates = {
        candidate.turn_id: candidate
        for candidate in dense.candidates_for_record(record)
    }
    expected = record["expected"]
    target_ids = set(expected["target_evidence_turn_ids"])
    competing_ids = set(expected["competing_evidence_turn_ids"])
    context_ids = set(expected["context_evidence_turn_ids"])
    evidence_ids = (
        target_ids
        | competing_ids
        | context_ids
        | set(expected["gold_evidence_turn_ids"])
    )

    def vector(candidate: dense.Candidate) -> tuple[float, ...]:
        identifier = dense.embedding_id("document", candidate.text)
        if identifier not in vector_cache:
            vector_cache[identifier] = store.vector("document", candidate.text)
        return vector_cache[identifier]

    def similarity(left: dense.Candidate, right: dense.Candidate) -> float:
        return dense.cosine_similarity(vector(left), vector(right))

    positive_rows: list[dict[str, Any]] = []
    positive_pair_ids: set[tuple[str, str]] = set()
    for target_id in sorted(target_ids):
        for competing_id in sorted(competing_ids):
            pair_ids = canonical_pair(target_id, competing_id)
            if pair_ids in positive_pair_ids:
                continue
            positive_pair_ids.add(pair_ids)
            left = candidates[target_id]
            right = candidates[competing_id]
            positive_rows.append(
                pair_row(
                    record=record,
                    label="same_fact_version",
                    left=left,
                    right=right,
                    score=similarity(left, right),
                    operational=(target_id in pool_ids and competing_id in pool_ids),
                )
            )

    negative_rows: list[dict[str, Any]] = []
    seen_negative_pairs: set[tuple[str, str]] = set()
    anchor_ids = (target_ids | competing_ids) & pool_ids
    negative_candidates = [
        item.candidate
        for item in candidate_pool
        if item.candidate.turn_id not in evidence_ids
    ]
    for anchor_id in sorted(anchor_ids):
        anchor = candidates[anchor_id]
        for negative in negative_candidates:
            pair_ids = canonical_pair(anchor_id, negative.turn_id)
            if pair_ids in seen_negative_pairs:
                continue
            seen_negative_pairs.add(pair_ids)
            negative_rows.append(
                pair_row(
                    record=record,
                    label="non_evidence_top_k",
                    left=anchor,
                    right=negative,
                    score=similarity(anchor, negative),
                    operational=True,
                )
            )

    operational_positives = [
        row for row in positive_rows if row["operational"]
    ]
    hardest_negative = (
        max(negative_rows, key=lambda row: row["cosine"])
        if negative_rows
        else None
    )
    hardest_score = (
        None if hardest_negative is None else hardest_negative["cosine"]
    )
    margins = [
        {
            "positive_cosine": row["cosine"],
            "hardest_negative_cosine": hardest_score,
            "margin": (
                None if hardest_score is None else row["cosine"] - hardest_score
            ),
        }
        for row in operational_positives
    ]
    return {
        "case_id": record["case_id"],
        "query": record["query"],
        "temporal_subtype": expected["temporal_subtype"],
        "top_k_turn_ids": [item.candidate.turn_id for item in candidate_pool],
        "positive_pairs": positive_rows,
        "negative_pairs": negative_rows,
        "hardest_negative": hardest_negative,
        "operational_margins": margins,
    }


def flattened(rows: Iterable[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    return [pair for row in rows for pair in row[key]]


def build_summary(
    rows: Sequence[dict[str, Any]],
    *,
    top_k: int,
    thresholds: Sequence[float],
    overlap_thresholds: Sequence[int],
    artifact_dir: Path,
    embeddings_path: Path,
) -> tuple[
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
]:
    positives = flattened(rows, "positive_pairs")
    operational_positives = [row for row in positives if row["operational"]]
    negatives = flattened(rows, "negative_pairs")
    positive_scores = [row["cosine"] for row in positives]
    operational_positive_scores = [
        row["cosine"] for row in operational_positives
    ]
    negative_scores = [row["cosine"] for row in negatives]
    negative_scores_by_case = {
        row["case_id"]: [
            pair["cosine"] for pair in row["negative_pairs"]
        ]
        for row in rows
    }
    negative_pairs_by_case = {
        row["case_id"]: row["negative_pairs"]
        for row in rows
    }
    hardest_negative_scores = [
        row["hardest_negative"]["cosine"]
        for row in rows
        if row["hardest_negative"] is not None
    ]
    margins = [
        margin["margin"]
        for row in rows
        for margin in row["operational_margins"]
        if margin["margin"] is not None
    ]
    if not operational_positive_scores or not negative_scores:
        raise CohortSimilarityError(
            "operational analysis requires positive and negative pairs"
        )

    sweep = threshold_metrics(
        operational_positive_scores,
        negative_scores_by_case,
        thresholds,
    )
    combined_sweep = combined_gate_metrics(
        operational_positives,
        negative_pairs_by_case,
        (-1.0, *thresholds),
        overlap_thresholds,
    )
    partner_sweep = partner_top1_metrics(
        rows,
        (-1.0, *thresholds),
        (0, *overlap_thresholds),
    )
    summary = {
        "phase": "cohort_similarity_diagnostic_complete",
        "runner_version": RUNNER_VERSION,
        "benchmark_version": prepare.load_manifest()["version"],
        "hypothesis": (
            "Manually reviewed target/competing temporal versions have "
            "higher pairwise document cosine than non-evidence candidates "
            "in the same Dense Top-K pool."
        ),
        "contract": {
            "axis": "C",
            "positive_pair": "target evidence x competing evidence",
            "negative_pair": (
                "target/competing evidence x non-evidence Dense Top-K "
                "candidate; context evidence excluded"
            ),
            "candidate_source": f"Dense Top-{top_k}",
            "similarity": "document-to-document cosine",
            "lexical_overlap": (
                "NFKC/casefold content-token set intersection after value, "
                "English stopword, and temporal-marker removal"
            ),
            "reranking": "not run",
            "threshold_policy": (
                "Exploratory sweep only; no operating threshold is selected "
                "on EdgeMemBench v0."
            ),
        },
        "inputs": {
            "artifact_manifest_sha256": dense.sha256_file(
                artifact_dir / "artifact_manifest.json"
            ),
            "embeddings_sha256": dense.sha256_file(embeddings_path),
            "embedding_model_id": dense.MODEL_ID,
        },
        "coverage": {
            "usable_conflict_cases": len(rows),
            "intrinsic_positive_pairs": len(positives),
            "operational_positive_pairs": len(operational_positives),
            "operational_positive_pair_recall": (
                len(operational_positives) / len(positives)
            ),
            "negative_pairs": len(negatives),
        },
        "distributions": {
            "intrinsic_positive": describe(positive_scores),
            "operational_positive": describe(operational_positive_scores),
            "all_operational_negative": describe(negative_scores),
            "hardest_negative_per_case": describe(hardest_negative_scores),
            "positive_minus_case_hardest_negative": describe(margins),
            "positive_overlap_count": describe([
                pair["overlap_count"] for pair in operational_positives
            ]),
            "negative_overlap_count": describe([
                pair["overlap_count"] for pair in negatives
            ]),
        },
        "separation": {
            "pair_level_auroc": dense.roc_auc(
                operational_positive_scores,
                negative_scores,
            ),
            "pair_level_average_precision": average_precision(
                operational_positive_scores,
                negative_scores,
            ),
            "overlap_count_auroc": dense.roc_auc(
                [pair["overlap_count"] for pair in operational_positives],
                [pair["overlap_count"] for pair in negatives],
            ),
            "overlap_count_average_precision": average_precision(
                [pair["overlap_count"] for pair in operational_positives],
                [pair["overlap_count"] for pair in negatives],
            ),
            "positive_above_case_hardest_negative_rate": (
                sum(margin > 0 for margin in margins) / len(margins)
                if margins
                else None
            ),
        },
        "limitations": [
            (
                "EdgeMemBench v0 is the test set, so threshold results are "
                "diagnostic and cannot establish a deployment threshold."
            ),
            (
                "Non-evidence Top-K candidates are retrieval distractors, "
                "not manually annotated universal non-version pairs."
            ),
            (
                "This experiment measures cohort identification only and "
                "does not measure temporal reranking quality."
            ),
            (
                "The lexical normalizer is an English EdgeMemBench v0 "
                "diagnostic; Korean morphology requires a separate contract."
            ),
        ],
    }
    threshold_output = {
        "runner_version": RUNNER_VERSION,
        "policy": summary["contract"]["threshold_policy"],
        "positive_pair_count": len(operational_positive_scores),
        "negative_pair_count": len(negative_scores),
        "rows": sweep,
    }
    combined_output = {
        "runner_version": RUNNER_VERSION,
        "policy": summary["contract"]["threshold_policy"],
        "gate": "cosine >= C AND content-token overlap >= N",
        "overlap_only_reference": (
            "Rows with cosine_threshold=-1.0 apply only the overlap gate."
        ),
        "positive_pair_count": len(operational_positives),
        "negative_pair_count": len(negatives),
        "rows": combined_sweep,
    }
    partner_output = {
        "runner_version": RUNNER_VERSION,
        "policy": summary["contract"]["threshold_policy"],
        "candidate_pool": (
            "Operational positive pairs plus non-evidence Dense Top-K "
            "pairs for each positive anchor; context evidence excluded."
        ),
        "selection": (
            "Among pairs passing cosine and overlap gates, select cosine "
            "descending, overlap descending, partner ID ascending."
        ),
        "cosine_only_reference": (
            "cosine_threshold=-1.0 and overlap_threshold=0"
        ),
        "clustering": "not run",
        "mutual_partner_gate": "not run",
        "rows": partner_sweep,
    }
    return summary, threshold_output, combined_output, partner_output


def run(
    *,
    artifact_dir: Path,
    embeddings_path: Path,
    output_dir: Path,
    top_k: int,
    thresholds: Sequence[float],
    overlap_thresholds: Sequence[int],
) -> dict[str, Any]:
    prepare.validate_artifacts(artifact_dir)
    if output_dir.exists():
        raise CohortSimilarityError(
            f"output directory already exists: {output_dir}"
        )
    if top_k < 1:
        raise CohortSimilarityError("top-k must be positive")
    if not thresholds:
        raise CohortSimilarityError("at least one threshold is required")
    if not overlap_thresholds:
        raise CohortSimilarityError(
            "at least one overlap threshold is required"
        )

    records = prepare.read_jsonl(
        artifact_dir / prepare.OUTPUT_FILES["C"]
    )
    store = dense.EmbeddingStore(embeddings_path)
    vector_cache: dict[str, tuple[float, ...]] = {}
    rows: list[dict[str, Any]] = []
    try:
        for record in records:
            row = analyze_record(
                record,
                store,
                top_k=top_k,
                vector_cache=vector_cache,
            )
            if row is not None:
                rows.append(row)
    finally:
        store.close()

    (
        summary,
        threshold_output,
        combined_output,
        partner_output,
    ) = build_summary(
        rows,
        top_k=top_k,
        thresholds=thresholds,
        overlap_thresholds=overlap_thresholds,
        artifact_dir=artifact_dir,
        embeddings_path=embeddings_path,
    )
    pair_rows = [
        pair
        for row in rows
        for pair in row["positive_pairs"] + row["negative_pairs"]
    ]
    output_dir.mkdir(parents=True)
    prepare.write_jsonl_atomic(output_dir / "pair_scores.jsonl", pair_rows)
    prepare.write_json_atomic(output_dir / "threshold_sweep.json", threshold_output)
    prepare.write_json_atomic(
        output_dir / "combined_gate_sweep.json",
        combined_output,
    )
    prepare.write_json_atomic(
        output_dir / "partner_top1_sweep.json",
        partner_output,
    )
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
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
    )
    parser.add_argument(
        "--annotations",
        type=Path,
        default=DEFAULT_ANNOTATIONS_PATH,
    )
    parser.add_argument(
        "--retrieval-results",
        type=Path,
        default=DEFAULT_RETRIEVAL_RESULTS_PATH,
    )
    parser.add_argument(
        "--abc-annotations",
        type=Path,
        default=DEFAULT_ABC_ANNOTATIONS_PATH,
    )
    parser.add_argument(
        "--rescore-annotations",
        action="store_true",
        help="Rescore existing pair/partner artifacts with frozen annotations",
    )
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    parser.add_argument(
        "--thresholds",
        type=float,
        nargs="+",
        default=list(DEFAULT_THRESHOLDS),
    )
    parser.add_argument(
        "--overlap-thresholds",
        type=int,
        nargs="+",
        default=list(DEFAULT_OVERLAP_THRESHOLDS),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.rescore_annotations:
            summary = rescore_blind_annotations(
                pair_scores_path=arguments.output_dir / "pair_scores.jsonl",
                source_partner_sweep_path=(
                    arguments.output_dir / "partner_top1_sweep.json"
                ),
                annotations_path=arguments.annotations,
                output_dir=arguments.output_dir,
                retrieval_results_path=arguments.retrieval_results,
                abc_annotations_path=arguments.abc_annotations,
            )
        else:
            summary = run(
                artifact_dir=arguments.artifact_dir,
                embeddings_path=arguments.embeddings,
                output_dir=arguments.output_dir,
                top_k=arguments.top_k,
                thresholds=arguments.thresholds,
                overlap_thresholds=arguments.overlap_thresholds,
            )
    except (
        CohortSimilarityError,
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
