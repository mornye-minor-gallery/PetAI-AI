import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from beolmuri_eval.resource.inference import (
    preflight,
    recover_active_owner,
    resume_inference_run,
    run_inference_one,
)
from beolmuri_eval.resource.protocol import sha256
from resource_fixture import RUN, OWNER, app_files
from test_resource_protocol import CONFIG


class FakeInferenceDevice:
    identifier = "synthetic"
    bundle = "com.example.resourcebench"

    def __init__(self, *, fail_collection_once=False):
        self.commands = []
        self.files = app_files()
        self.phase = "boot_ready"
        self.tick = 0
        self.fail_collection_once = fail_collection_once
        self.terminated = False

    def copy_to(self, path, destination, timeout=300):
        if "/commands/" in destination:
            value = json.loads(Path(path).read_text())
            operation = value["operation"]
            self.commands.append(operation)
            self.phase = {"prepare": "ready", "begin": "finished", "cancel": "cancelled"}[operation]
            self.files["receipts/" + value["operation_id"] + ".json"] = json.dumps({
                "digest": sha256(Path(path).read_bytes()), "status": "completed"
            }).encode()

    def copy_from(self, source, destination, timeout=60):
        if self.fail_collection_once and source.endswith("artifacts.json"):
            self.fail_collection_once = False
            raise RuntimeError("transport interrupted")
        tail = source.split("/" + RUN + "/")[1]
        Path(destination).write_bytes(self.files[tail])

    def launch(self, run_id):
        return {"processIdentifier": 4242}

    def processes(self):
        rows = [] if self.terminated else [{"processIdentifier": 4242, "executable": "/app/Example.app/Example"}]
        return {"runningProcesses": rows}

    def state(self, run_id):
        self.tick += 1
        return dict(run_id=RUN, owner_id=OWNER, process_instance_id="one", phase=self.phase,
                    pid=4242, revision=self.tick, heartbeat_seq=self.tick,
                    build_id="build", bundle_id=self.bundle)

    def terminate_owned(self, state):
        self.terminated = True
        return {"termination": "confirmed"}


def inference_plan():
    return dict(schema_version=1, run_id=RUN, owner_id=OWNER, role="work",
                measurement_mode="inference", config=dict(CONFIG, scenario="fixed"),
                model={"path": "models/" + "a" * 64 + ".litertlm", "sha256": "a" * 64},
                generation={"context_tokens": 4096, "max_output_tokens": 32,
                            "temperature": 0.7, "top_k": 40, "top_p": 1,
                            "thinking_enabled": False, "conversation_mode": "fresh_per_input"},
                inputs=[{"id": "turn", "system_prompt": "system", "user_prompt": "user"}])


class InferenceLifecycleTests(unittest.TestCase):
    def test_inference_run_never_constructs_power_recorder(self):
        with tempfile.TemporaryDirectory() as temporary, patch(
            "beolmuri_eval.resource.runner.Recorder", side_effect=AssertionError("power recorder used")
        ):
            root = Path(temporary) / RUN
            result = run_inference_one(root, inference_plan(), FakeInferenceDevice(), "build",
                                       progress=lambda **kw: None)
            self.assertTrue(result["complete"], result)
            self.assertEqual(result["stage"], "closed")
            summary = json.loads((root / "analyses" / result["analysis_id"] / "summary.json").read_text())
            self.assertEqual(summary["power"]["mean"]["status"], "not_requested")

    def test_finished_device_run_can_resume_collection_without_rerunning_inference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / RUN
            device = FakeInferenceDevice(fail_collection_once=True)
            first = run_inference_one(root, inference_plan(), device, "build", progress=lambda **kw: None)
            self.assertFalse(first["complete"])
            self.assertEqual(first["stage"], "device_finished")
            self.assertEqual(device.commands, ["prepare", "begin"])
            resumed = resume_inference_run(root, device, progress=lambda **kw: None)
            self.assertTrue(resumed["complete"], resumed)
            self.assertEqual(resumed["stage"], "closed")
            self.assertEqual(device.commands, ["prepare", "begin"])


class PreflightTests(unittest.TestCase):
    def test_preflight_rejects_locked_device_before_model_or_launch_work(self):
        class Locked:
            def lock_state(self): return {"passcodeRequired": True}
        with self.assertRaisesRegex(RuntimeError, "device_locked"):
            preflight(Locked(), expected_bundle="com.example.resourcebench", progress=lambda **kw: None)

    def test_preflight_requires_a_successful_filesandbox_roundtrip(self):
        class Ready:
            def lock_state(self): return {"passcodeRequired": False}
            def details(self): return {"connectionProperties": {"transportType": "localNetwork"}}
            def apps(self): return {"apps": [{"bundleIdentifier": "com.example.resourcebench"}]}
            def probe_transport(self): raise RuntimeError("filesandbox unavailable")
        with self.assertRaisesRegex(RuntimeError, "filesandbox unavailable"):
            preflight(Ready(), expected_bundle="com.example.resourcebench", progress=lambda **kw: None)


class RecoveryTests(unittest.TestCase):
    def test_absent_benchmark_process_closes_stale_owner_without_device_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            run = base / "run"; run.mkdir()
            (run / "manifest.json").write_text(json.dumps(inference_plan()))
            active = base / "active.json"
            active.write_text(json.dumps({"directory": str(run), "termination_confirmed": False}))
            class Absent:
                bundle = "com.example.resourcebench"
                def state(self, run_id): raise RuntimeError("state unavailable")
                def running_app_processes(self): return []
            result = recover_active_owner(active, Absent(), progress=lambda **kw: None)
            self.assertEqual(result["resolution"], "process_absent")
            self.assertTrue(json.loads(active.read_text())["termination_confirmed"])


if __name__ == "__main__":
    unittest.main()
