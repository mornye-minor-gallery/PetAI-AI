#!/usr/bin/env python3
"""Build and validate the deterministic EdgeMemBench v0 data artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import Any, Iterable, Iterator


ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "benchmark_manifest.json"
DEFAULT_STORAGE_PATH = ROOT / "data" / "storage_decision.jsonl"
DEFAULT_ARTIFACT_DIR = ROOT / ".artifacts" / "v0"
DEFAULT_CACHE_PATH = ROOT / ".artifacts" / "cache" / "longmemeval_s_cleaned.json"

OUTPUT_FILES = {
    "A": "storage_decision.jsonl",
    "B": "single_memory_retrieval.jsonl",
    "C": "knowledge_update.jsonl",
    "D": "abstention.jsonl",
}


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
    dates = record.get("haystack_dates", [])
    session_ids = record.get("haystack_session_ids", [])
    sessions = record.get("haystack_sessions", [])
    if not (len(dates) == len(session_ids) == len(sessions)):
        raise BenchmarkError(f"{question_id}: session metadata lengths differ")

    normalized_sessions: list[dict[str, Any]] = []
    gold_evidence_turn_ids: list[str] = []
    partial_evidence_turn_ids: list[str] = []
    is_abstention = axis == "D"
    for session_id, date, session in zip(session_ids, dates, sessions, strict=True):
        user_turns: list[dict[str, Any]] = []
        for source_index, turn in enumerate(session):
            source_turn_id = turn_id(str(session_id), source_index)
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
                "session_id": str(session_id),
                "timestamp": str(date),
                "turns": user_turns,
            }
        )

    if not is_abstention and not gold_evidence_turn_ids:
        raise BenchmarkError(f"{question_id}: answerable case has no gold evidence")

    return {
        "case_id": f"edgemem-{axis.lower()}-{question_id}",
        "axis": axis,
        "task": task,
        "query": record["question"],
        "history": normalized_sessions,
        "expected": {
            "answer": record["answer"],
            "expected_abstention": is_abstention,
            "gold_evidence_turn_ids": gold_evidence_turn_ids,
            "partial_evidence_turn_ids": partial_evidence_turn_ids,
            "answer_session_ids": [
                str(value) for value in record.get("answer_session_ids", [])
            ],
        },
        "source": {
            "dataset": "LongMemEval-S cleaned",
            "question_id": question_id,
            "question_type": record["question_type"],
        },
    }


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
        if record.get("axis") != axis:
            raise BenchmarkError(f"{case_id}: wrong axis")
        observed_turn_ids: set[str] = set()
        for session in record.get("history", []):
            for turn in session.get("turns", []):
                if turn.get("role") != "user":
                    raise BenchmarkError(f"{case_id}: assistant turn leaked into history")
                observed_turn_ids.add(str(turn.get("turn_id")))
        expected = record.get("expected", {})
        gold = set(expected.get("gold_evidence_turn_ids", []))
        partial = set(expected.get("partial_evidence_turn_ids", []))
        if axis == "D":
            if expected.get("expected_abstention") is not True or gold:
                raise BenchmarkError(f"{case_id}: invalid abstention contract")
            if not partial.issubset(observed_turn_ids):
                raise BenchmarkError(
                    f"{case_id}: partial abstention evidence is missing from history"
                )
        else:
            if expected.get("expected_abstention") is not False or not gold:
                raise BenchmarkError(f"{case_id}: invalid answerable contract")
            if not gold.issubset(observed_turn_ids):
                raise BenchmarkError(f"{case_id}: gold evidence is missing from history")
            if partial:
                raise BenchmarkError(f"{case_id}: unexpected partial evidence")


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
    records_by_axis: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    files: dict[str, Any] = {}
    for axis, filename in OUTPUT_FILES.items():
        path = output_dir / filename
        files[filename] = {
            "axis": axis,
            "cases": len(records_by_axis[axis]),
            "sha256": sha256_file(path),
        }
    return {
        "benchmark": "EdgeMemBench",
        "version": "0.1.0",
        "profile": "edgemem-abcd-v0",
        "generator": "prepare.py",
        "sources": {
            "longmemeval_s_cleaned": {
                "sha256": sha256_file(source_path),
            },
            "storage_decision": {
                "sha256": sha256_file(DEFAULT_STORAGE_PATH),
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


def build(source_path: Path | None, storage_path: Path, output_dir: Path) -> None:
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
    validate_storage_records(records_by_axis["A"], counts["A"])
    for axis in ("B", "C", "D"):
        validate_memory_records(axis, records_by_axis[axis], counts[axis])
    validate_unique_case_ids(records_by_axis)

    output_dir.mkdir(parents=True, exist_ok=True)
    for axis, filename in OUTPUT_FILES.items():
        write_jsonl_atomic(output_dir / filename, records_by_axis[axis])
    write_json_atomic(
        output_dir / "artifact_manifest.json",
        artifact_manifest(output_dir, source_path, records_by_axis),
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
    expected_longmemeval_sha = benchmark_manifest["sources"][
        "longmemeval_s_cleaned"
    ]["sha256"]
    if generated_manifest.get("sources", {}).get(
        "longmemeval_s_cleaned", {}
    ).get("sha256") != expected_longmemeval_sha:
        raise BenchmarkError("artifact manifest LongMemEval source SHA-256 mismatch")
    for axis, filename in OUTPUT_FILES.items():
        file_record = generated_manifest["files"].get(filename, {})
        if file_record.get("cases") != len(records_by_axis[axis]):
            raise BenchmarkError(f"{filename}: manifest count mismatch")
        if file_record.get("sha256") != sha256_file(output_dir / filename):
            raise BenchmarkError(f"{filename}: manifest SHA-256 mismatch")
    expected_storage_sha = benchmark_manifest["sources"][
        "storage_decision_normalized"
    ]["sha256"]
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
            build(args.source, args.storage, args.output_dir)
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
