from __future__ import annotations

import json
import hashlib
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterable, Iterator


PACKAGE_ROOT = Path(__file__).resolve().parent.parent
CONTRACTS_DIR = PACKAGE_ROOT / "contracts"
CONFIGS_DIR = PACKAGE_ROOT / "configs"
PROMPTS_DIR = PACKAGE_ROOT / "prompts"
SCHEMAS_DIR = PACKAGE_ROOT / "schemas"
REPOSITORY_ROOT = PACKAGE_ROOT.parent.parent


class ToolRouteBenchError(RuntimeError):
    """Raised when a frozen ToolRouteBench contract is violated."""


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ToolRouteBenchError(f"could not read JSON contract {path}: {error}") from error
    if not isinstance(value, dict):
        raise ToolRouteBenchError(f"JSON contract must contain an object: {path}")
    return value


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ToolRouteBenchError(
                        f"{path}:{line_number}: JSONL record must be an object"
                    )
                yield value
    except (OSError, json.JSONDecodeError) as error:
        raise ToolRouteBenchError(f"could not read JSONL {path}: {error}") from error


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return list(iter_jsonl(path))


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ToolRouteBenchError(f"could not hash {path}: {error}") from error
    return digest.hexdigest()


def write_json(path: Path, value: Any, *, overwrite: bool = False) -> None:
    if path.exists() and not overwrite:
        raise ToolRouteBenchError(f"refusing to overwrite existing file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_jsonl(
    path: Path,
    values: Iterable[dict[str, Any]],
    *,
    overwrite: bool = False,
) -> None:
    if path.exists() and not overwrite:
        raise ToolRouteBenchError(f"refusing to overwrite existing file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(canonical_json(value) + "\n" for value in values)
    path.write_text(payload, encoding="utf-8")


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(canonical_json(value) + "\n")


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def git_commit(*, require_clean: bool = True) -> str:
    if require_clean:
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if status:
            raise ToolRouteBenchError(
                "benchmark execution requires a clean Git worktree"
            )
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
