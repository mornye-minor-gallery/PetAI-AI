"""Fast, resumable on-device inference measurements without power capture."""
from copy import deepcopy
from pathlib import Path
import json
import plistlib
import time
from uuid import uuid4

from ..config import repository
from ..storage import atomic_json, read_json, run_lock
from .device import Device, ROOT
from .observation import Observation
from .plan import inputs_from_config, manifest, verify_model
from .protocol import sha256
from .runner import collect_run, launch_process_id, send_command, wait_phase
from .summary import save_summary


TERMINAL_DEVICE_PHASES = {"finished", "failed", "cancelled"}


class InferenceProgress:
    """Human-readable lifecycle updates with heartbeats for long operations."""
    def __init__(self):
        self.stage = None
        self.last = 0.0

    def __call__(self, **value):
        # devicectl details remain in tool artifacts. The console reports the
        # lifecycle checkpoint that tells an operator what happens next.
        if value.get("stage") == "tool":
            return
        now = time.monotonic()
        if value.get("stage") == self.stage and now - self.last < 5:
            return
        completed = value.get("completed_bytes")
        total = value.get("total_bytes")
        if isinstance(completed, int) and isinstance(total, int) and total > 0:
            filled = min(20, int(20 * completed / total))
            value["progress_bar"] = "[" + "#" * filled + "-" * (20 - filled) + "]"
        import sys

        print(json.dumps(value, ensure_ascii=False), file=sys.stderr, flush=True)
        self.stage = value.get("stage")
        self.last = now


def _control(root, stage, **details):
    value = {
        "schema_version": 1,
        "run_id": read_json(Path(root) / "manifest.json")["run_id"],
        "stage": stage,
        "updated_at_unix_seconds": time.time(),
        **details,
    }
    atomic_json(Path(root) / "control-state.json", value)
    return value


def _terminate_terminal(device, state):
    """Stop only the process proven to own the completed device run."""
    if state["phase"] not in TERMINAL_DEVICE_PHASES:
        raise RuntimeError("device run is not terminal")
    rows = device.processes().get("runningProcesses")
    if not isinstance(rows, list):
        raise RuntimeError("process inventory format unverified")
    if not any(row.get("processIdentifier") == state["pid"] for row in rows):
        return device.terminate_owned(state)
    observed = state
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        current = device.state(state["run_id"].lower())
        if current["heartbeat_seq"] > observed["heartbeat_seq"]:
            break
        time.sleep(1)
    return device.terminate_owned(observed)


def preflight(device, *, expected_bundle, progress):
    """Prove the control channel works before hashing or launching anything."""
    progress(stage="preflight", check="device_lock")
    lock = device.lock_state()
    if lock.get("passcodeRequired") is not False:
        raise RuntimeError("device_locked: unlock the phone and keep its screen awake")
    progress(stage="preflight", check="device_details")
    details = device.details()
    progress(stage="preflight", check="installed_app")
    apps = device.apps()
    if not any(row.get("bundleIdentifier") == expected_bundle for row in apps.get("apps", [])):
        raise RuntimeError("benchmark_app_missing: install the matching ResourceBench app")
    progress(stage="preflight", check="filesandbox_roundtrip")
    transport = device.probe_transport()
    return {"lock": lock, "details": details, "apps": apps, "transport": transport}


def recover_active_owner(active_path, device, *, progress):
    """Resolve an unconfirmed previous owner from authoritative device evidence."""
    active_path = Path(active_path)
    if not active_path.exists():
        return {"resolution": "no_active_owner"}
    owner = read_json(active_path)
    if owner.get("termination_confirmed") is True:
        return {"resolution": "already_confirmed"}
    root = Path(owner["directory"])
    plan = read_json(root / "manifest.json")
    progress(stage="recover", run_id=plan["run_id"])
    try:
        state = device.state(plan["run_id"])
    except Exception as state_error:
        processes = device.running_app_processes()
        if processes:
            raise RuntimeError(
                "active_owner_unresolved: device state is unavailable while benchmark process is running"
            ) from state_error
        resolution = {"resolution": "process_absent", "state_error": str(state_error)}
    else:
        if state["phase"] not in TERMINAL_DEVICE_PHASES:
            observer = Observation(run_id=plan["run_id"], owner_id=plan["owner_id"])
            command = send_command(device, root, plan, state, "cancel")
            state = wait_phase(
                device,
                root,
                plan,
                TERMINAL_DEVICE_PHASES,
                timeout=30,
                observer=observer,
                progress=progress,
            )
            resolution = {"resolution": "cancelled", "operation_id": command["operation_id"]}
        else:
            resolution = {"resolution": "terminal_state"}
        resolution["termination"] = _terminate_terminal(device, state)
    atomic_json(root / "reconciliation.json", resolution)
    atomic_json(active_path, {**owner, "termination_confirmed": True, "reconciliation": resolution})
    return resolution


def _final_result(root, *, complete, stage, reason=None, analysis=None, termination=False):
    result = {
        "run_id": read_json(Path(root) / "manifest.json")["run_id"],
        "directory": str(Path(root)),
        "complete": complete,
        "stage": stage,
        "termination_confirmed": termination,
        "reason": reason,
    }
    if analysis is not None:
        result["analysis"] = str(analysis)
        result["analysis_id"] = Path(analysis).name
    return result


def _collect_analyze_close(root, device, *, progress):
    root = Path(root)
    plan = read_json(root / "manifest.json")
    control = read_json(root / "control-state.json")
    if control["stage"] == "device_finished":
        progress(stage="collect", run_id=plan["run_id"])
        state = collect_run(root, device)
        _control(root, "collected")
        control = read_json(root / "control-state.json")
    else:
        state = read_json(root / "device-state-final.json")
    if control["stage"] == "collected":
        progress(stage="analyze", run_id=plan["run_id"])
        summary, analysis = save_summary(root)
        if not summary["complete"]:
            raise RuntimeError("required inference evidence invalid: " + "; ".join(summary["reasons"]))
        _control(root, "analyzed", analysis_id=analysis.name)
    elif control["stage"] == "analyzed":
        analysis = root / "analyses" / control["analysis_id"]
    else:
        raise RuntimeError("post-processing requires device_finished, collected or analyzed state")
    termination = _terminate_terminal(device, state)
    atomic_json(root / "termination.json", {"confirmed": True, **termination})
    _control(root, "closed", analysis_id=analysis.name, termination_confirmed=True)
    return _final_result(root, complete=True, stage="closed", analysis=analysis, termination=True)


def run_inference_one(root, plan, device, expected_build, *, progress, model_source=None):
    """Run one exact-turn inference measurement and preserve resumable checkpoints."""
    root = Path(root)
    root.mkdir(parents=True)
    atomic_json(root / "manifest.json", plan)
    atomic_json(
        root / "transport.json",
        {"device": device.identifier, "bundle": device.bundle, "expected_build_id": expected_build},
    )
    _control(root, "created")
    observer = Observation(run_id=plan["run_id"], owner_id=plan["owner_id"])
    launched = False
    last = None
    with run_lock(root):
        try:
            progress(stage="launch", run_id=plan["run_id"])
            device.copy_to(root / "manifest.json", f"{ROOT}/runs/{plan['run_id']}/manifest.json")
            launched = True
            launch = device.launch(plan["run_id"])
            atomic_json(root / "launch.json", launch)
            last = wait_phase(
                device,
                root,
                plan,
                {"boot_ready"},
                timeout=60,
                observer=observer,
                progress=progress,
                expected_pid=launch_process_id(launch),
            )
            if last.get("build_id") != expected_build or last.get("bundle_id") != device.bundle:
                raise RuntimeError("installed benchmark build does not match expected build identity")
            _control(root, "app_ready")
            if model_source is not None:
                progress(stage="model_upload", run_id=plan["run_id"])
                device.copy_to(
                    model_source,
                    f"{ROOT}/{plan['model']['path']}",
                    timeout=plan["config"]["prepare_timeout_ms"] / 1000,
                )
            send_command(device, root, plan, last, "prepare")
            last = wait_phase(
                device,
                root,
                plan,
                {"ready"},
                timeout=plan["config"]["prepare_timeout_ms"] / 1000 + 10,
                observer=observer,
                progress=progress,
            )
            _control(root, "running")
            send_command(device, root, plan, last, "begin")
            last = wait_phase(
                device,
                root,
                plan,
                {"finished"},
                timeout=(plan["config"]["turn_timeout_ms"] * len(plan["inputs"])) / 1000 + 30,
                observer=observer,
                progress=progress,
            )
            _control(root, "device_finished", completed_turns=last.get("completed_turns"))
            return _collect_analyze_close(root, device, progress=progress)
        except (Exception, KeyboardInterrupt) as error:
            reason = str(error) or type(error).__name__
            control = read_json(root / "control-state.json")
            if control["stage"] in {"device_finished", "collected", "analyzed"}:
                atomic_json(root / "postprocess-error.json", {"stage": control["stage"], "error": reason})
                termination = False
                try:
                    if last is None:
                        last = device.state(plan["run_id"])
                    _terminate_terminal(device, last)
                    termination = True
                except Exception as termination_error:
                    atomic_json(root / "termination-error.json", {"error": str(termination_error)})
                _control(
                    root,
                    control["stage"],
                    postprocess_error=reason,
                    termination_confirmed=termination,
                    next_action="resource resume",
                )
                return _final_result(
                    root,
                    complete=False,
                    stage=control["stage"],
                    reason=reason,
                    termination=termination,
                )
            atomic_json(root / "failure.json", {"reason": reason})
            if launched:
                try:
                    last = device.state(plan["run_id"])
                    if last["phase"] not in TERMINAL_DEVICE_PHASES:
                        send_command(device, root, plan, last, "cancel")
                        last = wait_phase(
                            device,
                            root,
                            plan,
                            TERMINAL_DEVICE_PHASES,
                            timeout=30,
                            observer=observer,
                            progress=progress,
                        )
                    _terminate_terminal(device, last)
                except Exception as reconciliation_error:
                    atomic_json(root / "reconciliation-error.json", {"error": str(reconciliation_error)})
            _control(root, "failed", reason=reason)
            return _final_result(root, complete=False, stage="failed", reason=reason)


def resume_inference_run(root, device, *, progress):
    """Resume collection only; never send prepare or begin again."""
    root = Path(root)
    with run_lock(root):
        control = read_json(root / "control-state.json")
        if control["stage"] == "closed":
            analysis_id = control["analysis_id"]
            return _final_result(
                root,
                complete=True,
                stage="closed",
                analysis=root / "analyses" / analysis_id,
                termination=True,
            )
        if control["stage"] not in {"device_finished", "collected", "analyzed"}:
            raise RuntimeError("resume requires an authoritative post-inference checkpoint")
        return _collect_analyze_close(root, device, progress=progress)


def run_inference_batch(
    config_path,
    *,
    device_id,
    app_path,
    model_preinstalled=False,
    modes=("fresh_per_input",),
    canonical_content=None,
    dialogue_turns=None,
):
    """Preflight once, then run one exact-turn experiment for each cache mode."""
    config, paths, model, model_path, generation, rows = inputs_from_config(config_path)
    if (canonical_content is None) != (dialogue_turns is None):
        raise ValueError("canonical content and dialogue turns must be provided together")
    app = Path(app_path).resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    build_id = info.get("ResourceBenchBuildID")
    if not build_id or info["CFBundleIdentifier"] != config["bundle_id"]:
        raise ValueError("a matching benchmark .app is required")
    base = repository() / "ai/beolmuri-eval/.artifacts/resource-runs"
    batch = base / str(uuid4())
    batch.mkdir(parents=True)
    provenance = None
    if canonical_content is not None:
        from .dialogue_fixture import load_dialogue_fixture

        rows, provenance = load_dialogue_fixture(
            canonical_content, dialogue_turns, log_path=batch / "swift-composer.log"
        )
    owner = str(uuid4())

    progress = InferenceProgress()
    device = Device(device_id, config["bundle_id"], batch / "device", progress=progress)
    evidence = preflight(device, expected_bundle=config["bundle_id"], progress=progress)
    details = evidence["details"]
    atomic_json(batch / "preflight.json", evidence)
    canonical = details.get("hardwareProperties", {}).get("udid")
    if not canonical:
        raise RuntimeError("canonical hardware device identity unavailable")
    device.identifier = canonical
    device_directory = base.parent / "resource-devices" / sha256(canonical.lower().encode())
    device_directory.mkdir(parents=True, exist_ok=True)
    active = device_directory / "active.json"
    with run_lock(device_directory):
        recover_active_owner(active, device, progress=progress)
        atomic_json(batch / "state.json", {"complete": False, "stage": "model_verification"})
        verify_model(model_path, model["sha256"], progress=progress)
        atomic_json(batch / "state.json", {"complete": False, "stage": "model_verified"})
        snapshots = batch / "inputs"
        snapshots.mkdir()
        for key, path in paths.items():
            (snapshots / (key + path.suffix)).write_bytes(path.read_bytes())
        (snapshots / "prepared-fixture.jsonl").write_text(
            "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
        )
        if provenance is not None:
            atomic_json(snapshots / "prompt-provenance.json", provenance)
        fixed_config = deepcopy(config)
        fixed_config["scenario"] = "fixed"
        atomic_json(
            batch / "inputs.json",
            {
                "config": fixed_config,
                "files": {key: sha256(path.read_bytes()) for key, path in paths.items()},
                "build_id": build_id,
                "backend": "cpu",
                "model_preinstalled": model_preinstalled,
                "provenance": provenance,
            },
        )
        results = []
        for mode in modes:
            if mode not in {"fresh_per_input", "cached_full_prompt"}:
                raise ValueError("unsupported inference conversation mode")
            selected_generation = deepcopy(generation)
            selected_generation["conversation_mode"] = mode
            plan = manifest(
                fixed_config,
                model,
                selected_generation,
                rows,
                role="work",
                owner_id=owner,
                measurement_mode="inference",
            )
            folder = batch / plan["run_id"]
            atomic_json(
                active,
                {"owner_id": owner, "directory": str(folder), "termination_confirmed": False},
            )
            progress(stage="batch", mode=mode, completed_runs=len(results), planned_runs=len(modes))
            result = run_inference_one(
                folder,
                plan,
                device,
                build_id,
                progress=progress,
                model_source=model_path if not results and not model_preinstalled else None,
            )
            results.append(result)
            atomic_json(
                active,
                {
                    "owner_id": owner,
                    "directory": str(folder),
                    "termination_confirmed": result["termination_confirmed"],
                },
            )
            atomic_json(batch / "state.json", {"complete": False, "stage": "running", "results": results})
            if not result["complete"]:
                atomic_json(batch / "state.json", {"complete": False, "stage": "failed", "results": results})
                return {"batch": str(batch), "complete": False, "results": results}
        atomic_json(batch / "state.json", {"complete": True, "stage": "closed", "results": results})
        return {"batch": str(batch), "complete": True, "results": results}
