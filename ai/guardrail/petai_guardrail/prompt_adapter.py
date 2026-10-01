from __future__ import annotations

import json
import subprocess
from collections.abc import Iterable
from typing import Any

from .common import PROJECT_ROOT, GuardrailError, canonical_json

PACKAGE_PATH = PROJECT_ROOT / "swift" / "ProductPromptAdapter"


def _command(action: str) -> list[str]:
    return [
        "swift",
        "run",
        "--package-path",
        str(PACKAGE_PATH),
        "-c",
        "release",
        "product-prompt-adapter",
        action,
    ]


def prompt_snapshot() -> dict[str, Any]:
    result = subprocess.run(
        _command("prompt"), text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        raise GuardrailError(f"Swift prompt adapter failed: {result.stderr.strip()}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GuardrailError("Swift prompt adapter returned invalid JSON.") from error
    if not isinstance(value, dict) or not value.get("systemPrompt"):
        raise GuardrailError("Swift prompt adapter returned no system prompt.")
    return value


def normalize_responses(
    records: Iterable[dict[str, str]],
) -> dict[str, dict[str, Any]]:
    payload = "".join(canonical_json(record) + "\n" for record in records)
    result = subprocess.run(
        _command("normalize"),
        input=payload,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise GuardrailError(f"Swift response adapter failed: {result.stderr.strip()}")
    output: dict[str, dict[str, Any]] = {}
    for line_number, line in enumerate(result.stdout.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise GuardrailError(
                f"Swift response adapter returned invalid JSONL at line {line_number}."
            ) from error
        output[row["case_id"]] = row
    return output
