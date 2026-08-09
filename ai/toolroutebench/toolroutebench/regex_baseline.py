from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .common import (
    CONTRACTS_DIR,
    REPOSITORY_ROOT,
    ToolRouteBenchError,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import load_tool_contract, validate_record_schema


@dataclass(frozen=True)
class Rule:
    tool_id: str
    domain: str
    request: str


# Keep these expressions line-for-line equivalent to KoreanNativeToolRouter.swift.
RULES = (
    Rule(
        "get_step_count",
        r"걸음|보행|스텝|만\s*보",
        r"몇|얼마|알려\s*줘|보여\s*줘|조회|확인|합계",
    ),
    Rule(
        "create_alarm",
        r"알람|깨워",
        r"맞춰\s*줘|설정해\s*줘|등록해\s*줘|추가해\s*줘|만들어\s*줘|깨워\s*줘",
    ),
    Rule(
        "list_alarms",
        r"알람",
        r"목록|보여\s*줘|알려\s*줘|조회|확인|뭐|어떤",
    ),
    Rule(
        "create_timer",
        r"타이머|카운트다운",
        r"시작|설정|맞춰\s*줘|재\s*줘|켜\s*줘",
    ),
    Rule(
        "schedule_local_notification",
        r"알림|리마인드|라고\s*알려",
        r"예약|설정|등록|추가|알려\s*줘",
    ),
    Rule(
        "get_calendar_events",
        r"일정|캘린더|약속",
        r"알려\s*(?:줘|주고)|보여\s*(?:줘|주고)|조회|확인|뭐|어떤|있어\s*\?|있나\s*\?",
    ),
    Rule(
        "create_calendar_event",
        r"일정|캘린더|약속",
        r"잡아\s*줘|추가해\s*줘|등록해\s*줘|생성해\s*줘|만들어\s*줘|넣어\s*줘",
    ),
)

RELATIVE_DURATION = re.compile(r"(?:\d+|한|두|세|네)\s*(?:초|분|시간)\s*(?:뒤|후)")
ALARM_DOMAIN = re.compile(r"알람|깨워")
ALARM_REQUEST = re.compile(
    r"맞춰\s*줘|설정해\s*줘|등록해\s*줘|추가해\s*줘|만들어\s*줘|깨워\s*줘"
)


def validate_regex_source() -> dict[str, str]:
    contract = load_tool_contract()["regex_baseline"]
    source_path = REPOSITORY_ROOT / contract["source"]
    actual = sha256_file(source_path)
    if actual != contract["source_sha256"]:
        raise ToolRouteBenchError(
            "Swift KoreanNativeToolRouter changed; review and update the Python port "
            "before running the baseline"
        )
    return {
        "path": str(source_path.resolve()),
        "sha256": actual,
    }


class PythonKoreanNativeToolRouter:
    def __init__(self) -> None:
        validate_regex_source()
        contract_order = load_tool_contract()["tool_order"]
        if [rule.tool_id for rule in RULES] != contract_order:
            raise ToolRouteBenchError("Python Regex rules differ from Tool contract order")
        self._compiled_rules = tuple(
            (rule.tool_id, re.compile(rule.domain), re.compile(rule.request))
            for rule in RULES
        )

    def route(self, utterance: str) -> list[str]:
        normalized = unicodedata.normalize("NFC", utterance).lower().strip()
        if not normalized:
            return []
        if (
            RELATIVE_DURATION.search(normalized)
            and ALARM_DOMAIN.search(normalized)
            and ALARM_REQUEST.search(normalized)
        ):
            return ["create_timer"]
        matched = {
            tool_id
            for tool_id, domain, request in self._compiled_rules
            if domain.search(normalized) and request.search(normalized)
        }
        return [
            tool_id
            for tool_id in load_tool_contract()["tool_order"]
            if tool_id in matched
        ]


def _manifest_path(predictions_path: Path) -> Path:
    return predictions_path.with_suffix(".manifest.json")


def export_regex_predictions(dataset_path: Path, output_path: Path) -> Path:
    commit = git_commit(require_clean=True)
    records = read_jsonl(dataset_path)
    if not records:
        raise ToolRouteBenchError("Regex baseline dataset must not be empty")
    for record in records:
        validate_record_schema(record)
        if record["split"] not in {"dev", "holdout"}:
            raise ToolRouteBenchError(
                "Regex baseline exporter accepts Dev or Holdout only"
            )
    splits = {record["split"] for record in records}
    if len(splits) != 1:
        raise ToolRouteBenchError("Regex baseline dataset must contain one split")
    router = PythonKoreanNativeToolRouter()
    predictions = [
        {
            "case_id": record["case_id"],
            "predicted_tool_ids": router.route(record["utterance"]),
        }
        for record in records
    ]
    write_jsonl(output_path, predictions)
    source = validate_regex_source()
    manifest = {
        "schema_version": "toolroutebench-regex-baseline-v1",
        "created_at": utc_now(),
        "git_commit": commit,
        "implementation": "python_semantic_port",
        "split": next(iter(splits)),
        "swift_source": source,
        "tool_contract": {
            "path": str((CONTRACTS_DIR / "tools.v1.json").resolve()),
            "sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
        },
        "dataset": {
            "path": str(dataset_path.resolve()),
            "records": len(records),
            "sha256": sha256_file(dataset_path),
        },
        "predictions": {
            "path": str(output_path.resolve()),
            "records": len(predictions),
            "sha256": sha256_file(output_path),
        },
    }
    write_json(_manifest_path(output_path), manifest)
    return output_path.resolve()


def validate_regex_predictions_artifact(
    predictions_path: Path, dataset_path: Path
) -> dict[str, Any]:
    source = validate_regex_source()
    manifest_path = _manifest_path(predictions_path)
    manifest = read_json(manifest_path)
    expected = {
        "schema_version": "toolroutebench-regex-baseline-v1",
        "implementation": "python_semantic_port",
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ToolRouteBenchError("Regex baseline manifest contract is invalid")
    if manifest.get("swift_source") != source:
        raise ToolRouteBenchError("Regex baseline was produced from another Swift source")
    if manifest.get("tool_contract", {}).get("sha256") != sha256_file(
        CONTRACTS_DIR / "tools.v1.json"
    ):
        raise ToolRouteBenchError("Regex baseline Tool contract is stale")
    if manifest.get("dataset", {}).get("sha256") != sha256_file(dataset_path):
        raise ToolRouteBenchError("Regex baseline dataset SHA does not match")
    if manifest.get("predictions", {}).get("sha256") != sha256_file(predictions_path):
        raise ToolRouteBenchError("Regex baseline predictions SHA does not match manifest")
    return manifest
