#!/usr/bin/env python3
"""Calibrate the query-score band for temporal cohort selection.

The calibration split selects one delta. The held-out split is scored only
after that choice. EdgeMemBench v0 is not read by this runner and remains a
separate retrospective regression check.
"""

from __future__ import annotations

import argparse
import json
import math
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Sequence

import cohort_similarity_runner as cohort
import prepare
import retrieval_runner as dense


ROOT = Path(__file__).resolve().parent
RUNNER_VERSION = "0.1.0"
DATASET_VERSION = "cohort-delta-calibration-v1"
DEFAULT_DATASET_PATH = ROOT / "data" / "cohort_delta_calibration.jsonl"
DEFAULT_OUTPUT_DIR = (
    dense.DEFAULT_RETRIEVAL_DIR / "cohort-calibration"
)
DEFAULT_INPUTS_PATH = DEFAULT_OUTPUT_DIR / "embedding_inputs.jsonl"
DEFAULT_EMBEDDINGS_PATH = DEFAULT_OUTPUT_DIR / "embeddinggemma.sqlite3"
DEFAULT_DELTAS = cohort.DEFAULT_QUERY_SCORE_DELTAS
SCORE_EPSILON = 1e-12
EXPECTED_CASES = 50
EXPECTED_PAIRS = 100
EXPECTED_SPLITS = {"calibration": 35, "holdout": 15}
ALLOWED_LABELS = {"same_cohort", "different_cohort"}
ALLOWED_REASONS = {
    "same_attribute_update",
    "different_attribute",
    "separate_event",
    "different_entity",
}


class CohortCalibrationError(RuntimeError):
    """Raised when the calibration contract is violated."""


def normalized_text(text: Any, *, field: str) -> str:
    if not isinstance(text, str) or not text.strip():
        raise CohortCalibrationError(f"{field} must be a non-empty string")
    return " ".join(text.split())


def validate_turn(turn: Any, *, field: str) -> None:
    if not isinstance(turn, dict):
        raise CohortCalibrationError(f"{field} must be an object")
    normalized_text(turn.get("turn_id"), field=f"{field}.turn_id")
    normalized_text(turn.get("text"), field=f"{field}.text")
    occurred_at = normalized_text(
        turn.get("occurred_at"), field=f"{field}.occurred_at"
    )
    try:
        parsed = datetime.fromisoformat(occurred_at)
    except ValueError as exc:
        raise CohortCalibrationError(
            f"{field}.occurred_at must be ISO-8601"
        ) from exc
    if parsed.tzinfo is None:
        raise CohortCalibrationError(
            f"{field}.occurred_at must include a UTC offset"
        )


def load_dataset(path: Path = DEFAULT_DATASET_PATH) -> list[dict[str, Any]]:
    source_spec = prepare.load_manifest()["sources"]["cohort_delta_calibration"]
    actual_sha = dense.sha256_file(path)
    if actual_sha != source_spec["sha256"]:
        raise CohortCalibrationError(
            f"calibration dataset SHA-256 mismatch: {actual_sha}"
        )
    if source_spec["expected_cases"] != EXPECTED_CASES:
        raise CohortCalibrationError("manifest case count differs from runner")
    if source_spec["expected_pairs"] != EXPECTED_PAIRS:
        raise CohortCalibrationError("manifest pair count differs from runner")
    if source_spec["split"] != EXPECTED_SPLITS:
        raise CohortCalibrationError("manifest split counts differ from runner")
    rows = prepare.read_jsonl(path)
    if len(rows) != EXPECTED_CASES:
        raise CohortCalibrationError(
            f"expected {EXPECTED_CASES} cases, found {len(rows)}"
        )

    seen_cases: set[str] = set()
    seen_families: set[str] = set()
    seen_turns: set[str] = set()
    seen_texts: set[str] = set()
    split_counts = {split: 0 for split in EXPECTED_SPLITS}
    pair_count = 0

    for row in rows:
        case_id = normalized_text(row.get("case_id"), field="case_id")
        family = normalized_text(row.get("family"), field=f"{case_id}.family")
        split = row.get("split")
        if case_id in seen_cases:
            raise CohortCalibrationError(f"duplicate case_id: {case_id}")
        if family in seen_families:
            raise CohortCalibrationError(f"duplicate family: {family}")
        if split not in EXPECTED_SPLITS:
            raise CohortCalibrationError(f"{case_id}: invalid split {split!r}")
        seen_cases.add(case_id)
        seen_families.add(family)
        split_counts[split] += 1
        normalized_text(row.get("difficulty"), field=f"{case_id}.difficulty")
        normalized_text(row.get("query"), field=f"{case_id}.query")

        anchor = row.get("anchor")
        validate_turn(anchor, field=f"{case_id}.anchor")
        candidates = row.get("candidates")
        if not isinstance(candidates, list) or len(candidates) != 2:
            raise CohortCalibrationError(
                f"{case_id}: exactly two candidates are required"
            )
        labels = []
        for index, candidate in enumerate(candidates):
            field = f"{case_id}.candidates[{index}]"
            validate_turn(candidate, field=field)
            label = candidate.get("label")
            reason = candidate.get("reason")
            if label not in ALLOWED_LABELS:
                raise CohortCalibrationError(f"{field}: invalid label")
            if reason not in ALLOWED_REASONS:
                raise CohortCalibrationError(f"{field}: invalid reason")
            labels.append(label)
            pair_count += 1

        if sorted(labels) != ["different_cohort", "same_cohort"]:
            raise CohortCalibrationError(
                f"{case_id}: requires one same and one different candidate"
            )

        for turn in [anchor, *candidates]:
            turn_id = turn["turn_id"]
            text = normalized_text(turn["text"], field=f"{turn_id}.text")
            if turn_id in seen_turns:
                raise CohortCalibrationError(f"duplicate turn_id: {turn_id}")
            if text in seen_texts:
                raise CohortCalibrationError(f"duplicate text: {text}")
            seen_turns.add(turn_id)
            seen_texts.add(text)

    if split_counts != EXPECTED_SPLITS:
        raise CohortCalibrationError(
            f"invalid split counts: {split_counts!r}"
        )
    if pair_count != EXPECTED_PAIRS:
        raise CohortCalibrationError(
            f"expected {EXPECTED_PAIRS} pairs, found {pair_count}"
        )
    return rows


def embedding_records(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    unique: dict[str, dict[str, Any]] = {}
    for row in rows:
        query = dense.embedding_input("query", row["query"])
        unique.setdefault(query["embedding_id"], query)
        for turn in [row["anchor"], *row["candidates"]]:
            document = dense.embedding_input("document", turn["text"])
            unique.setdefault(document["embedding_id"], document)
    return sorted(
        unique.values(), key=lambda item: (item["kind"], item["embedding_id"])
    )


def prepare_embeddings(
    dataset_path: Path,
    inputs_path: Path,
) -> dict[str, Any]:
    rows = load_dataset(dataset_path)
    records = embedding_records(rows)
    payload = "".join(
        json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
        for row in records
    )
    if inputs_path.exists():
        if inputs_path.read_text(encoding="utf-8") != payload:
            raise CohortCalibrationError(
                f"existing embedding inputs differ: {inputs_path}"
            )
    else:
        inputs_path.parent.mkdir(parents=True, exist_ok=True)
        inputs_path.write_text(payload, encoding="utf-8")

    manifest = {
        "phase": "cohort_calibration_embeddings_prepared",
        "runner_version": RUNNER_VERSION,
        "dataset_version": DATASET_VERSION,
        "dataset_sha256": dense.sha256_file(dataset_path),
        "case_count": len(rows),
        "pair_count": sum(len(row["candidates"]) for row in rows),
        "embedding_inputs": {
            "path": inputs_path.name,
            "sha256": dense.sha256_file(inputs_path),
            "records": len(records),
            "queries": sum(row["kind"] == "query" for row in records),
            "documents": sum(row["kind"] == "document" for row in records),
        },
        "embedding_contract": {
            "model_id": dense.MODEL_ID,
            "sequence_length": dense.SEQUENCE_LENGTH,
            "dimension": dense.EXPECTED_DIMENSION,
            "query_prefix": dense.QUERY_PREFIX,
            "document_prefix": dense.DOCUMENT_PREFIX,
        },
    }
    prepare.write_json_atomic(inputs_path.with_suffix(".manifest.json"), manifest)
    return manifest


def candidate_scores(
    row: dict[str, Any], store: dense.EmbeddingStore
) -> list[dict[str, Any]]:
    query_vector = store.vector("query", row["query"])
    anchor_vector = store.vector("document", row["anchor"]["text"])
    scores = []
    for candidate in row["candidates"]:
        candidate_vector = store.vector("document", candidate["text"])
        scores.append({
            "turn_id": candidate["turn_id"],
            "label": candidate["label"],
            "reason": candidate["reason"],
            "query_score": dense.cosine_similarity(
                query_vector, candidate_vector
            ),
            "pair_score": dense.cosine_similarity(
                anchor_vector, candidate_vector
            ),
        })
    return scores


def select_candidate(
    candidates: Sequence[dict[str, Any]], delta: float
) -> dict[str, Any]:
    if delta < 0 or (not math.isfinite(delta) and delta != math.inf):
        raise CohortCalibrationError("delta must be non-negative or infinity")
    best_query_score = max(row["query_score"] for row in candidates)
    band = [
        row for row in candidates
        if best_query_score - row["query_score"] <= delta + SCORE_EPSILON
    ]
    return max(
        sorted(band, key=lambda row: row["turn_id"]),
        key=lambda row: row["pair_score"],
    )


def wilson_interval(successes: int, total: int) -> tuple[float, float]:
    if total < 1:
        raise CohortCalibrationError("Wilson interval requires observations")
    z = 1.959963984540054
    proportion = successes / total
    denominator = 1 + z * z / total
    centre = (proportion + z * z / (2 * total)) / denominator
    margin = z * math.sqrt(
        proportion * (1 - proportion) / total + z * z / (4 * total * total)
    ) / denominator
    return centre - margin, centre + margin


def score_delta(
    scored_cases: Sequence[dict[str, Any]], delta: float
) -> dict[str, Any]:
    details = []
    for case in scored_cases:
        selected = select_candidate(case["candidates"], delta)
        details.append({
            "case_id": case["case_id"],
            "family": case["family"],
            "selected_turn_id": selected["turn_id"],
            "selected_label": selected["label"],
            "correct": selected["label"] == "same_cohort",
        })
    correct = sum(row["correct"] for row in details)
    lower, upper = wilson_interval(correct, len(details))
    return {
        "delta": "inf" if delta == math.inf else delta,
        "cases": len(details),
        "correct": correct,
        "accuracy": correct / len(details),
        "wilson_95": [lower, upper],
        "details": details,
    }


def choose_delta(rows: Sequence[dict[str, Any]]) -> float:
    finite = [row for row in rows if row["delta"] != "inf"]
    if not finite:
        raise CohortCalibrationError("at least one finite delta is required")
    winner = max(
        finite,
        key=lambda row: (row["accuracy"], -float(row["delta"])),
    )
    return float(winner["delta"])


def score_cases(
    rows: Sequence[dict[str, Any]], store: dense.EmbeddingStore
) -> list[dict[str, Any]]:
    return [
        {
            "case_id": row["case_id"],
            "split": row["split"],
            "family": row["family"],
            "query": row["query"],
            "candidates": candidate_scores(row, store),
        }
        for row in rows
    ]


def evaluate(
    dataset_path: Path,
    embeddings_path: Path,
    output_dir: Path,
    deltas: Sequence[float] = DEFAULT_DELTAS,
) -> dict[str, Any]:
    rows = load_dataset(dataset_path)
    store = dense.EmbeddingStore(embeddings_path)
    try:
        scored = score_cases(rows, store)
    finally:
        store.close()

    calibration = [row for row in scored if row["split"] == "calibration"]
    holdout = [row for row in scored if row["split"] == "holdout"]
    calibration_sweep = [score_delta(calibration, delta) for delta in deltas]
    selected_delta = choose_delta(calibration_sweep)
    holdout_policies = {
        "B_query_only": score_delta(holdout, 0.0),
        "C_frozen_delta": score_delta(holdout, selected_delta),
        "A_pair_only": score_delta(holdout, math.inf),
    }
    summary = {
        "phase": "cohort_delta_calibration_complete",
        "runner_version": RUNNER_VERSION,
        "dataset_version": DATASET_VERSION,
        "inputs": {
            "dataset_sha256": dense.sha256_file(dataset_path),
            "embedding_database_sha256": dense.sha256_file(embeddings_path),
            "embedding_model_sha256": store.metadata["model_sha256"],
            "tokenizer_sha256": store.metadata["tokenizer_sha256"],
        },
        "selection_contract": {
            "selection_split": "calibration",
            "selection_metric": "same-cohort partner accuracy",
            "tie_break": "smallest finite delta",
            "holdout_opened_after_selection": True,
            "edgemembench_v0_role": "retrospective regression only",
        },
        "selected_delta": selected_delta,
        "calibration_sweep": calibration_sweep,
        "holdout": holdout_policies,
        "limitations": [
            "The Korean cases are manually authored synthetic product proxies, not production conversations.",
            "The 15-case holdout has a wide confidence interval.",
            "The labels are deterministic by construction and have not received independent human review.",
            "This is embedding retrieval analysis on macOS, not iPhone latency or memory validation.",
        ],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    prepare.write_json_atomic(output_dir / "calibration_summary.json", summary)
    prepare.write_jsonl_atomic(output_dir / "scored_cases.jsonl", scored)
    return summary


def parse_delta(value: str) -> float:
    if value.casefold() == "inf":
        return math.inf
    parsed = float(value)
    if parsed < 0 or not math.isfinite(parsed):
        raise argparse.ArgumentTypeError("delta must be finite and non-negative")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET_PATH)

    prepare_parser = subparsers.add_parser("prepare-embeddings")
    prepare_parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET_PATH)
    prepare_parser.add_argument("--inputs", type=Path, default=DEFAULT_INPUTS_PATH)

    extract_parser = subparsers.add_parser("extract-embeddings")
    extract_parser.add_argument("--inputs", type=Path, default=DEFAULT_INPUTS_PATH)
    extract_parser.add_argument("--database", type=Path, default=DEFAULT_EMBEDDINGS_PATH)
    extract_parser.add_argument("--model", type=Path, required=True)
    extract_parser.add_argument("--tokenizer", type=Path, required=True)

    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET_PATH)
    evaluate_parser.add_argument("--database", type=Path, default=DEFAULT_EMBEDDINGS_PATH)
    evaluate_parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    evaluate_parser.add_argument(
        "--deltas", nargs="+", type=parse_delta, default=DEFAULT_DELTAS
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    if arguments.command == "validate":
        rows = load_dataset(arguments.dataset)
        print(json.dumps({
            "status": "PASS",
            "cases": len(rows),
            "pairs": sum(len(row["candidates"]) for row in rows),
            "sha256": dense.sha256_file(arguments.dataset),
        }, ensure_ascii=False, indent=2))
    elif arguments.command == "prepare-embeddings":
        print(json.dumps(
            prepare_embeddings(arguments.dataset, arguments.inputs),
            ensure_ascii=False,
            indent=2,
        ))
    elif arguments.command == "extract-embeddings":
        print(json.dumps(dense.extract_embeddings(
            arguments.inputs,
            arguments.database,
            arguments.model,
            arguments.tokenizer,
        ), ensure_ascii=False, indent=2))
    elif arguments.command == "evaluate":
        print(json.dumps(evaluate(
            arguments.dataset,
            arguments.database,
            arguments.output_dir,
            arguments.deltas,
        ), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CohortCalibrationError, dense.RetrievalRunnerError) as error:
        print(f"ERROR: {error}", file=__import__("sys").stderr)
        raise SystemExit(1) from error
