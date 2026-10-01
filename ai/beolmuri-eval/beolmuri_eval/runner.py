import json
from pathlib import Path
import time
import uuid
from . import process
from .config import SCOPE, digest, source_sha, repository
from .evaluation import load_plan, verify_snapshot
from .doctor import build, inspect_environment, swift_binary
from .judge import grade
from .metrics import summarize
from .comparison import compare
from .scenarios import execution_groups
from .seeds import sample_seeds, POLICY
from .plan_validation import validate_swift
from .checkpoints import validate_chains
from .process import Worker, heartbeat, execute
from .prompt_prepare import prepare_prompt
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
    validate_swift(plan)
    environment = inspect_environment(args.model, args.litert_python, args.codex, judge_settings=plan.judge)
    detail = check_environment(environment)
    cases = plan.cases
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + plan.variant + "-" + uuid.uuid4().hex[:8]
    output_root = getattr(args, "output_root", None)
    results = Path(output_root).expanduser().resolve() if output_root else root / "ai/beolmuri-eval/.artifacts/runs"
    directory = results / run_id
    directory.mkdir(parents=True)
    inputs = plan.snapshot(directory)
    if "retrieval" in plan.configuration:
        plan.configuration["retrieval"]["directory"] = str(directory / "inputs")
    commit = execute(["git", "rev-parse", "HEAD"], cwd=root)[0].strip()
    manifest = {
        "schema_version": 3, "run_id": run_id, "source_commit": commit, "source_sha256": source_sha(root),
        "variant": plan.variant, "configuration": plan.configuration, "scope": "multi-turn-fixed-general-retrieval-fixtures" if any("scenario_id" in c for c in cases) else ("single-turn-fixed-general-recalled-memory" if plan.memories else SCOPE),
        "input_files": inputs, "evaluation_config": plan.document,
        "history": plan.history, "history_sha256": digest(plan.history),
        "memories": plan.memories, "memories_sha256": digest(plan.memories),
        "cases": cases, "dataset_sha256": digest(cases), "repeats": plan.repeats,
        "seed_policy": POLICY, "base_seed": plan.document["run"].get("seed", 0),
        "model": detail["deployment_model"], "litert_python": detail["litert_python"],
        "runtime": {"version": detail["litert_native_library"]["version"],
                    "backend": detail["litert_native_library"]["backend"],
                    "speculative_decoding": False, "max_num_tokens": plan.max_num_tokens,
                    "mobile_parity": environment["runtime_parity"]},
        "judge": {**plan.judge,
                  "codex": args.codex, "cli_version": detail["codex_cli"],
                  "rubric_sha256": digest(plan.judge["rubric"]), "schema_sha256": digest(plan.judge["output_schema"])},
        "prompt_budget": plan.prompt_budget,
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
    planned_judgments = sum(c["kind"] != "dialogue" for c in manifest["cases"]) * manifest["repeats"]
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
            if manifest.get("schema_version", 2) >= 3:
                validate_chains(directory, manifest)
            with Worker([str(swift_binary(root))], directory / "swift.log") as swift:
                # Keep the engine loaded; each prompt rebuilds the native conversation from the shared Swift snapshot.
                with Worker([manifest["litert_python"], str(Path(__file__).with_name("native_worker.py"))], directory / "native.log") as native:
                    load = None
                    for repeat in range(manifest["repeats"]):
                        checkpoint = None
                        current_group = None
                        schedule = [(group, case) for group, cases in execution_groups(manifest["cases"]) for case in cases]
                        for group, case in schedule:
                            process.check_cancel()
                            if group != current_group:
                                checkpoint = None
                                current_group = group
                            key = f"{case['id']}-r{repeat}"
                            path = directory / "records" / (key + ".json")
                            record = read_json(path) if path.exists() else {
                                "key": key, "case": case, "repeat": repeat, "status": "pending", "attempts": []}
                            stateful = manifest.get("schema_version", 2) >= 3
                            if record['case'] != case or record['repeat'] != repeat or record['key'] != key:
                                raise ValueError("record identity conflicts with manifest")
                            before_hash = digest(checkpoint)
                            if stateful and 'generation' in record:
                                if record.get('session_before_sha256') != before_hash:
                                    raise ValueError("session checkpoint chain changed")
                                checkpoint = record['session_after']
                                if digest(checkpoint) != record.get('session_after_sha256'):
                                    raise ValueError("session checkpoint changed")
                            if record["status"] in ("graded", "completed"):
                                continue
                            done = sum(r['status'] in ('graded', 'completed') for r in records(directory))
                            filled = 20 * done // planned
                            heartbeat(f"{manifest['variant']} [{'█' * filled}{'░' * (20-filled)}] {done}/{planned} · {key}")
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
                                                           cache_dir=str(directory / "native-cache"),
                                                           max_num_tokens=manifest["runtime"]["max_num_tokens"])
                                        event(directory, "model_loaded", load_ms=load["load_ms"])
                                    seeds = sample_seeds(manifest.get('base_seed', 0), case['pair_id'], repeat,
                                                         case.get('turn_id', 'single')) if stateful else {'generation': repeat}
                                    record['seeds'] = seeds
                                    record['session_before_sha256'] = before_hash
                                    prepared = prepare_prompt(swift, native, configuration=manifest["configuration"],
                                        case=case, history=manifest.get("history", []), memories=manifest["memories"],
                                        max_num_tokens=manifest["runtime"]["max_num_tokens"],
                                        prompt_budget=manifest.get("prompt_budget"), timeout=timeout,
                                        session_checkpoint=checkpoint, world_info_seed=seeds.get("world_info_base"))
                                    record["input"] = prepared
                                    record["status"] = "prepared"
                                    atomic_json(path, record)
                                    native.call("start", system_prompt=prepared["system_prompt"],
                                                sampling=prepared["sampling"], seed=seeds["generation"],
                                                reserve_output=manifest.get("prompt_budget") is not None)
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
                                    if stateful:
                                        committed = swift.call('commit', configuration=manifest['configuration'],
                                            sessionCheckpoint=prepared['session_checkpoint'], userMessage=case['user_message'],
                                            assistantMessage=processed['visible_text'],
                                            worldInfoTransaction=prepared.get('world_info_transaction'))
                                        checkpoint = committed['session_checkpoint']
                                        record['session_after'] = checkpoint
                                        record['session_after_sha256'] = digest(checkpoint)
                                        record['seeds']['world_info_effective'] = prepared['world_info_seed']
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
                            if case['kind'] == 'dialogue':
                                record['status'] = 'completed'
                                atomic_json(path, record)
                                event(directory, 'warmup_completed', key=key)
                                continue
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
            summary = summarize(records(directory), planned, planned_judgments=planned_judgments)
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
