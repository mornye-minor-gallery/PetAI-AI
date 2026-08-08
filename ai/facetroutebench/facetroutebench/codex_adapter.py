from __future__ import annotations

import json
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .common import FacetRouteBenchError, sha256_file, sha256_text

MODEL = "gpt-5.6-sol"
REASONING_EFFORT = "medium"


@dataclass(frozen=True)
class CodexInvocation:
    session_id: str
    prompt_sha256: str
    request_sha256: str
    elapsed_ms: float
    codex_version: str

    def provenance(self) -> dict[str, str]:
        return {
            "interface": "codex_cli",
            "model": MODEL,
            "reasoning_effort": REASONING_EFFORT,
            "prompt_template_sha256": self.prompt_sha256,
            "request_sha256": self.request_sha256,
            "session_id": self.session_id,
        }


def codex_version(codex_bin: str) -> str:
    completed = subprocess.run(
        [codex_bin, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return completed.stdout.strip()


def complete_json(
    *,
    prompt: str,
    prompt_template: Path,
    output_schema: Path,
    codex_bin: str,
    working_directory: Path,
    timeout_seconds: float,
) -> tuple[dict[str, Any], CodexInvocation]:
    if not output_schema.is_file() or not prompt_template.is_file():
        raise FacetRouteBenchError("Codex prompt template or output schema is missing")
    session_id = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="facetroutebench-codex-") as directory:
        output_path = Path(directory) / "last-message.json"
        command = [
            codex_bin,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox",
            "read-only",
            "--model",
            MODEL,
            "-c",
            f'model_reasoning_effort="{REASONING_EFFORT}"',
            "--output-schema",
            str(output_schema.resolve()),
            "--output-last-message",
            str(output_path),
            "--cd",
            str(working_directory.resolve()),
            "-",
        ]
        started = time.perf_counter()
        try:
            completed = subprocess.run(
                command,
                input=prompt,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise FacetRouteBenchError(
                f"Codex CLI timed out after {timeout_seconds:g} seconds"
            ) from error
        elapsed_ms = (time.perf_counter() - started) * 1000
        if completed.returncode != 0:
            diagnostic = (completed.stderr or completed.stdout).strip()[-2000:]
            raise FacetRouteBenchError(
                f"Codex CLI failed with exit code {completed.returncode}: {diagnostic}"
            )
        if not output_path.is_file():
            raise FacetRouteBenchError("Codex CLI did not write structured output")
        try:
            value = json.loads(output_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise FacetRouteBenchError("Codex CLI output was not valid JSON") from error
        if not isinstance(value, dict):
            raise FacetRouteBenchError("Codex CLI output must be a JSON object")
        invocation = CodexInvocation(
            session_id=session_id,
            prompt_sha256=sha256_file(prompt_template),
            request_sha256=sha256_text(prompt),
            elapsed_ms=round(elapsed_ms, 3),
            codex_version=codex_version(codex_bin),
        )
        return value, invocation
