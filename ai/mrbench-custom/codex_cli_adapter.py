from __future__ import annotations

import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


def codex_cli_version(codex_bin: str, *, timeout_seconds: float = 10.0) -> str:
    completed = subprocess.run(
        [codex_bin, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    version = completed.stdout.strip()
    if not version:
        raise RuntimeError("Codex CLI returned an empty version string")
    return version


def codex_cli_completion(
    *,
    prompt: str,
    model: str,
    reasoning_effort: str,
    output_schema: Path,
    codex_bin: str,
    working_directory: Path,
    timeout_seconds: float,
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    if not output_schema.is_file():
        raise FileNotFoundError(f"Codex output schema does not exist: {output_schema}")
    if not working_directory.is_dir():
        raise NotADirectoryError(f"Codex working directory does not exist: {working_directory}")

    with tempfile.TemporaryDirectory(prefix="mrbench-custom-codex-") as temporary_directory:
        output_path = Path(temporary_directory) / "last-message.json"
        command = [
            codex_bin,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox",
            "read-only",
            "--model",
            model,
            "-c",
            f'model_reasoning_effort="{reasoning_effort}"',
            "--output-schema",
            str(output_schema.resolve()),
            "--output-last-message",
            str(output_path),
            "--cd",
            str(working_directory.resolve()),
            "-",
        ]
        started = time.monotonic()
        try:
            completed = subprocess.run(
                command,
                input=prompt,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"Codex CLI judge timed out after {timeout_seconds:g} seconds"
            ) from exc
        elapsed_ms = round((time.monotonic() - started) * 1000, 3)
        if completed.returncode != 0:
            diagnostic = (completed.stderr or completed.stdout).strip()[-2000:]
            raise RuntimeError(
                f"Codex CLI judge failed with exit code {completed.returncode}: {diagnostic}"
            )
        if not output_path.is_file():
            raise RuntimeError("Codex CLI did not write the requested final-message file")
        content = output_path.read_text(encoding="utf-8").strip()
        if not content:
            raise RuntimeError("Codex CLI returned an empty final message")
        return content, {}, {"elapsed_ms": elapsed_ms}
