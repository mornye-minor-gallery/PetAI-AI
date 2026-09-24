"""Resumable, schema-driven annotation through the harness's Codex adapter.

Corpus selection, definitions and prompts belong to the caller. This runner
records observable requests/results; schema conformance is not semantic accuracy.
"""
import hashlib
import json
from pathlib import Path
import re
import tempfile
import time

import jsonschema

from .judge import command
from .process import execute, heartbeat
from .storage import atomic_json, read_json, run_lock


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def source_hashes():
    return {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in ("annotation.py", "judge.py", "process.py", "storage.py")}


def snapshot(path):
    path = Path(path).resolve()
    plan = read_json(path)
    if not plan.get("model") or plan.get("reasoning_effort") not in ("low", "medium", "high", "xhigh"):
        raise ValueError("model and supported reasoning_effort are required")
    if not isinstance(plan.get("timeout"), (int, float)) or plan["timeout"] <= 0:
        raise ValueError("positive timeout required")
    requests, seen = [], set()
    for item in plan["requests"]:
        key = item["id"]
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", key) or key in seen:
            raise ValueError("request IDs must be unique safe filenames")
        seen.add(key)
        schema = read_json(path.parent / item["schema"])
        jsonschema.Draft202012Validator.check_schema(schema)
        requests.append({**item, "prompt_text": (path.parent / item["prompt"]).read_text(),
                         "output_schema": schema})
    if not requests:
        raise ValueError("empty annotation batch")
    return {**plan, "requests": requests}


def annotate(request, settings, attempt, codex):
    atomic_json(attempt / "schema.json", request["output_schema"])
    (attempt / "prompt.txt").write_text(request["prompt_text"])
    # An empty working directory prevents the response request or another sample
    # from becoming ambient project context. Tool use is rejected below as well.
    with tempfile.TemporaryDirectory(prefix="beolmuri-annotation-") as work:
        args = command(codex, attempt / "schema.json", attempt / "answer.json", work, settings)
        args.insert(-1, "--json")
        atomic_json(attempt / "invocation.json", {"argv": args,
            "input_role": "user", "provider_added_instructions": "not exposed by CLI",
            "temperature": "CLI default; not overridden", "seed": "not specified"})
        stdout, stderr = execute(args, input_text=request["prompt_text"],
                                 timeout=settings["timeout"], capture_directory=attempt)
    # Retain output even when using a test provider without process capture.
    (attempt / "stdout.jsonl").write_text(stdout)
    (attempt / "stderr.txt").write_text(stderr)
    events = [json.loads(line) for line in stdout.splitlines() if line.strip()]
    tools = [e for e in events if e.get("item", {}).get("type") in
             ("command_execution", "mcp_tool_call", "web_search", "file_change")]
    if tools:
        raise ValueError("tool activity observed; annotation context isolation not satisfied")
    completed = [e for e in events if e.get("type") == "turn.completed"]
    if not completed:
        raise ValueError("provider did not report turn.completed")
    answer = read_json(attempt / "answer.json")
    jsonschema.validate(answer, request["output_schema"])
    return answer, completed[-1].get("usage")


def run_batch(manifest, output, *, codex="codex", resume=False):
    frozen = snapshot(manifest)
    fingerprint = digest(frozen)
    output = Path(output).resolve()
    if not resume:
        output.mkdir(parents=True, exist_ok=False)
    elif not output.is_dir():
        raise ValueError("resume directory not found")
    with run_lock(output):
        saved = output / "manifest.json"
        version, _ = execute([codex, "--version"], timeout=20)
        version = version.strip()
        code_sha256 = source_hashes()
        if resume:
            previous = read_json(saved)
            if previous["input_sha256"] != fingerprint or previous["codex"] != codex:
                raise ValueError("annotation inputs or provider changed; use a new run directory")
            if previous["codex_version"] != version:
                raise ValueError("annotation provider changed; use a new run directory")
            if previous["code_sha256"] != code_sha256:
                raise ValueError("annotation code changed; use a new run directory")
        else:
            atomic_json(saved, {"kind": "annotation", "input_sha256": fingerprint,
                "codex": codex, "codex_version": version, "created_at": time.time(),
                "code_sha256": code_sha256, "inputs": frozen})
        total = len(frozen["requests"])
        for index, request in enumerate(frozen["requests"], 1):
            record = output / "records" / (request["id"] + ".json")
            if record.exists() and read_json(record)["status"] == "completed":
                continue
            attempts = output / "attempts" / request["id"]
            attempts.mkdir(parents=True, exist_ok=True)
            number = max([int(p.name) for p in attempts.iterdir() if p.name.isdigit()] + [0]) + 1
            attempt = attempts / f"{number:03d}"
            attempt.mkdir()
            started = time.monotonic()
            progress = "=" * (index - 1) + "." * (total - index + 1)
            heartbeat(f"[{progress}] {index - 1}/{total} 주석: {request['id']}")
            atomic_json(output / "state.json", {"state": "running", "request_id": request["id"],
                        "attempt": number, "updated_at": time.time()})
            row = {"id": request["id"], "attempt": number, "status": "failed"}
            try:
                row["answer"], row["usage"] = annotate(request, frozen, attempt, codex)
                row["status"] = "completed"
            except KeyboardInterrupt:
                row["status"] = "interrupted"
                row["error"] = "interrupted; explicit resume required"
                raise
            except Exception as error:
                row["error"] = str(error)
            finally:
                row["elapsed_ms"] = round((time.monotonic() - started) * 1000, 2)
                atomic_json(attempt / "result.json", row)
                atomic_json(record, row)
                atomic_json(output / "state.json", {"state": row["status"],
                            "request_id": request["id"], "updated_at": time.time()})
            if row["status"] != "completed":
                break  # No silent repair, retries or model fallback.
        rows = [read_json(p) for p in (output / "records").glob("*.json")]
        count = sum(row["status"] == "completed" for row in rows)
        result = {"complete": count == total, "completed": count, "planned": total,
                  "semantic_accuracy": "UNVERIFIED", "output": str(output)}
        atomic_json(output / "summary.json", result)
        atomic_json(output / "state.json", {"state": "completed" if result["complete"] else "failed",
                                          "updated_at": time.time()})
        heartbeat(f"[{'=' * count}{'.' * (total-count)}] {count}/{total} 주석 저장")
        return result
