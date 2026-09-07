import json
from pathlib import Path
import time
import uuid
from . import process
from .config import SCOPE, digest, source_sha, repository
from .evaluation import load_plan, verify_snapshot
from .doctor import build, inspect_environment, swift_binary
from .judge import grade
from .metrics import summarize, compare_results
from .process import Worker, heartbeat, execute
from .storage import atomic_json, read_json, records, run_lock, event


def check_environment(environment):
    if not environment["ready"]:
        failed = [item["name"] + ": " + str(item["detail"]) for item in environment["checks"] if item["status"] == "fail"]
        raise RuntimeError("doctor failed: " + "; ".join(failed))
    return {item["name"]: item["detail"] for item in environment["checks"]}


def create_run(args):
    root = repository()
    plan = load_plan(args.config, variant=args.variant, repeats=args.repeats,
                     limit_pairs=args.limit_pairs, timeout=args.timeout)
    build(root)
    environment = inspect_environment(args.model, args.litert_python, args.codex, judge_settings=plan.judge)
    detail = check_environment(environment)
    cases = plan.cases
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + plan.variant + "-" + uuid.uuid4().hex[:8]
    directory = root / "ai/beolmuri-eval/.artifacts/runs" / run_id
    directory.mkdir(parents=True)
    inputs = plan.snapshot(directory)
    commit = execute(["git", "rev-parse", "HEAD"], cwd=root)[0].strip()
    manifest = {
        "schema_version": 2, "run_id": run_id, "source_commit": commit, "source_sha256": source_sha(root),
        "variant": plan.variant, "configuration": plan.configuration, "scope": SCOPE,
        "input_files": inputs, "evaluation_config": plan.document,
        "cases": cases, "dataset_sha256": digest(cases), "repeats": plan.repeats,
        "seed_policy": "repeat-index; paired inputs use the same seed; bitwise reproducibility not claimed",
        "model": detail["deployment_model"], "litert_python": detail["litert_python"],
        "runtime": {"version": detail["litert_native_library"]["version"],
                    "backend": detail["litert_native_library"]["backend"],
                    "speculative_decoding": False, "kv_capacity": "artifact default",
                    "mobile_parity": environment["runtime_parity"]},
        "judge": {**plan.judge,
                  "codex": args.codex, "cli_version": detail["codex_cli"],
                  "rubric_sha256": digest(plan.judge["rubric"]), "schema_sha256": digest(plan.judge["output_schema"])},
        "timeout_seconds": plan.timeout_seconds,
        "data_policy": "synthetic suite only; user-approved remote Codex judging; local results retained until removed",
    }
    atomic_json(directory / "manifest.json", manifest)
    return directory


def validate_resume(manifest, root):
    if manifest["source_sha256"] != source_sha(root):
        raise ValueError("execution source/dependencies changed: start a new run instead of mixing checkpoints")
    environment = inspect_environment(manifest["model"]["path"], manifest["litert_python"],
                                      manifest["judge"]["codex"], judge_settings=manifest["judge"])
    detail = check_environment(environment)
    if detail["codex_cli"] != manifest["judge"]["cli_version"]:
        raise ValueError("Codex CLI changed: start a new run")
    if detail["litert_native_library"]["version"] != manifest["runtime"]["version"]:
        raise ValueError("LiteRT-LM changed: start a new run")


def run(directory, resume=False):
    root = repository()
    directory = Path(directory).resolve()
    manifest = read_json(directory / "manifest.json")
    timeout = manifest["timeout_seconds"]
    planned = len(manifest["cases"]) * manifest["repeats"]
    with run_lock(directory):
        cancellation = directory / "cancel.request"
        cancellation.unlink(missing_ok=True)
        process.CANCEL_FILE = cancellation
        atomic_json(directory / "state.json", {"state": "running", "run_id": manifest["run_id"]})
        event(directory, "run_started", resumed=resume)
        try:
            if resume:
                verify_snapshot(directory, manifest["input_files"])
                validate_resume(manifest, root)
            process.check_cancel()
            with Worker([str(swift_binary(root))], directory / "swift.log") as swift:
                # Keep one model loaded for all independent single-turn sessions.
                with Worker([manifest["litert_python"], str(Path(__file__).with_name("native_worker.py"))], directory / "native.log") as native:
                    load = None
                    for repeat in range(manifest["repeats"]):
                        for case in manifest["cases"]:
                            key = f"{case['id']}-r{repeat}"
                            path = directory / "records" / (key + ".json")
                            record = read_json(path) if path.exists() else {
                                "key": key, "case": case, "repeat": repeat, "status": "pending", "attempts": []}
                            if record["status"] == "graded":
                                continue
                            heartbeat(f"{manifest['variant']} {len([r for r in records(directory) if r['status']=='graded'])}/{planned} · {key}")
                            if "generation" not in record:
                                try:
                                    if "primary" in record:
                                        record["attempts"].append({"stage": "incomplete_generation_restarted",
                                                                   "primary": record.pop("primary"),
                                                                   "time": time.time()})
                                        atomic_json(path, record)
                                    if load is None:
                                        load = native.call("load", timeout=max(timeout, 180),
                                                           model=manifest["model"]["path"],
                                                           cache_dir=str(directory / "native-cache"))
                                        event(directory, "model_loaded", load_ms=load["load_ms"])
                                    prepared = swift.call("prepare", configuration=manifest["configuration"],
                                                          characterName=case["character_name"], userMessage=case["user_message"])
                                    record["input"] = prepared
                                    record["status"] = "prepared"
                                    atomic_json(path, record)
                                    native.call("start", system_prompt=prepared["system_prompt"],
                                                sampling=prepared["sampling"], seed=repeat)
                                    primary = native.call("generate", message=prepared["user_prompt"], timeout=timeout)
                                    # Save raw generation before parsing or requesting any retry.
                                    record["primary"] = primary
                                    atomic_json(path, record)
                                    processed = swift.call("process", configuration=manifest["configuration"],
                                                           primaryChunks=primary["chunks"])
                                    retry = None
                                    if processed["status"] == "retry_required":
                                        event(directory, "answer_retry", key=key)
                                        record["retry_prompt"] = processed["retry_prompt"]
                                        retry = native.call("generate", message=processed["retry_prompt"], timeout=timeout)
                                        processed = swift.call("process", configuration=manifest["configuration"],
                                                               primaryChunks=primary["chunks"], retryChunks=retry["chunks"])
                                    record["generation"] = {"primary": primary, "retry": retry, "processed": processed}
                                    record["status"] = "generated"
                                    atomic_json(path, record)
                                    event(directory, "generation_completed", key=key)
                                except Exception as error:
                                    record["status"] = "generation_error"
                                    record["attempts"].append({"stage": "generation", "error": str(error), "time": time.time()})
                                    atomic_json(path, record)
                                    # A crashed/timed-out native worker cannot safely handle the next case.
                                    raise
                            try:
                                judgment, invocation = grade(case, record["generation"]["processed"]["visible_text"],
                                                             codex=manifest["judge"]["codex"], timeout=timeout, settings=manifest["judge"])
                                record["judgment"] = judgment
                                record["judge_invocation"] = invocation
                                record["status"] = "graded"
                            except Exception as error:
                                record["status"] = "judge_error"
                                record["attempts"].append({"stage": "judge", "error": str(error), "time": time.time()})
                            atomic_json(path, record)
                            event(directory, record["status"], key=key)
            summary = summarize(records(directory), planned)
            atomic_json(directory / "summary.json", summary)
            atomic_json(directory / "state.json", {"state": "completed" if summary["complete"] else "incomplete"})
            event(directory, "run_finished", complete=summary["complete"])
            return summary
        except BaseException as error:
            atomic_json(directory / "state.json", {"state": "interrupted" if isinstance(error, KeyboardInterrupt) else "failed",
                                                    "error": str(error)})
            event(directory, "run_stopped", error=type(error).__name__)
            raise
        finally:
            process.CANCEL_FILE = None


def compare(left, right):
    first, second = read_json(left / "manifest.json"), read_json(right / "manifest.json")
    for key in ("dataset_sha256", "repeats", "seed_policy", "scope", "runtime", "judge"):
        if first[key] != second[key]:
            raise ValueError(f"comparison mismatch: {key}")
    if first["model"]["sha256"] != second["model"]["sha256"]:
        raise ValueError("comparison model differs")
    a, b = records(left), records(right)
    by_key = {row["key"]: row for row in b}
    for previous in a:
        current = by_key.get(previous["key"])
        if current is None:
            raise ValueError("comparison result keys differ")
        for field in ("sampling", "user_prompt"):
            if previous.get("input", {}).get(field) != current.get("input", {}).get(field):
                raise ValueError(f"comparison input differs: {field}")
    planned = len(first["cases"]) * first["repeats"]
    summaries = [summarize(rows, planned) for rows in (a, b)]
    if not all(summary["complete"] for summary in summaries):
        raise ValueError("comparison requires all scheduled cases to be graded")
    deltas = {label: round(summaries[1]["wrong_name"][label] - summaries[0]["wrong_name"][label], 3)
              for label in summaries[0]["wrong_name"] if label.endswith("_pct")}
    return {"baseline": first["run_id"], "candidate": second["run_id"],
            "wrong_name_delta_percentage_points": deltas,
            "control_correction_delta_percentage_points": round(summaries[1]["correct_name"]["incorrect_correction_pct"] - summaries[0]["correct_name"]["incorrect_correction_pct"], 3),
            "paired": compare_results(a, b), "summaries": summaries,
            "same_source": first["source_sha256"] == second["source_sha256"]}
