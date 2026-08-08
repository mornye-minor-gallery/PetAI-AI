from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from collections.abc import Iterable, Iterator, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
CONTRACTS_DIR = ROOT / "contracts"
PROMPTS_DIR = ROOT / "prompts"
SCHEMAS_DIR = ROOT / "schemas"


class FacetRouteBenchError(RuntimeError):
    """Raised when a benchmark contract cannot be satisfied."""


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path, description: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise FacetRouteBenchError(f"{description} was not found: {resolved}")
    return resolved


def require_new_path(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if resolved.exists():
        raise FacetRouteBenchError(f"refusing to overwrite existing path: {resolved}")
    resolved.parent.mkdir(parents=True, exist_ok=True)
    return resolved


def assert_not_invalidated(path: Path) -> None:
    resolved = path.expanduser().resolve()
    for parent in (resolved.parent, *resolved.parents):
        marker = parent / "INVALIDATED.json"
        if marker.is_file():
            raise FacetRouteBenchError(
                f"refusing to use invalidated benchmark artifacts: {marker}"
            )
        if parent == REPO_ROOT:
            break


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(require_file(path, "JSON file").read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise FacetRouteBenchError(f"expected a JSON object: {path}")
    return value


def write_json(path: Path, value: Any, *, overwrite: bool = False) -> None:
    resolved = path.expanduser().resolve()
    if resolved.exists() and not overwrite:
        raise FacetRouteBenchError(f"refusing to overwrite existing file: {resolved}")
    resolved.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=resolved.parent,
        prefix=f".{resolved.name}.",
        delete=False,
    ) as handle:
        handle.write(payload)
        temporary = Path(handle.name)
    os.replace(temporary, resolved)


def iter_jsonl(path: Path) -> Iterator[tuple[int, dict[str, Any]]]:
    assert_not_invalidated(path)
    with require_file(path, "JSONL file").open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise FacetRouteBenchError(
                    f"{path}:{line_number}: invalid JSON: {error.msg}"
                ) from error
            if not isinstance(value, dict):
                raise FacetRouteBenchError(
                    f"{path}:{line_number}: expected a JSON object"
                )
            yield line_number, value


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [value for _, value in iter_jsonl(path)]


def write_jsonl(
    path: Path,
    values: Iterable[dict[str, Any]],
    *,
    overwrite: bool = False,
) -> None:
    resolved = path.expanduser().resolve()
    if resolved.exists() and not overwrite:
        raise FacetRouteBenchError(f"refusing to overwrite existing file: {resolved}")
    resolved.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        dir=resolved.parent,
        prefix=f".{resolved.name}.",
        delete=False,
    ) as handle:
        for value in values:
            handle.write(canonical_json(value) + "\n")
        temporary = Path(handle.name)
    os.replace(temporary, resolved)


def normalized_text(text: str) -> str:
    return re.sub(r"[^0-9a-z가-힣]+", "", text.casefold())


def final_user_text(messages: Sequence[dict[str, str]]) -> str:
    if not messages or messages[-1].get("role") != "user":
        raise FacetRouteBenchError("messages must end with a user turn")
    content = messages[-1].get("content")
    if not isinstance(content, str) or not content.strip():
        raise FacetRouteBenchError("final user message must be non-empty")
    return content.strip()


def conversation_text(messages: Sequence[dict[str, str]]) -> str:
    final_user_text(messages)
    try:
        return "\n".join(
            f"{message['role']}:{message['content'].strip()}" for message in messages
        )
    except (KeyError, AttributeError) as error:
        raise FacetRouteBenchError("invalid conversation message") from error


def render_router_input(
    messages: Sequence[dict[str, str]],
    *,
    include_history: bool,
    maximum_history_turns: int = 6,
) -> str:
    current = final_user_text(messages)
    sections: list[str] = []
    if include_history:
        history = list(messages[:-1])[-maximum_history_turns:]
        if history:
            role_names = {"user": "사용자", "assistant": "캐릭터"}
            try:
                rendered = "\n".join(
                    f"{role_names[item['role']]}: {item['content'].strip()}"
                    for item in history
                )
            except (KeyError, AttributeError) as error:
                raise FacetRouteBenchError("invalid context message") from error
            sections.append(f"## 최근 대화\n{rendered}")
    sections.append(f"## 마지막 사용자 요청\n{current}")
    return "\n\n".join(sections)


def parse_unique_route(raw_text: str, route_ids: Sequence[str]) -> str | None:
    upper = raw_text.upper()
    matches = [
        route
        for route in route_ids
        if re.search(
            rf"(?<![A-Z0-9_]){re.escape(route)}(?![A-Z0-9_])",
            upper,
        )
    ]
    return matches[0] if len(matches) == 1 else None


def chunked(values: Sequence[Any], size: int) -> Iterator[list[Any]]:
    if size < 1:
        raise ValueError("chunk size must be positive")
    for index in range(0, len(values), size):
        yield list(values[index : index + size])
