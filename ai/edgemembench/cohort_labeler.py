#!/usr/bin/env python3
"""Prepare, serve, validate, and export blind cohort-pair annotations."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import threading
import webbrowser
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import parse_qs, urlparse

import cohort_similarity_runner as cohort
import prepare
import retrieval_runner as dense


LABELER_VERSION = "0.1.0"
QUEUE_SEED = 42
ROOT = Path(__file__).resolve().parent
DEFAULT_SIMILARITY_DIR = (
    dense.DEFAULT_RETRIEVAL_DIR / "cohort-similarity"
)
DEFAULT_PAIR_SCORES_PATH = DEFAULT_SIMILARITY_DIR / "pair_scores.jsonl"
DEFAULT_PARTNER_SWEEP_PATH = (
    DEFAULT_SIMILARITY_DIR / "partner_top1_sweep.json"
)
DEFAULT_LABELING_DIR = dense.DEFAULT_RETRIEVAL_DIR / "cohort-labeling"
DEFAULT_QUEUE_PATH = DEFAULT_LABELING_DIR / "labeling_queue.jsonl"
DEFAULT_QUEUE_MANIFEST_PATH = DEFAULT_LABELING_DIR / "queue_manifest.json"
DEFAULT_DRAFT_PATH = DEFAULT_LABELING_DIR / "annotations.draft.jsonl"
DEFAULT_AGENT_DRAFT_PATH = DEFAULT_LABELING_DIR / "agent-consensus.draft.jsonl"
DEFAULT_AGENT_DISAGREEMENT_DIR = DEFAULT_LABELING_DIR / "agent-disagreements"
DEFAULT_EXPORT_PATH = ROOT / "data" / "cohort_pair_annotations.jsonl"
HTML_PATH = ROOT / "labeler" / "index.html"

LABEL_REASONS = {
    "same_cohort": {
        "same_attribute_update",
        "correction",
        "restatement",
    },
    "different_cohort": {
        "different_attribute",
        "separate_event",
        "different_entity",
    },
    "ambiguous": {"insufficient_context"},
}


class CohortLabelerError(RuntimeError):
    """Raised when the labeling queue or annotation contract is violated."""


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def pair_key(pair: dict[str, Any]) -> tuple[str, str, str]:
    left_id, right_id = cohort.canonical_pair(*cohort.pair_ids(pair))
    return pair["case_id"], left_id, right_id


def stable_pair_id(key: tuple[str, str, str]) -> str:
    digest = hashlib.sha256("\0".join(key).encode("utf-8")).hexdigest()
    return f"cohort-pair-{digest[:20]}"


def group_pair_rows(pair_rows: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for pair in pair_rows:
        case_id = pair["case_id"]
        case = grouped.setdefault(
            case_id,
            {
                "case_id": case_id,
                "positive_pairs": [],
                "negative_pairs": [],
            },
        )
        if pair["label"] == "same_fact_version":
            case["positive_pairs"].append(pair)
        elif pair["label"] == "non_evidence_top_k":
            case["negative_pairs"].append(pair)
        else:
            raise CohortLabelerError(
                f"unexpected source pair label: {pair['label']!r}"
            )
    return [grouped[case_id] for case_id in sorted(grouped)]


def selection_configs(partner_sweep: dict[str, Any]) -> list[tuple[float, int]]:
    rows = partner_sweep.get("rows")
    if not isinstance(rows, list) or not rows:
        raise CohortLabelerError("partner sweep has no rows")
    configs = {
        (row["cosine_threshold"], row["overlap_threshold"])
        for row in rows
    }
    return sorted(configs)


def chronological_pair(pair: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    members = [pair["left"], pair["right"]]
    members.sort(key=lambda member: (member["timestamp"], member["turn_id"]))
    return members[0], members[1]


def queue_record(
    pair: dict[str, Any],
    source_groups: set[str],
    selected_by: set[tuple[float, int]],
) -> dict[str, Any]:
    key = pair_key(pair)
    left, right = chronological_pair(pair)
    return {
        "pair_id": stable_pair_id(key),
        "case_id": key[0],
        "left": {
            "turn_id": left["turn_id"],
            "text": left["text"],
            "timestamp": left["timestamp"],
            "text_sha256": sha256_text(left["text"]),
        },
        "right": {
            "turn_id": right["turn_id"],
            "text": right["text"],
            "timestamp": right["timestamp"],
            "text_sha256": sha256_text(right["text"]),
        },
        "source_groups": sorted(source_groups),
        "selected_by": [
            {
                "cosine_threshold": cosine_threshold,
                "overlap_threshold": overlap_threshold,
            }
            for cosine_threshold, overlap_threshold in sorted(selected_by)
        ],
    }


def build_queue(
    pair_rows: Sequence[dict[str, Any]],
    partner_sweep: dict[str, Any],
    *,
    seed: int = QUEUE_SEED,
) -> list[dict[str, Any]]:
    cases = group_pair_rows(pair_rows)
    indexed_pairs = {pair_key(pair): pair for pair in pair_rows}
    selected: dict[tuple[str, str, str], dict[str, Any]] = {}

    for case in cases:
        for pair in case["positive_pairs"]:
            key = pair_key(pair)
            selected.setdefault(
                key,
                {"pair": pair, "source_groups": set(), "selected_by": set()},
            )["source_groups"].add("reviewed_target_competing_seed")

    for cosine_threshold, overlap_threshold in selection_configs(partner_sweep):
        for selection in cohort.partner_top1_selections(
            cases,
            cosine_threshold,
            overlap_threshold,
        ):
            pair = selection["selected_pair"]
            if pair is None:
                continue
            key = pair_key(pair)
            if key not in indexed_pairs:
                raise CohortLabelerError(f"selected pair is missing: {key}")
            entry = selected.setdefault(
                key,
                {"pair": pair, "source_groups": set(), "selected_by": set()},
            )
            entry["source_groups"].add("partner_top1_candidate")
            entry["selected_by"].add((cosine_threshold, overlap_threshold))

    queue = [
        queue_record(
            entry["pair"],
            entry["source_groups"],
            entry["selected_by"],
        )
        for _, entry in sorted(selected.items())
    ]
    random.Random(seed).shuffle(queue)
    validate_queue(queue)
    return queue


def validate_queue(queue: Sequence[dict[str, Any]]) -> None:
    if not queue:
        raise CohortLabelerError("labeling queue must not be empty")
    seen_pair_ids: set[str] = set()
    seen_keys: set[tuple[str, str, str]] = set()
    for row in queue:
        pair_id = row.get("pair_id")
        case_id = row.get("case_id")
        left = row.get("left")
        right = row.get("right")
        if not isinstance(pair_id, str) or not pair_id:
            raise CohortLabelerError("queue row has invalid pair_id")
        if pair_id in seen_pair_ids:
            raise CohortLabelerError(f"duplicate pair_id: {pair_id}")
        seen_pair_ids.add(pair_id)
        if not isinstance(case_id, str) or not case_id:
            raise CohortLabelerError(f"{pair_id}: invalid case_id")
        if not isinstance(left, dict) or not isinstance(right, dict):
            raise CohortLabelerError(f"{pair_id}: invalid pair members")
        key = (
            case_id,
            *cohort.canonical_pair(left["turn_id"], right["turn_id"]),
        )
        if key in seen_keys:
            raise CohortLabelerError(f"duplicate undirected pair: {key}")
        seen_keys.add(key)
        if stable_pair_id(key) != pair_id:
            raise CohortLabelerError(f"{pair_id}: unstable pair identifier")
        for member_name, member in (("left", left), ("right", right)):
            text = member.get("text")
            if not isinstance(text, str) or not text.strip():
                raise CohortLabelerError(
                    f"{pair_id}: {member_name} text is invalid"
                )
            if member.get("text_sha256") != sha256_text(text):
                raise CohortLabelerError(
                    f"{pair_id}: {member_name} text hash mismatch"
                )


def validate_annotation(
    annotation: dict[str, Any],
    valid_pair_ids: set[str],
) -> dict[str, Any]:
    pair_id = annotation.get("pair_id")
    label = annotation.get("label")
    reason = annotation.get("reason")
    note = annotation.get("note", "")
    if pair_id not in valid_pair_ids:
        raise CohortLabelerError(f"unknown annotation pair_id: {pair_id!r}")
    if label not in LABEL_REASONS:
        raise CohortLabelerError(f"invalid cohort label: {label!r}")
    if reason not in LABEL_REASONS[label]:
        raise CohortLabelerError(
            f"reason {reason!r} is invalid for label {label!r}"
        )
    if not isinstance(note, str) or len(note) > 1000:
        raise CohortLabelerError("annotation note must be at most 1000 characters")
    return {
        "pair_id": pair_id,
        "label": label,
        "reason": reason,
        "note": note.strip(),
        "annotated_at": datetime.now(timezone.utc).isoformat(),
    }


def load_annotations(
    path: Path,
    queue: Sequence[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    valid_pair_ids = {row["pair_id"] for row in queue}
    annotations: dict[str, dict[str, Any]] = {}
    for row in prepare.read_jsonl(path):
        pair_id = row.get("pair_id")
        if pair_id not in valid_pair_ids:
            raise CohortLabelerError(
                f"draft contains unknown pair_id: {pair_id!r}"
            )
        if pair_id in annotations:
            raise CohortLabelerError(f"draft contains duplicate pair_id: {pair_id}")
        label = row.get("label")
        reason = row.get("reason")
        if label not in LABEL_REASONS or reason not in LABEL_REASONS[label]:
            raise CohortLabelerError(f"{pair_id}: invalid draft label or reason")
        annotations[pair_id] = row
    return annotations


def save_annotation(
    path: Path,
    queue: Sequence[dict[str, Any]],
    annotations: dict[str, dict[str, Any]],
    payload: dict[str, Any],
) -> dict[str, Any]:
    valid_pair_ids = {row["pair_id"] for row in queue}
    normalized = validate_annotation(payload, valid_pair_ids)
    annotations[normalized["pair_id"]] = normalized
    ordered = [
        annotations[row["pair_id"]]
        for row in queue
        if row["pair_id"] in annotations
    ]
    prepare.write_jsonl_atomic(path, ordered)
    return normalized


def load_agent_votes(
    vote_specs: Sequence[tuple[str, Path]],
    queue: Sequence[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    """Load blinded agent votes and reject malformed or duplicate ballots."""
    valid_pair_ids = {row["pair_id"] for row in queue}
    votes_by_pair: dict[str, list[dict[str, Any]]] = {
        pair_id: [] for pair_id in valid_pair_ids
    }
    seen_ballots: set[tuple[str, str]] = set()
    for annotator, path in vote_specs:
        if not annotator or not path.is_file():
            raise CohortLabelerError(f"invalid agent vote source: {annotator}={path}")
        for row in prepare.read_jsonl(path):
            pair_id = row.get("pair_id")
            label = row.get("label")
            reason = row.get("reason")
            rationale = row.get("rationale", "")
            if pair_id not in valid_pair_ids:
                raise CohortLabelerError(
                    f"{annotator}: unknown vote pair_id: {pair_id!r}"
                )
            ballot_key = (annotator, pair_id)
            if ballot_key in seen_ballots:
                raise CohortLabelerError(
                    f"duplicate agent ballot: {annotator}/{pair_id}"
                )
            seen_ballots.add(ballot_key)
            if label not in LABEL_REASONS:
                raise CohortLabelerError(
                    f"{annotator}/{pair_id}: invalid label {label!r}"
                )
            if reason not in LABEL_REASONS[label]:
                raise CohortLabelerError(
                    f"{annotator}/{pair_id}: invalid reason {reason!r}"
                )
            if not isinstance(rationale, str) or not rationale.strip():
                raise CohortLabelerError(
                    f"{annotator}/{pair_id}: rationale must not be empty"
                )
            votes_by_pair[pair_id].append({
                "annotator": annotator,
                "label": label,
                "reason": reason,
                "rationale": rationale.strip(),
            })
    return votes_by_pair


def consensus_label(votes: Sequence[dict[str, Any]]) -> str | None:
    counts: dict[str, int] = {}
    for vote in votes:
        counts[vote["label"]] = counts.get(vote["label"], 0) + 1
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    if not ranked or ranked[0][1] < 2:
        return None
    return ranked[0][0]


def consensus_reason(
    label: str,
    votes: Sequence[dict[str, Any]],
) -> str:
    matching = [vote for vote in votes if vote["label"] == label]
    counts: dict[str, int] = {}
    for vote in matching:
        counts[vote["reason"]] = counts.get(vote["reason"], 0) + 1
    return min(counts, key=lambda reason: (-counts[reason], reason))


def reconcile_agent_votes(
    *,
    queue: Sequence[dict[str, Any]],
    vote_specs: Sequence[tuple[str, Path]],
    draft_path: Path,
    disagreement_dir: Path,
) -> dict[str, Any]:
    """Merge two blind votes, or a third adjudication vote, fail-closed."""
    annotators = sorted({annotator for annotator, _ in vote_specs})
    if len(annotators) not in {3, 4}:
        raise CohortLabelerError(
            "agent reconciliation requires three annotators and an optional tiebreaker"
        )
    votes_by_pair = load_agent_votes(vote_specs, queue)
    annotations: list[dict[str, Any]] = []
    disagreements: dict[str, list[dict[str, Any]]] = {
        annotator: [] for annotator in annotators
    }
    unresolved = 0
    label_agreements = 0
    adjudicated = 0
    tiebroken = 0
    annotated_at = datetime.now(timezone.utc).isoformat()

    for row in queue:
        pair_id = row["pair_id"]
        votes = sorted(
            votes_by_pair[pair_id],
            key=lambda vote: vote["annotator"],
        )
        if len(votes) not in {2, 3, 4}:
            raise CohortLabelerError(
                f"{pair_id}: expected two to four independent votes, got {len(votes)}"
            )
        label = consensus_label(votes)
        if label is None:
            if len(votes) == 2:
                missing = sorted(
                    set(annotators) - {vote["annotator"] for vote in votes}
                )
                if len(missing) != 1:
                    raise CohortLabelerError(
                        f"{pair_id}: cannot determine missing adjudicator"
                    )
                disagreements[missing[0]].append({
                    "pair_id": pair_id,
                    "earlier": {
                        "text": row["left"]["text"],
                        "timestamp": row["left"]["timestamp"],
                    },
                    "later": {
                        "text": row["right"]["text"],
                        "timestamp": row["right"]["timestamp"],
                    },
                })
            elif len(votes) >= 3:
                unresolved += 1
            continue

        if len(votes) == 2:
            label_agreements += 1
            agreement = "independent_label_agreement"
        elif len(votes) == 3:
            adjudicated += 1
            agreement = "majority_after_blind_adjudication"
        else:
            tiebroken += 1
            agreement = "majority_after_fresh_blind_tiebreak"
        annotations.append({
            "pair_id": pair_id,
            "label": label,
            "reason": consensus_reason(label, votes),
            "note": "",
            "annotated_at": annotated_at,
            "annotation_method": "gpt-5.6-sol-double-blind-v1",
            "agreement": agreement,
            "annotators": [vote["annotator"] for vote in votes],
            "votes": votes,
        })

    prepare.write_jsonl_atomic(draft_path, annotations)
    disagreement_dir.mkdir(parents=True, exist_ok=True)
    disagreement_counts = {}
    for annotator, rows in disagreements.items():
        path = disagreement_dir / f"{annotator}.jsonl"
        prepare.write_jsonl_atomic(path, rows)
        disagreement_counts[annotator] = len(rows)
    result = {
        "queue": len(queue),
        "consensus": len(annotations),
        "label_agreements": label_agreements,
        "adjudicated": adjudicated,
        "tiebroken": tiebroken,
        "pending_adjudication": sum(disagreement_counts.values()),
        "unresolved_after_three_votes": unresolved,
        "disagreements_by_annotator": disagreement_counts,
        "draft": str(draft_path),
    }
    prepare.write_json_atomic(disagreement_dir / "manifest.json", result)
    return result


def blind_state(
    queue: Sequence[dict[str, Any]],
    annotations: dict[str, dict[str, Any]],
    index: int,
) -> dict[str, Any]:
    if not 0 <= index < len(queue):
        raise CohortLabelerError(f"queue index is out of range: {index}")
    row = queue[index]
    annotation = annotations.get(row["pair_id"])
    return {
        "index": index,
        "total": len(queue),
        "annotated": len(annotations),
        "remaining": len(queue) - len(annotations),
        "pair_id": row["pair_id"],
        "left": {
            "text": row["left"]["text"],
            "timestamp": row["left"]["timestamp"],
        },
        "right": {
            "text": row["right"]["text"],
            "timestamp": row["right"]["timestamp"],
        },
        "annotation": (
            None
            if annotation is None
            else {
                "label": annotation["label"],
                "reason": annotation["reason"],
                "note": annotation.get("note", ""),
            }
        ),
    }


def next_unannotated_index(
    queue: Sequence[dict[str, Any]],
    annotations: dict[str, dict[str, Any]],
    after_index: int,
) -> int:
    for offset in range(1, len(queue) + 1):
        index = (after_index + offset) % len(queue)
        if queue[index]["pair_id"] not in annotations:
            return index
    return min(after_index + 1, len(queue) - 1)


def prepare_queue(
    *,
    pair_scores_path: Path,
    partner_sweep_path: Path,
    output_dir: Path,
) -> dict[str, Any]:
    queue_path = output_dir / DEFAULT_QUEUE_PATH.name
    manifest_path = output_dir / DEFAULT_QUEUE_MANIFEST_PATH.name
    pair_scores_sha = dense.sha256_file(pair_scores_path)
    partner_sweep_sha = dense.sha256_file(partner_sweep_path)
    if queue_path.exists() or manifest_path.exists():
        if not queue_path.is_file() or not manifest_path.is_file():
            raise CohortLabelerError("labeling queue is partially initialized")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        expected = {
            "pair_scores_sha256": pair_scores_sha,
            "partner_sweep_sha256": partner_sweep_sha,
        }
        if manifest.get("inputs") != expected:
            raise CohortLabelerError(
                "existing queue was built from different source artifacts"
            )
        queue = prepare.read_jsonl(queue_path)
        validate_queue(queue)
        return manifest

    pair_rows = prepare.read_jsonl(pair_scores_path)
    partner_sweep = json.loads(partner_sweep_path.read_text(encoding="utf-8"))
    queue = build_queue(pair_rows, partner_sweep)
    output_dir.mkdir(parents=True)
    prepare.write_jsonl_atomic(queue_path, queue)
    manifest = {
        "labeler_version": LABELER_VERSION,
        "queue_seed": QUEUE_SEED,
        "queue_count": len(queue),
        "queue_sha256": dense.sha256_file(queue_path),
        "inputs": {
            "pair_scores_sha256": pair_scores_sha,
            "partner_sweep_sha256": partner_sweep_sha,
        },
        "blind_fields": [
            "case_id",
            "cosine",
            "overlap_count",
            "source_groups",
            "selected_by",
        ],
        "labels": {
            label: sorted(reasons)
            for label, reasons in LABEL_REASONS.items()
        },
    }
    prepare.write_json_atomic(manifest_path, manifest)
    return manifest


def export_annotations(
    *,
    queue_path: Path,
    draft_path: Path,
    output_path: Path,
) -> dict[str, Any]:
    queue = prepare.read_jsonl(queue_path)
    validate_queue(queue)
    annotations = load_annotations(draft_path, queue)
    if len(annotations) != len(queue):
        raise CohortLabelerError(
            f"annotation export requires completion: "
            f"{len(annotations)}/{len(queue)} labeled"
        )
    if output_path.exists():
        raise CohortLabelerError(f"export already exists: {output_path}")
    exported = []
    for row in queue:
        annotation = annotations[row["pair_id"]]
        exported_row = {
            "schema_version": "cohort-pair-annotation-v1",
            "pair_id": row["pair_id"],
            "case_id": row["case_id"],
            "left_turn_id": row["left"]["turn_id"],
            "right_turn_id": row["right"]["turn_id"],
            "left_text_sha256": row["left"]["text_sha256"],
            "right_text_sha256": row["right"]["text_sha256"],
            "label": annotation["label"],
            "reason": annotation["reason"],
            "note": annotation.get("note", ""),
        }
        for field in (
            "annotation_method",
            "agreement",
            "annotators",
            "votes",
        ):
            if field in annotation:
                exported_row[field] = annotation[field]
        exported.append(exported_row)
    prepare.write_jsonl_atomic(output_path, exported)
    return {
        "status": "complete",
        "annotations": len(exported),
        "output": str(output_path),
        "sha256": dense.sha256_file(output_path),
    }


class LabelerApplication:
    def __init__(self, queue_path: Path, draft_path: Path) -> None:
        self.queue_path = queue_path
        self.draft_path = draft_path
        self.queue = prepare.read_jsonl(queue_path)
        validate_queue(self.queue)
        self.annotations = load_annotations(draft_path, self.queue)
        self.lock = threading.Lock()

    def state(self, index: int) -> dict[str, Any]:
        with self.lock:
            return blind_state(self.queue, self.annotations, index)

    def save(self, payload: dict[str, Any], index: int) -> dict[str, Any]:
        with self.lock:
            annotation = save_annotation(
                self.draft_path,
                self.queue,
                self.annotations,
                payload,
            )
            return {
                "annotation": annotation,
                "next_index": next_unannotated_index(
                    self.queue,
                    self.annotations,
                    index,
                ),
                "annotated": len(self.annotations),
                "total": len(self.queue),
            }


def handler_factory(application: LabelerApplication) -> type[BaseHTTPRequestHandler]:
    class LabelerHandler(BaseHTTPRequestHandler):
        server_version = "PetAICohortLabeler/0.1"

        def send_json(self, value: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
            body = prepare.canonical_json(value).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            try:
                if parsed.path == "/":
                    body = HTML_PATH.read_bytes()
                    self.send_response(HTTPStatus.OK)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if parsed.path == "/api/state":
                    values = parse_qs(parsed.query)
                    index = int(values.get("index", ["0"])[0])
                    self.send_json(application.state(index))
                    return
                self.send_json(
                    {"error": "not found"},
                    HTTPStatus.NOT_FOUND,
                )
            except (CohortLabelerError, OSError, ValueError) as error:
                self.send_json(
                    {"error": str(error)},
                    HTTPStatus.BAD_REQUEST,
                )

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path != "/api/annotation":
                self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > 64 * 1024:
                    raise CohortLabelerError("invalid request body length")
                payload = json.loads(self.rfile.read(length))
                index = payload.pop("index")
                if not isinstance(index, int):
                    raise CohortLabelerError("annotation index must be an integer")
                self.send_json(application.save(payload, index))
            except (
                CohortLabelerError,
                json.JSONDecodeError,
                KeyError,
                OSError,
                TypeError,
                ValueError,
            ) as error:
                self.send_json(
                    {"error": str(error)},
                    HTTPStatus.BAD_REQUEST,
                )

        def log_message(self, format: str, *args: Any) -> None:
            print(f"labeler: {format % args}", file=sys.stderr)

    return LabelerHandler


def serve(
    *,
    queue_path: Path,
    draft_path: Path,
    host: str,
    port: int,
    open_browser: bool,
) -> None:
    if host not in {"127.0.0.1", "localhost"}:
        raise CohortLabelerError("labeler must bind to localhost")
    if not HTML_PATH.is_file():
        raise CohortLabelerError(f"labeler HTML is missing: {HTML_PATH}")
    application = LabelerApplication(queue_path, draft_path)
    server = ThreadingHTTPServer((host, port), handler_factory(application))
    url = f"http://{host}:{server.server_port}/"
    print(f"Cohort labeler: {url}")
    print(
        f"Progress: {len(application.annotations)}/{len(application.queue)}"
    )
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument(
        "--pair-scores",
        type=Path,
        default=DEFAULT_PAIR_SCORES_PATH,
    )
    prepare_parser.add_argument(
        "--partner-sweep",
        type=Path,
        default=DEFAULT_PARTNER_SWEEP_PATH,
    )
    prepare_parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_LABELING_DIR,
    )

    serve_parser = commands.add_parser("serve")
    serve_parser.add_argument(
        "--queue",
        type=Path,
        default=DEFAULT_QUEUE_PATH,
    )
    serve_parser.add_argument(
        "--draft",
        type=Path,
        default=DEFAULT_DRAFT_PATH,
    )
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument("--open", action="store_true")

    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument(
        "--queue",
        type=Path,
        default=DEFAULT_QUEUE_PATH,
    )
    validate_parser.add_argument(
        "--draft",
        type=Path,
        default=DEFAULT_DRAFT_PATH,
    )

    export_parser = commands.add_parser("export")
    export_parser.add_argument(
        "--queue",
        type=Path,
        default=DEFAULT_QUEUE_PATH,
    )
    export_parser.add_argument(
        "--draft",
        type=Path,
        default=DEFAULT_DRAFT_PATH,
    )
    export_parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_EXPORT_PATH,
    )

    reconcile_parser = commands.add_parser("reconcile-agent-votes")
    reconcile_parser.add_argument(
        "--queue",
        type=Path,
        default=DEFAULT_QUEUE_PATH,
    )
    reconcile_parser.add_argument(
        "--vote",
        action="append",
        required=True,
        metavar="ANNOTATOR=PATH",
    )
    reconcile_parser.add_argument(
        "--draft",
        type=Path,
        default=DEFAULT_AGENT_DRAFT_PATH,
    )
    reconcile_parser.add_argument(
        "--disagreement-dir",
        type=Path,
        default=DEFAULT_AGENT_DISAGREEMENT_DIR,
    )
    return parser


def parse_vote_specs(values: Sequence[str]) -> list[tuple[str, Path]]:
    specs = []
    for value in values:
        annotator, separator, path = value.partition("=")
        if not separator or not annotator or not path:
            raise CohortLabelerError(
                f"invalid --vote value {value!r}; expected ANNOTATOR=PATH"
            )
        specs.append((annotator, Path(path)))
    return specs


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "prepare":
            result = prepare_queue(
                pair_scores_path=arguments.pair_scores,
                partner_sweep_path=arguments.partner_sweep,
                output_dir=arguments.output_dir,
            )
            print(prepare.canonical_json(result))
        elif arguments.command == "serve":
            serve(
                queue_path=arguments.queue,
                draft_path=arguments.draft,
                host=arguments.host,
                port=arguments.port,
                open_browser=arguments.open,
            )
        elif arguments.command == "validate":
            queue = prepare.read_jsonl(arguments.queue)
            validate_queue(queue)
            annotations = load_annotations(arguments.draft, queue)
            print(prepare.canonical_json({
                "status": "valid",
                "queue": len(queue),
                "annotated": len(annotations),
                "remaining": len(queue) - len(annotations),
            }))
        elif arguments.command == "export":
            print(prepare.canonical_json(export_annotations(
                queue_path=arguments.queue,
                draft_path=arguments.draft,
                output_path=arguments.output,
            )))
        elif arguments.command == "reconcile-agent-votes":
            queue = prepare.read_jsonl(arguments.queue)
            validate_queue(queue)
            print(prepare.canonical_json(reconcile_agent_votes(
                queue=queue,
                vote_specs=parse_vote_specs(arguments.vote),
                draft_path=arguments.draft,
                disagreement_dir=arguments.disagreement_dir,
            )))
    except (
        CohortLabelerError,
        cohort.CohortSimilarityError,
        dense.RetrievalRunnerError,
        OSError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
