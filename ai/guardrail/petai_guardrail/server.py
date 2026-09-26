from __future__ import annotations

import contextlib
import subprocess
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import httpx

from .common import GuardrailError, expand_path
from .config import TargetConfig


def server_ready(target: TargetConfig) -> bool:
    try:
        response = httpx.get(
            f"{target.base_url}/models", timeout=min(target.timeout_seconds, 5)
        )
        response.raise_for_status()
        return True
    except (httpx.HTTPError, ValueError):
        return False


@dataclass
class ManagedServer:
    process: subprocess.Popen[str] | None
    log_path: Path

    @property
    def owned(self) -> bool:
        return self.process is not None


@contextlib.contextmanager
def ensure_server(target: TargetConfig, run_dir: Path) -> Iterator[ManagedServer]:
    log_path = run_dir / "litert-lm-server.log"
    if server_ready(target):
        yield ManagedServer(process=None, log_path=log_path)
        return

    cli = expand_path(target.litert_lm_cli)
    if not cli.is_file():
        raise GuardrailError(f"LiteRT-LM CLI not found: {cli}")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as log:
        process = subprocess.Popen(
            [
                str(cli),
                "serve",
                "--host",
                target.host,
                "--port",
                str(target.port),
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.monotonic() + target.timeout_seconds
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise GuardrailError(
                    f"LiteRT-LM server exited with {process.returncode}; see {log_path}."
                )
            if server_ready(target):
                break
            time.sleep(0.5)
        else:
            process.terminate()
            raise GuardrailError(f"LiteRT-LM server did not become ready: {log_path}")
        try:
            yield ManagedServer(process=process, log_path=log_path)
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
