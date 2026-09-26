from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock

import pytest

from petai_guardrail import runner
from petai_guardrail.common import GuardrailError
from petai_guardrail.config import default_config_path, load_config


class InterruptedRun(RuntimeError):
    pass


@pytest.fixture
def experiment(tmp_path, monkeypatch):
    config = load_config(default_config_path("smoke"))
    prompt = {"configurationID": "test", "systemPrompt": "prompt A",
              "maxOutputTokens": 128, "thinkingEnabled": False}
    monkeypatch.setattr(runner, "ARTIFACTS_ROOT", tmp_path)
    monkeypatch.setattr(runner, "prompt_snapshot", lambda: dict(prompt))
    monkeypatch.setattr(runner, "fetch_datasets", lambda: {"multijail": tmp_path, "xstest": tmp_path})
    monkeypatch.setattr(runner, "verify_dataset_sources", lambda: {"hash": "dataset-a"})
    monkeypatch.setattr(runner, "git_evidence", lambda: {})
    monkeypatch.setattr(runner, "_runtime_version", lambda _: "runtime-a")
    registry = runner.read_json(Path(runner.__file__).resolve().parents[3] / "ai/models/runtime-models.json")
    artifact = next(a for a in registry["artifacts"] if a["id"] == config.target.model_artifact_id)
    monkeypatch.setattr(runner, "sha256_file", lambda _: artifact["sha256"])
    monkeypatch.setattr(runner, "load_multijail", lambda *_: [])
    monkeypatch.setattr(runner, "load_xstest", lambda *_: [])
    (tmp_path / "model.safetensors").touch()
    monkeypatch.setattr(runner, "fetch_input_guard", lambda: tmp_path)
    reference = tmp_path / "reference"
    reference.mkdir()
    for name in ("manifest.json", "metrics.json", "report.jsonl"):
        (reference / name).write_text("{}")
    monkeypatch.setattr(runner, "_load_baseline_reference", lambda *_: (
        {"run_id": "reference"}, {"garak": {"report": str(reference / "report.jsonl")}}))
    def interrupt(*_):
        (tmp_path / "runs" / "test" / "responses.jsonl").write_text("saved response")
        raise InterruptedRun()
    server = Mock(side_effect=interrupt)
    monkeypatch.setattr(runner, "ensure_server", server)
    return config, prompt, reference, server


def invoke(mode, config, reference):
    if mode == "baseline":
        return runner.run_baseline(config, "test")
    return runner.run_comparison(config, "test", reference)


def saved_files(root):
    return {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}


@pytest.mark.parametrize("mode", ["baseline", "comparison"])
@pytest.mark.parametrize("change", ["prompt", "sampling", "limits", "judge", "guard", "output", "runtime", "dataset"])
def test_changed_inputs_rejected_without_writing(experiment, tmp_path, monkeypatch, mode, change):
    config, prompt, reference, server = experiment
    with pytest.raises(InterruptedRun):
        invoke(mode, config, reference)
    before = saved_files(tmp_path / "runs")
    if change == "prompt":
        prompt["systemPrompt"] = "prompt B"
    elif change == "sampling":
        config = replace(config, target=replace(config.target, temperature=0.13))
    elif change == "limits":
        config = replace(config, limits={**config.limits, "xstest": 99})
    elif change == "judge":
        config = replace(config, qwen3guard={**config.qwen3guard, "max_new_tokens": 999})
    elif change == "guard":
        config = replace(config, input_guard=replace(config.input_guard, blocked_response="changed"))
    elif change == "output":
        prompt["maxOutputTokens"] = 999
    elif change == "runtime":
        monkeypatch.setattr(runner, "_runtime_version", lambda _: "runtime-b")
    elif change == "dataset":
        monkeypatch.setattr(runner, "verify_dataset_sources", lambda: {"hash": "dataset-b"})
    with pytest.raises(GuardrailError, match="new run ID"):
        invoke(mode, config, reference)
    assert server.call_count == 1
    assert saved_files(tmp_path / "runs") == before


@pytest.mark.parametrize("mode", ["baseline", "comparison"])
def test_same_inputs_resume(experiment, mode):
    config, _, reference, server = experiment
    for _ in range(2):
        with pytest.raises(InterruptedRun):
            invoke(mode, config, reference)
    assert server.call_count == 2


@pytest.mark.parametrize("mode", ["baseline", "comparison"])
def test_unidentified_outputs_are_preserved(experiment, tmp_path, mode):
    config, _, reference, server = experiment
    run_dir = tmp_path / "runs" / "test"
    run_dir.mkdir(parents=True)
    (run_dir / "responses.jsonl").write_text("old output")
    before = saved_files(run_dir)
    with pytest.raises(GuardrailError, match="new run ID"):
        invoke(mode, config, reference)
    assert server.call_count == 0
    assert saved_files(run_dir) == before


@pytest.mark.parametrize("mode", ["baseline", "comparison"])
def test_old_manifest_without_fingerprint_is_preserved(experiment, tmp_path, mode):
    config, _, reference, server = experiment
    run_dir = tmp_path / "runs" / "test"
    run_dir.mkdir(parents=True)
    (run_dir / "manifest.json").write_text('{"status": "completed"}')
    before = saved_files(run_dir)
    with pytest.raises(GuardrailError, match="new run ID"):
        invoke(mode, config, reference)
    assert server.call_count == 0
    assert saved_files(run_dir) == before


def test_baseline_cannot_be_resumed_as_comparison(experiment, tmp_path):
    config, _, reference, server = experiment
    with pytest.raises(InterruptedRun):
        invoke("baseline", config, reference)
    before = saved_files(tmp_path / "runs")
    with pytest.raises(GuardrailError, match="new run ID"):
        invoke("comparison", config, reference)
    assert server.call_count == 1
    assert saved_files(tmp_path / "runs") == before


def test_changed_comparison_reference_is_rejected(experiment, tmp_path, monkeypatch):
    config, _, reference, server = experiment
    with pytest.raises(InterruptedRun):
        invoke("comparison", config, reference)
    before = saved_files(tmp_path / "runs")
    monkeypatch.setattr(runner, "_load_baseline_reference", lambda *_: (
        {"run_id": "different"}, {"garak": {"report": str(reference / "report.jsonl")}}))
    with pytest.raises(GuardrailError, match="new run ID"):
        invoke("comparison", config, reference)
    assert server.call_count == 1
    assert saved_files(tmp_path / "runs") == before
