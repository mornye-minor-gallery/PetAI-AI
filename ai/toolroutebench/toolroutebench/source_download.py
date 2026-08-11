from __future__ import annotations

import urllib.error
import urllib.request
from pathlib import Path

from .common import ToolRouteBenchError, sha256_file


def download_pinned_source(
    *,
    label: str,
    url: str,
    expected_sha256: str,
    output_path: Path,
) -> Path:
    if output_path.is_file():
        if sha256_file(output_path) != expected_sha256:
            raise ToolRouteBenchError(f"cached {label} SHA-256 differs: {output_path}")
        return output_path
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(output_path.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            payload = response.read()
        temporary_path.write_bytes(payload)
        if sha256_file(temporary_path) != expected_sha256:
            raise ToolRouteBenchError(f"downloaded {label} SHA-256 differs: {url}")
        temporary_path.replace(output_path)
    except (OSError, urllib.error.URLError) as error:
        temporary_path.unlink(missing_ok=True)
        raise ToolRouteBenchError(f"could not download {label}: {url}") from error
    return output_path
