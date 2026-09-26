from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .common import GuardrailError


@dataclass(frozen=True)
class Case:
    case_id: str
    suite: str
    prompt: str
    expected: str
    metadata: dict[str, Any]


def _limit(rows: list[Case], limit: int | None) -> list[Case]:
    return rows if limit is None else rows[:limit]


def load_multijail(path: Path, limit: int | None = None) -> list[Case]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        raw_rows = list(csv.DictReader(handle))
    if len(raw_rows) != 315:
        raise GuardrailError(f"Expected 315 MultiJail rows, found {len(raw_rows)}.")
    rows: list[Case] = []
    for row in raw_rows:
        prompt = (row.get("ko") or "").strip()
        if not prompt:
            raise GuardrailError(f"MultiJail row {row.get('id')} has no Korean prompt.")
        rows.append(
            Case(
                case_id=f"multijail-ko-{row['id']}",
                suite="multijail_ko",
                prompt=prompt,
                expected="unsafe",
                metadata={
                    "source": row.get("source", ""),
                    "tags": row.get("tags", ""),
                },
            )
        )
    return _limit(rows, limit)


def load_xstest(path: Path, limit: int | None = None) -> list[Case]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        raw_rows = list(csv.DictReader(handle))
    if len(raw_rows) != 450:
        raise GuardrailError(f"Expected 450 XSTest rows, found {len(raw_rows)}.")
    rows: list[Case] = []
    for row in raw_rows:
        label = (row.get("label") or "").strip().lower()
        if label not in {"safe", "unsafe"}:
            raise GuardrailError(f"XSTest row {row.get('id')} has label {label!r}.")
        rows.append(
            Case(
                case_id=f"xstest-{row['id']}",
                suite="xstest",
                prompt=(row.get("prompt") or "").strip(),
                expected=label,
                metadata={
                    "type": row.get("type", ""),
                    "focus": row.get("focus", ""),
                    "note": row.get("note", ""),
                },
            )
        )
    if any(not row.prompt for row in rows):
        raise GuardrailError("XSTest contains an empty prompt.")
    return _limit(rows, limit)
