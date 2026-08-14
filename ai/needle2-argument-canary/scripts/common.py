from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path


CANARY_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = CANARY_ROOT.parents[1]
DATASET_PATH = CANARY_ROOT / "datasets" / "canary.v1.jsonl"
TOOLS_PATH = CANARY_ROOT / "contracts" / "tools.v1.json"
PROMPT_ROOT = (
    REPO_ROOT
    / "ios"
    / "EdgeLLM"
    / "Sources"
    / "EdgeLLM"
    / "Resources"
    / "Prompts"
    / "ToolUse"
)
ARTIFACT_ROOT = CANARY_ROOT / ".artifacts"

FIXED_DATE = "2026-08-13"
FIXED_DATE_TIME = "2026-08-13T21:00"
FIXED_TIME_ZONE = "Asia/Seoul"
NEEDLE_SYSTEM_FACTS = (
    "date: 2026-08-13 Thu 21:00; locale: ko-KR; device: phone; "
    "assistant: Elena"
)
COMMON_SYSTEM_FACTS = (
    "date: 2026-08-13 Thu 21:00; locale: ko-KR; device: phone; "
    "assistant: Elena"
)


def read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def read_jsonl(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def base_schema(tool_name: str) -> dict:
    payload = read_json(TOOLS_PATH)
    assert isinstance(payload, dict)
    tool = payload["tools"][tool_name]
    return {
        "name": tool_name,
        "description": tool["description"],
        "parameters": copy.deepcopy(tool["parameters"]),
    }


def production_prompt(tool_name: str) -> str:
    source = (PROMPT_ROOT / f"{tool_name}.md").read_text(encoding="utf-8")
    return (
        source
        + "\n\n## 기기 기준\n\n"
        + f"- currentDate: {FIXED_DATE}\n"
        + f"- currentDateTime: {FIXED_DATE_TIME}\n"
        + f"- timeZoneIdentifier: {FIXED_TIME_ZONE}"
    )


def enriched_schema(tool_name: str) -> dict:
    schema = base_schema(tool_name)
    rules = (PROMPT_ROOT / f"{tool_name}.md").read_text(encoding="utf-8")
    schema["description"] = schema["description"] + "\n\n" + rules
    return schema


def openai_tool(schema: dict) -> dict:
    return {"type": "function", "function": schema}
