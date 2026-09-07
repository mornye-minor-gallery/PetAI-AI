import hashlib
import json
import os
from pathlib import Path
import shutil

SCOPE = "single-turn-fixed-general-empty-memory"


def repository():
    root = Path(__file__).resolve().parents[3]
    if not (root / "ios/EdgeLLM/Package.swift").is_file():
        raise ValueError("install editable from the PetAI checkout: uv tool install --editable ai/beolmuri-eval")
    return root


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def file_sha(path):
    result = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def source_sha(root):
    package = root / "ai/beolmuri-eval"
    files = list((package / "beolmuri_eval").glob("*.py"))
    files += list((package / "swift/Sources").rglob("*.swift"))
    files += [p for p in (root / "ios/EdgeLLM/Sources").rglob("*") if p.is_file()]
    files += [package / "pyproject.toml", package / "uv.lock", package / "swift/Package.swift",
              package / "schemas/evaluation.schema.json", package / "schemas/name-case.schema.json",
              root / "ios/EdgeLLM/Package.swift", root / "ai/models/runtime-models.json"]
    return digest({str(p.relative_to(root)): file_sha(p) for p in sorted(files)})


def model_path(raw=None):
    return Path(raw or os.environ.get("BEOLMURI_EVAL_MODEL", "") or
                Path.home() / ".litert-lm/models/gemma4-e2b/model.litertlm").expanduser().resolve()


def python_path(raw=None):
    if raw or os.environ.get("BEOLMURI_EVAL_LITERT_PYTHON"):
        return str(Path(raw or os.environ["BEOLMURI_EVAL_LITERT_PYTHON"]).expanduser().absolute())
    cli = shutil.which("litert-lm")
    if cli:
        candidate = Path(cli).resolve().parent / "python"
        if candidate.is_file():
            return str(candidate)
    raise ValueError("set BEOLMURI_EVAL_LITERT_PYTHON to a Python environment with litert-lm==0.13.1")


def model_artifact(root):
    registry = json.loads((root / "ai/models/runtime-models.json").read_text())
    return next(item for item in registry["artifacts"] if item["role"] == "chat")
