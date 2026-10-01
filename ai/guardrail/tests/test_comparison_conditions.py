from dataclasses import replace
from copy import deepcopy

import pytest

from petai_guardrail import runner
from petai_guardrail.common import GuardrailError, read_json, write_json
from test_resume import InterruptedRun, experiment, saved_files


load_reference = runner._load_baseline_reference


@pytest.fixture
def baseline(experiment, tmp_path, monkeypatch):
    config, prompt, _, server = experiment
    with pytest.raises(InterruptedRun):
        runner.run_baseline(config, "test")
    path = tmp_path / "runs" / "test"
    manifest = read_json(path / "manifest.json")
    manifest["status"] = "completed"
    write_json(path / "manifest.json", manifest)
    write_json(path / "metrics.json", {"garak": {"report": str(path / "responses.jsonl")}})
    monkeypatch.setattr(runner, "_load_baseline_reference", load_reference)
    server.reset_mock()
    return config, prompt, path, server


@pytest.mark.parametrize("change", ["limits", "judge", "runtime", "dataset", "output", "garak", "scorer", "normalization", "missing"])
def test_new_comparison_rejects_changed_conditions(baseline, tmp_path, monkeypatch, change):
    config, prompt, path, server = baseline
    if change == "limits":
        config = replace(config, limits={**config.limits, "xstest": 99})
    elif change == "judge":
        config = replace(config, qwen3guard={**config.qwen3guard, "max_new_tokens": 999})
    elif change == "runtime":
        monkeypatch.setattr(runner, "_runtime_version", lambda _: "runtime-b")
    elif change == "dataset":
        monkeypatch.setattr(runner, "verify_dataset_sources", lambda: {"hash": "dataset-b"})
    elif change == "output":
        prompt["maxOutputTokens"] = 999
    elif change == "garak":
        config = replace(config, garak={**config.garak, "generations": 99})
    elif change == "scorer":
        lock = deepcopy(runner.source_lock())
        lock["scorers"]["qwen3guard"]["revision"] = "different-revision"
        monkeypatch.setattr(runner, "source_lock", lambda: lock)
    elif change == "normalization":
        manifest = read_json(path / "manifest.json")
        manifest["evaluation_conditions"]["implementation"] = {"normalizer": "old"}
        write_json(path / "manifest.json", manifest)
    else:
        manifest = read_json(path / "manifest.json")
        manifest.pop("evaluation_conditions", None)
        write_json(path / "manifest.json", manifest)
    before = saved_files(tmp_path)
    with pytest.raises(GuardrailError, match="new baseline"):
        runner.run_comparison(config, "fresh-comparison", path)
    server.assert_not_called()
    assert saved_files(tmp_path) == before


def test_guard_and_location_changes_allow_comparison_and_resume(baseline):
    config, _, path, server = baseline
    config = replace(config, path=path / "moved-config.json",
                     target=replace(config.target, model_path=str(path / "moved-model"),
                                    base_url="http://127.0.0.1:9999/v1", port=9999),
                     input_guard=replace(config.input_guard, enabled=True,
                                         blocked_response="guard reply", max_length=512))
    for _ in range(2):
        with pytest.raises(InterruptedRun):
            runner.run_comparison(config, "fresh-comparison", path)
    assert server.call_count == 2
