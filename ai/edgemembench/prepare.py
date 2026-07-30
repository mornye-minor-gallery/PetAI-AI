#!/usr/bin/env python3
"""Build and validate the deterministic EdgeMemBench v0 data artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Iterator


ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "benchmark_manifest.json"
DEFAULT_STORAGE_PATH = ROOT / "data" / "storage_decision.jsonl"
DEFAULT_KNOWLEDGE_UPDATE_ANNOTATIONS_PATH = (
    ROOT / "data" / "knowledge_update_annotations.jsonl"
)
DEFAULT_ARTIFACT_DIR = ROOT / ".artifacts" / "v0"
DEFAULT_CACHE_PATH = ROOT / ".artifacts" / "cache" / "longmemeval_s_cleaned.json"

OUTPUT_FILES = {
    "A": "storage_decision.jsonl",
    "B": "single_memory_retrieval.jsonl",
    "C": "knowledge_update.jsonl",
    "D": "abstention.jsonl",
}

TASKS = {
    "A": "storage_decision",
    "B": "single_memory_retrieval",
    "C": "knowledge_update",
    "D": "abstention",
}

TIMESTAMP_PATTERN = re.compile(
    r"^(?P<year>\d{4})/(?P<month>\d{2})/(?P<day>\d{2}) "
    r"\([A-Za-z]{3}\) (?P<hour>\d{2}):(?P<minute>\d{2})$"
)


class BenchmarkError(RuntimeError):
    """Raised when a source or generated artifact violates the benchmark contract."""


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise BenchmarkError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(value, dict):
                raise BenchmarkError(f"{path}:{line_number}: expected a JSON object")
            records.append(value)
    return records


def write_jsonl_atomic(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        for record in records:
            handle.write(canonical_json(record))
            handle.write("\n")
    os.replace(temporary_path, path)


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2))
        handle.write("\n")
    os.replace(temporary_path, path)


def load_manifest() -> dict[str, Any]:
    with MANIFEST_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def verify_file(path: Path, expected_sha256: str, label: str) -> None:
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise BenchmarkError(
            f"{label} SHA-256 mismatch: expected {expected_sha256}, got {actual}"
        )


def storage_label(preference: bool, event: bool) -> str:
    return {
        (False, False): "N",
        (True, False): "P",
        (False, True): "E",
        (True, True): "B",
    }[(preference, event)]


def normalize_storage_record(record: dict[str, Any]) -> dict[str, Any]:
    required = ("id", "utterance", "split", "preference", "event")
    missing = [key for key in required if key not in record]
    if missing:
        raise BenchmarkError(f"storage record is missing fields: {missing}")
    preference = record["preference"]
    event = record["event"]
    if not isinstance(preference, bool) or not isinstance(event, bool):
        raise BenchmarkError(f"{record['id']}: preference/event must be booleans")
    utterance = record["utterance"]
    if not isinstance(utterance, str) or not utterance.strip():
        raise BenchmarkError(f"{record['id']}: utterance must be non-empty")

    metadata_keys = (
        "split",
        "challenge_type",
        "expression_pattern",
        "surface_style",
        "topic_hint",
        "family_id",
    )
    return {
        "case_id": f"edgemem-a-{record['id']}",
        "axis": "A",
        "task": "storage_decision",
        "utterance": utterance,
        "expected": {
            "preference": preference,
            "event": event,
            "store": preference or event,
            "label": storage_label(preference, event),
        },
        "metadata": {
            key: record[key] for key in metadata_keys if key in record
        },
        "source": {
            "dataset": "PetAI memory-classifier balanced",
            "record_id": record["id"],
        },
    }


def import_storage(test_path: Path, challenge_path: Path, output_path: Path) -> None:
    manifest = load_manifest()
    source_specs = (
        ("storage_test", test_path),
        ("storage_synthetic_challenge", challenge_path),
    )
    normalized: list[dict[str, Any]] = []
    for source_key, source_path in source_specs:
        spec = manifest["sources"][source_key]
        verify_file(source_path, spec["sha256"], spec["name"])
        records = read_jsonl(source_path)
        if len(records) != spec["expected_cases"]:
            raise BenchmarkError(
                f"{spec['name']} count mismatch: expected "
                f"{spec['expected_cases']}, got {len(records)}"
            )
        normalized.extend(normalize_storage_record(record) for record in records)

    if len({record["case_id"] for record in normalized}) != len(normalized):
        raise BenchmarkError("storage source contains duplicate IDs")
    write_jsonl_atomic(output_path, normalized)
    validate_storage_records(normalized, expected_count=300)
    normalized_spec = manifest["sources"]["storage_decision_normalized"]
    verify_file(output_path, normalized_spec["sha256"], normalized_spec["name"])


def parse_timestamp(value: Any) -> tuple[int, int, int, int, int]:
    if not isinstance(value, str):
        raise BenchmarkError("timestamp must be a string")
    match = TIMESTAMP_PATTERN.fullmatch(value)
    if match is None:
        raise BenchmarkError(f"invalid timestamp: {value!r}")
    parts = tuple(int(match.group(name)) for name in (
        "year",
        "month",
        "day",
        "hour",
        "minute",
    ))
    year, month, day, hour, minute = parts
    try:
        datetime(year, month, day, hour, minute)
    except ValueError as exc:
        raise BenchmarkError(f"invalid timestamp: {value!r}") from exc
    return year, month, day, hour, minute


def normalized_session_id(source_session_id: str, source_index: int) -> str:
    return f"{source_session_id}::session-{source_index:04d}"


def turn_id(session_id: str, turn_index: int) -> str:
    return f"{session_id}::turn-{turn_index:04d}"


def iter_source_turns(
    record: dict[str, Any],
) -> Iterator[tuple[str, str, int, dict[str, Any]]]:
    session_ids = record.get("haystack_session_ids", [])
    sessions = record.get("haystack_sessions", [])
    if len(session_ids) != len(sessions):
        raise BenchmarkError(
            f"{record.get('question_id')}: session ID/session count mismatch"
        )
    for session_id, session in zip(session_ids, sessions, strict=True):
        for index, turn in enumerate(session):
            yield str(session_id), turn_id(str(session_id), index), index, turn


def evidence_roles(record: dict[str, Any]) -> set[str]:
    return {
        str(turn.get("role"))
        for _, _, _, turn in iter_source_turns(record)
        if turn.get("has_answer") is True
    }


def normalize_longmemeval_record(
    record: dict[str, Any],
    axis: str,
    task: str,
) -> dict[str, Any]:
    question_id = str(record["question_id"])
    query = record.get("question")
    if not isinstance(query, str) or not query.strip():
        raise BenchmarkError(f"{question_id}: question must be a non-empty string")
    answer = record.get("answer")
    if isinstance(answer, bool) or not isinstance(answer, (str, int, float)):
        raise BenchmarkError(f"{question_id}: answer must be a string or number")

    dates = record.get("haystack_dates", [])
    session_ids = record.get("haystack_session_ids", [])
    sessions = record.get("haystack_sessions", [])
    if not (len(dates) == len(session_ids) == len(sessions)):
        raise BenchmarkError(f"{question_id}: session metadata lengths differ")

    raw_answer_session_ids = record.get("answer_session_ids", [])
    if not isinstance(raw_answer_session_ids, list) or any(
        not isinstance(value, (str, int)) for value in raw_answer_session_ids
    ):
        raise BenchmarkError(f"{question_id}: invalid answer_session_ids")
    raw_answer_session_ids = {str(value) for value in raw_answer_session_ids}

    source_sessions: list[dict[str, Any]] = []
    for source_index, (session_id, date, session) in enumerate(
        zip(session_ids, dates, sessions, strict=True)
    ):
        if not isinstance(session, list):
            raise BenchmarkError(f"{question_id}: session must be a list")
        source_session_id = str(session_id)
        source_sessions.append(
            {
                "source_index": source_index,
                "source_session_id": source_session_id,
                "session_id": normalized_session_id(
                    source_session_id, source_index
                ),
                "timestamp": str(date),
                "timestamp_key": parse_timestamp(date),
                "turns": session,
            }
        )
    source_sessions.sort(
        key=lambda session: (session["timestamp_key"], session["source_index"])
    )

    normalized_sessions: list[dict[str, Any]] = []
    gold_evidence_turn_ids: list[str] = []
    partial_evidence_turn_ids: list[str] = []
    answer_session_ids: list[str] = []
    matched_answer_source_ids: set[str] = set()
    is_abstention = axis == "D"
    for source_session in source_sessions:
        session_id = source_session["session_id"]
        source_session_id = source_session["source_session_id"]
        if source_session_id in raw_answer_session_ids:
            answer_session_ids.append(session_id)
            matched_answer_source_ids.add(source_session_id)
        user_turns: list[dict[str, Any]] = []
        for source_index, turn in enumerate(source_session["turns"]):
            if not isinstance(turn, dict):
                raise BenchmarkError(f"{question_id}: turn must be an object")
            source_turn_id = turn_id(session_id, source_index)
            if turn.get("has_answer") is True:
                if turn.get("role") != "user":
                    raise BenchmarkError(
                        f"{question_id}: non-user evidence entered user-only slice"
                    )
                if is_abstention:
                    partial_evidence_turn_ids.append(source_turn_id)
                else:
                    gold_evidence_turn_ids.append(source_turn_id)
            if turn.get("role") != "user":
                continue
            content = turn.get("content")
            if not isinstance(content, str) or not content.strip():
                if turn.get("has_answer") is True:
                    raise BenchmarkError(f"{question_id}: empty evidence turn")
                continue
            user_turns.append(
                {
                    "turn_id": source_turn_id,
                    "role": "user",
                    "content": content,
                }
            )
        normalized_sessions.append(
            {
                "session_id": session_id,
                "source_session_id": source_session_id,
                "timestamp": source_session["timestamp"],
                "turns": user_turns,
            }
        )

    if matched_answer_source_ids != raw_answer_session_ids:
        raise BenchmarkError(
            f"{question_id}: answer_session_ids reference missing history sessions"
        )
    if not is_abstention and not gold_evidence_turn_ids:
        raise BenchmarkError(f"{question_id}: answerable case has no gold evidence")

    expected: dict[str, Any] = {
        "answer": str(answer),
        "expected_abstention": is_abstention,
        "gold_evidence_turn_ids": gold_evidence_turn_ids,
        "partial_evidence_turn_ids": partial_evidence_turn_ids,
        "answer_session_ids": answer_session_ids,
    }
    if axis == "D":
        expected["subtype"] = (
            "partial_evidence"
            if partial_evidence_turn_ids
            else "absent_evidence"
        )

    return {
        "case_id": f"edgemem-{axis.lower()}-{question_id}",
        "axis": axis,
        "task": task,
        "query": query,
        "history": normalized_sessions,
        "expected": expected,
        "source": {
            "dataset": "LongMemEval-S cleaned",
            "question_id": question_id,
            "question_type": record["question_type"],
        },
    }


def apply_knowledge_update_annotations(
    records: list[dict[str, Any]],
    annotation_path: Path,
) -> None:
    manifest = load_manifest()
    annotation_spec = manifest["sources"]["knowledge_update_annotations"]
    verify_file(
        annotation_path,
        annotation_spec["sha256"],
        annotation_spec["name"],
    )
    annotations = read_jsonl(annotation_path)
    if len(annotations) != annotation_spec["expected_cases"]:
        raise BenchmarkError(
            "knowledge-update annotation count mismatch: expected "
            f"{annotation_spec['expected_cases']}, got {len(annotations)}"
        )

    annotations_by_case: dict[str, dict[str, Any]] = {}
    for annotation in annotations:
        case_id = annotation.get("case_id")
        if not isinstance(case_id, str) or not case_id:
            raise BenchmarkError("knowledge-update annotation has invalid case_id")
        if case_id in annotations_by_case:
            raise BenchmarkError(
                f"duplicate knowledge-update annotation: {case_id}"
            )
        annotations_by_case[case_id] = annotation

    record_ids = {record["case_id"] for record in records}
    annotation_ids = set(annotations_by_case)
    if annotation_ids != record_ids:
        missing = sorted(record_ids - annotation_ids)
        extra = sorted(annotation_ids - record_ids)
        raise BenchmarkError(
            "knowledge-update annotation case IDs differ from selected cases: "
            f"missing={missing}, extra={extra}"
        )

    allowed_subtypes = {
        "current_state",
        "historical_state",
        "multi_state",
        "single_state",
    }
    for record in records:
        case_id = record["case_id"]
        annotation = annotations_by_case[case_id]
        status = annotation.get("evaluation_status")
        subtype = annotation.get("temporal_subtype")
        exclusion_reason = annotation.get("exclusion_reason")
        rationale = annotation.get("rationale")
        if status not in {"scored", "excluded"}:
            raise BenchmarkError(f"{case_id}: invalid evaluation_status")
        if subtype not in allowed_subtypes:
            raise BenchmarkError(f"{case_id}: invalid temporal_subtype")
        if status == "scored" and exclusion_reason is not None:
            raise BenchmarkError(
                f"{case_id}: scored case must not have an exclusion reason"
            )
        if status == "excluded" and (
            not isinstance(exclusion_reason, str) or not exclusion_reason
        ):
            raise BenchmarkError(
                f"{case_id}: excluded case requires an exclusion reason"
            )
        if not isinstance(rationale, str) or not rationale.strip():
            raise BenchmarkError(f"{case_id}: annotation rationale is required")

        gold = record["expected"]["gold_evidence_turn_ids"]

        def resolve_ordinals(field: str) -> list[str]:
            values = annotation.get(field)
            if not isinstance(values, list) or any(
                isinstance(value, bool) or not isinstance(value, int)
                for value in values
            ):
                raise BenchmarkError(f"{case_id}: invalid {field}")
            if len(values) != len(set(values)):
                raise BenchmarkError(f"{case_id}: duplicate values in {field}")
            if any(value < 1 or value > len(gold) for value in values):
                raise BenchmarkError(f"{case_id}: {field} is out of range")
            return [gold[value - 1] for value in values]

        target = resolve_ordinals("target_evidence_ordinals")
        competing = resolve_ordinals("competing_evidence_ordinals")
        context = resolve_ordinals("context_evidence_ordinals")
        if not target:
            raise BenchmarkError(f"{case_id}: target evidence must not be empty")
        partition = [*target, *competing, *context]
        if len(partition) != len(set(partition)) or set(partition) != set(gold):
            raise BenchmarkError(
                f"{case_id}: curated evidence roles must partition source gold"
            )

        record["expected"].update(
            {
                "evaluation_status": status,
                "temporal_subtype": subtype,
                "target_evidence_turn_ids": target,
                "competing_evidence_turn_ids": competing,
                "context_evidence_turn_ids": context,
                "exclusion_reason": exclusion_reason,
                "annotation_rationale": rationale,
            }
        )


def select_longmemeval_cases(
    source_records: Iterable[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    selected: dict[str, list[dict[str, Any]]] = {"B": [], "C": [], "D": []}
    for record in source_records:
        question_id = str(record.get("question_id", ""))
        question_type = record.get("question_type")
        abstention = question_id.endswith("_abs")
        roles = evidence_roles(record)

        if abstention:
            selected["D"].append(
                normalize_longmemeval_record(record, "D", "abstention")
            )
        elif (
            question_type
            in {"single-session-preference", "single-session-user"}
            and roles == {"user"}
        ):
            selected["B"].append(
                normalize_longmemeval_record(
                    record, "B", "single_memory_retrieval"
                )
            )
        elif question_type == "knowledge-update" and roles == {"user"}:
            selected["C"].append(
                normalize_longmemeval_record(record, "C", "knowledge_update")
            )
    return selected


def validate_storage_records(
    records: list[dict[str, Any]], expected_count: int
) -> None:
    if len(records) != expected_count:
        raise BenchmarkError(
            f"axis A count mismatch: expected {expected_count}, got {len(records)}"
        )
    for record in records:
        if record.get("axis") != "A" or record.get("task") != "storage_decision":
            raise BenchmarkError(f"{record.get('case_id')}: invalid axis A metadata")
        expected = record.get("expected", {})
        preference = expected.get("preference")
        event = expected.get("event")
        if not isinstance(preference, bool) or not isinstance(event, bool):
            raise BenchmarkError(f"{record.get('case_id')}: invalid P/E booleans")
        if expected.get("label") != storage_label(preference, event):
            raise BenchmarkError(f"{record.get('case_id')}: invalid storage label")
        if expected.get("store") is not (preference or event):
            raise BenchmarkError(f"{record.get('case_id')}: invalid store decision")


def validate_memory_records(
    axis: str,
    records: list[dict[str, Any]],
    expected_count: int,
) -> None:
    if len(records) != expected_count:
        raise BenchmarkError(
            f"axis {axis} count mismatch: expected {expected_count}, got {len(records)}"
        )
    for record in records:
        case_id = record.get("case_id")
        if not isinstance(case_id, str) or not case_id:
            raise BenchmarkError("memory record has an invalid case_id")
        if record.get("axis") != axis or record.get("task") != TASKS[axis]:
            raise BenchmarkError(f"{case_id}: invalid axis/task metadata")
        query = record.get("query")
        if not isinstance(query, str) or not query.strip():
            raise BenchmarkError(f"{case_id}: query must be a non-empty string")

        history = record.get("history")
        if not isinstance(history, list) or not history:
            raise BenchmarkError(f"{case_id}: history must be a non-empty list")
        observed_turn_ids: set[str] = set()
        observed_session_ids: set[str] = set()
        timestamps: list[tuple[int, int, int, int, int]] = []
        for session in history:
            if not isinstance(session, dict):
                raise BenchmarkError(f"{case_id}: session must be an object")
            session_id = session.get("session_id")
            source_session_id = session.get("source_session_id")
            if not isinstance(session_id, str) or not session_id:
                raise BenchmarkError(f"{case_id}: invalid session_id")
            if session_id in observed_session_ids:
                raise BenchmarkError(f"{case_id}: duplicate session_id {session_id}")
            observed_session_ids.add(session_id)
            if not isinstance(source_session_id, str) or not source_session_id:
                raise BenchmarkError(f"{case_id}: invalid source_session_id")
            timestamps.append(parse_timestamp(session.get("timestamp")))
            turns = session.get("turns")
            if not isinstance(turns, list):
                raise BenchmarkError(f"{case_id}: turns must be a list")
            for turn in turns:
                if not isinstance(turn, dict):
                    raise BenchmarkError(f"{case_id}: turn must be an object")
                if turn.get("role") != "user":
                    raise BenchmarkError(f"{case_id}: assistant turn leaked into history")
                turn_id_value = turn.get("turn_id")
                content = turn.get("content")
                if not isinstance(turn_id_value, str) or not turn_id_value:
                    raise BenchmarkError(f"{case_id}: invalid turn_id")
                if turn_id_value in observed_turn_ids:
                    raise BenchmarkError(
                        f"{case_id}: duplicate turn_id {turn_id_value}"
                    )
                observed_turn_ids.add(turn_id_value)
                if not isinstance(content, str) or not content.strip():
                    raise BenchmarkError(f"{case_id}: empty user content")
        if timestamps != sorted(timestamps):
            raise BenchmarkError(f"{case_id}: history is not timestamp sorted")

        expected = record.get("expected")
        if not isinstance(expected, dict):
            raise BenchmarkError(f"{case_id}: expected must be an object")
        answer = expected.get("answer")
        if not isinstance(answer, str) or not answer.strip():
            raise BenchmarkError(f"{case_id}: answer must be a non-empty string")
        if not isinstance(expected.get("expected_abstention"), bool):
            raise BenchmarkError(f"{case_id}: expected_abstention must be boolean")

        def id_list(field: str) -> list[str]:
            value = expected.get(field)
            if not isinstance(value, list) or any(
                not isinstance(item, str) or not item for item in value
            ):
                raise BenchmarkError(f"{case_id}: invalid {field}")
            if len(value) != len(set(value)):
                raise BenchmarkError(f"{case_id}: duplicate IDs in {field}")
            return value

        gold_values = id_list("gold_evidence_turn_ids")
        partial_values = id_list("partial_evidence_turn_ids")
        answer_session_values = id_list("answer_session_ids")
        if not set(answer_session_values).issubset(observed_session_ids):
            raise BenchmarkError(
                f"{case_id}: answer_session_ids are missing from history"
            )
        gold = set(gold_values)
        partial = set(partial_values)
        if axis == "D":
            if expected.get("expected_abstention") is not True or gold:
                raise BenchmarkError(f"{case_id}: invalid abstention contract")
            if not partial.issubset(observed_turn_ids):
                raise BenchmarkError(
                    f"{case_id}: partial abstention evidence is missing from history"
                )
            expected_subtype = (
                "partial_evidence" if partial else "absent_evidence"
            )
            if expected.get("subtype") != expected_subtype:
                raise BenchmarkError(f"{case_id}: invalid abstention subtype")
        else:
            if expected.get("expected_abstention") is not False or not gold:
                raise BenchmarkError(f"{case_id}: invalid answerable contract")
            if not gold.issubset(observed_turn_ids):
                raise BenchmarkError(f"{case_id}: gold evidence is missing from history")
            if partial:
                raise BenchmarkError(f"{case_id}: unexpected partial evidence")
            if axis == "C":
                status = expected.get("evaluation_status")
                subtype = expected.get("temporal_subtype")
                target = set(id_list("target_evidence_turn_ids"))
                competing = set(id_list("competing_evidence_turn_ids"))
                context = set(id_list("context_evidence_turn_ids"))
                if status not in {"scored", "excluded"}:
                    raise BenchmarkError(f"{case_id}: invalid C evaluation status")
                if subtype not in {
                    "current_state",
                    "historical_state",
                    "multi_state",
                    "single_state",
                }:
                    raise BenchmarkError(f"{case_id}: invalid C temporal subtype")
                if not target:
                    raise BenchmarkError(f"{case_id}: missing C target evidence")
                if target & competing or target & context or competing & context:
                    raise BenchmarkError(f"{case_id}: overlapping C evidence roles")
                if target | competing | context != gold:
                    raise BenchmarkError(
                        f"{case_id}: C evidence roles do not partition source gold"
                    )
                exclusion_reason = expected.get("exclusion_reason")
                if status == "scored" and exclusion_reason is not None:
                    raise BenchmarkError(
                        f"{case_id}: scored C case has exclusion reason"
                    )
                if status == "excluded" and (
                    not isinstance(exclusion_reason, str)
                    or not exclusion_reason
                ):
                    raise BenchmarkError(
                        f"{case_id}: excluded C case lacks exclusion reason"
                    )
                rationale = expected.get("annotation_rationale")
                if not isinstance(rationale, str) or not rationale.strip():
                    raise BenchmarkError(
                        f"{case_id}: C annotation rationale is required"
                    )


def validate_unique_case_ids(records_by_axis: dict[str, list[dict[str, Any]]]) -> None:
    seen: set[str] = set()
    for records in records_by_axis.values():
        for record in records:
            case_id = str(record.get("case_id"))
            if case_id in seen:
                raise BenchmarkError(f"duplicate case ID: {case_id}")
            seen.add(case_id)


def artifact_manifest(
    output_dir: Path,
    source_path: Path,
    storage_path: Path,
    annotation_path: Path,
    records_by_axis: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    benchmark_manifest = load_manifest()
    files: dict[str, Any] = {}
    for axis, filename in OUTPUT_FILES.items():
        path = output_dir / filename
        files[filename] = {
            "axis": axis,
            "cases": len(records_by_axis[axis]),
            "sha256": sha256_file(path),
        }
    return {
        "benchmark": benchmark_manifest["name"],
        "version": benchmark_manifest["version"],
        "profile": benchmark_manifest["profile"],
        "generator": "prepare.py",
        "sources": {
            "longmemeval_s_cleaned": {
                "sha256": sha256_file(source_path),
            },
            "storage_decision": {
                "sha256": sha256_file(storage_path),
            },
            "knowledge_update_annotations": {
                "sha256": sha256_file(annotation_path),
            },
        },
        "files": files,
        "total_cases": sum(len(records) for records in records_by_axis.values()),
    }


def expected_counts() -> dict[str, int]:
    manifest = load_manifest()
    return {
        axis: int(spec["expected_cases"])
        for axis, spec in manifest["axes"].items()
    }


def obtain_longmemeval_source(source_path: Path | None) -> Path:
    manifest = load_manifest()
    spec = manifest["sources"]["longmemeval_s_cleaned"]
    if source_path is not None:
        verify_file(source_path, spec["sha256"], spec["name"])
        return source_path

    if not DEFAULT_CACHE_PATH.exists():
        DEFAULT_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "wb",
            dir=DEFAULT_CACHE_PATH.parent,
            prefix=".longmemeval.",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            with urllib.request.urlopen(spec["url"]) as response:
                shutil.copyfileobj(response, handle)
        try:
            verify_file(temporary_path, spec["sha256"], spec["name"])
            os.replace(temporary_path, DEFAULT_CACHE_PATH)
        finally:
            temporary_path.unlink(missing_ok=True)
    verify_file(DEFAULT_CACHE_PATH, spec["sha256"], spec["name"])
    return DEFAULT_CACHE_PATH


def build(
    source_path: Path | None,
    storage_path: Path,
    annotation_path: Path,
    output_dir: Path,
) -> None:
    source_path = obtain_longmemeval_source(source_path)
    storage_spec = load_manifest()["sources"]["storage_decision_normalized"]
    verify_file(storage_path, storage_spec["sha256"], storage_spec["name"])
    with source_path.open("r", encoding="utf-8") as handle:
        source_records = json.load(handle)
    if not isinstance(source_records, list):
        raise BenchmarkError("LongMemEval source must be a JSON array")

    counts = expected_counts()
    records_by_axis: dict[str, list[dict[str, Any]]] = {
        "A": read_jsonl(storage_path),
        **select_longmemeval_cases(source_records),
    }
    apply_knowledge_update_annotations(records_by_axis["C"], annotation_path)
    validate_storage_records(records_by_axis["A"], counts["A"])
    for axis in ("B", "C", "D"):
        validate_memory_records(axis, records_by_axis[axis], counts[axis])
    validate_unique_case_ids(records_by_axis)

    output_dir.mkdir(parents=True, exist_ok=True)
    for axis, filename in OUTPUT_FILES.items():
        write_jsonl_atomic(output_dir / filename, records_by_axis[axis])
    write_json_atomic(
        output_dir / "artifact_manifest.json",
        artifact_manifest(
            output_dir,
            source_path,
            storage_path,
            annotation_path,
            records_by_axis,
        ),
    )


def validate_artifacts(output_dir: Path) -> dict[str, Any]:
    counts = expected_counts()
    benchmark_manifest = load_manifest()
    records_by_axis = {
        axis: read_jsonl(output_dir / filename)
        for axis, filename in OUTPUT_FILES.items()
    }
    validate_storage_records(records_by_axis["A"], counts["A"])
    for axis in ("B", "C", "D"):
        validate_memory_records(axis, records_by_axis[axis], counts[axis])
    validate_unique_case_ids(records_by_axis)

    with (output_dir / "artifact_manifest.json").open("r", encoding="utf-8") as handle:
        generated_manifest = json.load(handle)
    for generated_key, canonical_key in (
        ("benchmark", "name"),
        ("version", "version"),
        ("profile", "profile"),
    ):
        if generated_manifest.get(generated_key) != benchmark_manifest.get(
            canonical_key
        ):
            raise BenchmarkError(
                f"artifact manifest {generated_key} does not match benchmark contract"
            )
    if generated_manifest.get("generator") != "prepare.py":
        raise BenchmarkError("artifact manifest generator mismatch")
    expected_longmemeval_sha = benchmark_manifest["sources"][
        "longmemeval_s_cleaned"
    ]["sha256"]
    if generated_manifest.get("sources", {}).get(
        "longmemeval_s_cleaned", {}
    ).get("sha256") != expected_longmemeval_sha:
        raise BenchmarkError("artifact manifest LongMemEval source SHA-256 mismatch")
    for axis, filename in OUTPUT_FILES.items():
        file_record = generated_manifest["files"].get(filename, {})
        canonical_file_record = benchmark_manifest["artifacts"].get(filename, {})
        if file_record.get("axis") != axis:
            raise BenchmarkError(f"{filename}: manifest axis mismatch")
        if file_record.get("cases") != len(records_by_axis[axis]):
            raise BenchmarkError(f"{filename}: manifest count mismatch")
        actual_sha256 = sha256_file(output_dir / filename)
        if file_record.get("sha256") != actual_sha256:
            raise BenchmarkError(f"{filename}: manifest SHA-256 mismatch")
        if canonical_file_record.get("axis") != axis:
            raise BenchmarkError(f"{filename}: canonical axis mismatch")
        if canonical_file_record.get("expected_cases") != counts[axis]:
            raise BenchmarkError(f"{filename}: canonical count mismatch")
        if canonical_file_record.get("sha256") != actual_sha256:
            raise BenchmarkError(f"{filename}: canonical SHA-256 mismatch")
    expected_storage_sha = benchmark_manifest["sources"][
        "storage_decision_normalized"
    ]["sha256"]
    if generated_manifest.get("sources", {}).get(
        "storage_decision", {}
    ).get("sha256") != expected_storage_sha:
        raise BenchmarkError("artifact manifest storage source SHA-256 mismatch")
    expected_annotation_sha = benchmark_manifest["sources"][
        "knowledge_update_annotations"
    ]["sha256"]
    if generated_manifest.get("sources", {}).get(
        "knowledge_update_annotations", {}
    ).get("sha256") != expected_annotation_sha:
        raise BenchmarkError(
            "artifact manifest knowledge-update annotation SHA-256 mismatch"
        )
    if sha256_file(output_dir / OUTPUT_FILES["A"]) != expected_storage_sha:
        raise BenchmarkError("axis A does not match the frozen normalized dataset")
    if generated_manifest.get("total_cases") != sum(
        len(records) for records in records_by_axis.values()
    ):
        raise BenchmarkError("artifact manifest total count mismatch")
    return generated_manifest


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    import_parser = subparsers.add_parser(
        "import-storage", help="Normalize the pinned PetAI storage test sets"
    )
    import_parser.add_argument("--test", type=Path, required=True)
    import_parser.add_argument("--challenge", type=Path, required=True)
    import_parser.add_argument("--output", type=Path, default=DEFAULT_STORAGE_PATH)

    build_parser = subparsers.add_parser(
        "build", help="Build all ignored benchmark artifacts"
    )
    build_parser.add_argument("--source", type=Path)
    build_parser.add_argument("--storage", type=Path, default=DEFAULT_STORAGE_PATH)
    build_parser.add_argument(
        "--knowledge-update-annotations",
        type=Path,
        default=DEFAULT_KNOWLEDGE_UPDATE_ANNOTATIONS_PATH,
    )
    build_parser.add_argument("--output-dir", type=Path, default=DEFAULT_ARTIFACT_DIR)

    validate_parser = subparsers.add_parser(
        "validate", help="Validate a generated artifact directory"
    )
    validate_parser.add_argument(
        "--artifact-dir", type=Path, default=DEFAULT_ARTIFACT_DIR
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.command == "import-storage":
            import_storage(args.test, args.challenge, args.output)
            print(f"wrote {args.output}")
        elif args.command == "build":
            build(
                args.source,
                args.storage,
                args.knowledge_update_annotations,
                args.output_dir,
            )
            print(f"built {args.output_dir}")
        else:
            result = validate_artifacts(args.artifact_dir)
            print(canonical_json(result))
    except (BenchmarkError, OSError, KeyError, TypeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
