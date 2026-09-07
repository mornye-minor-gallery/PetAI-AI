"""Codex CLI provider. Inputs are synthetic evaluation conversations only."""
import json
from pathlib import Path
import tempfile
import time
from .metrics import LABELS
from .evaluation import load_plan
from .process import execute

def command(codex, schema, output, directory, settings=None):
    settings = settings if settings is not None else load_plan().judge
    return [codex, "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "--skip-git-repo-check", "--model", settings["model"],
            "-c", f'model_reasoning_effort="{settings["reasoning_effort"]}"', "--output-schema", str(schema),
            "--output-last-message", str(output), "--cd", str(directory), "-"]


def judge_prompt(case, answer, settings=None):
    settings = settings if settings is not None else load_plan().judge
    data = {key: case[key] for key in ("character_name", "called_name", "kind", "user_message")}
    data["response"] = answer
    return settings["rubric"] + "\n평가 데이터(JSON):\n" + json.dumps(data, ensure_ascii=False)


def validate_judgment(value, answer, kind, schema=None):
    import jsonschema
    try:
        jsonschema.validate(value, schema if schema is not None else load_plan().judge["output_schema"])
    except jsonschema.ValidationError as error:
        raise ValueError(f"invalid judgment schema: {error.message}") from error
    if value["label"] not in LABELS:
        raise ValueError("unsupported judgment label")
    evidence = value["evidence"]
    if evidence not in answer or (not evidence and value["label"] != "unjudgeable"):
        raise ValueError("judge evidence must quote the actual response")
    correction = value["incorrect_name_correction"]
    if kind == "wrong_name" and correction is not None:
        raise ValueError("wrong-name cases have no control correction decision")
    if kind == "correct_name":
        if (value["label"] == "unjudgeable") != (correction is None):
            raise ValueError("control uncertainty must be explicit")
        if correction is True and value["label"] != "uncorrected_response":
            raise ValueError("inconsistent control correction label")
        if correction is False and value["label"] != "identity_maintained":
            raise ValueError("inconsistent normal control label")
    return value


def grade(case, answer, codex="codex", timeout=120, settings=None):
    settings = settings if settings is not None else load_plan().judge
    with tempfile.TemporaryDirectory(prefix="beolmuri-judge-") as directory:
        root = Path(directory)
        schema, output = root / "schema.json", root / "answer.json"
        schema.write_text(json.dumps(settings["output_schema"]), encoding="utf-8")
        started = time.monotonic()
        stdout, stderr = execute(command(codex, schema, output, root, settings),
                                 input_text=judge_prompt(case, answer, settings), timeout=timeout)
        value = validate_judgment(json.loads(output.read_text()), answer, case["kind"], settings["output_schema"])
        return value, {"provider": "codex-cli", "requested_model": settings["model"], "reasoning_effort": settings["reasoning_effort"],
                       "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                       "stdout": stdout, "stderr": stderr}
