from __future__ import annotations

import subprocess
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .common import (
    ARTIFACTS_ROOT,
    GuardrailError,
    canonical_json,
    expand_path,
    git_evidence,
    read_json,
    sha256_file,
    sha256_text,
    utc_now,
    write_json,
)
from .config import RunConfig
from .comparison_conditions import evaluation_conditions
from .contracts import validate_manifest, validate_static_contracts
from .datasets import load_multijail, load_xstest
from .garak_runner import compare_garak_from_reference, run_garak
from .generation import generate_cases
from .input_guard import GuardedTarget, KoreanBertInputGuard
from .litert_target import LiteRTTarget
from .metrics import summarize
from .prompt_adapter import prompt_snapshot
from .qwen_judge import score_responses
from .report import render_report
from .server import ensure_server
from .sources import (
    fetch_datasets,
    fetch_input_guard,
    fetch_qwen3guard,
    source_lock,
    verify_dataset_sources,
)

COMPARISON_METRICS = (
    "unsafe_response_rate",
    "controversial_response_rate",
    "strict_risk_rate",
    "harmful_refusal_rate",
    "safe_over_refusal_rate",
    "empty_response_rate",
    "invalid_header_rate",
    "generation_error_rate",
    "scoring_error_rate",
)


def _runtime_version(cli: str) -> str:
    result = subprocess.run(
        [str(expand_path(cli)), "--version"],
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def _check_resume(
    run_dir: Path,
    config: RunConfig,
    prompt: dict[str, Any],
    manifest: dict[str, Any],
    reference: dict[str, Any] | None = None,
) -> None:
    # Compare before the first run-directory write: row IDs alone do not
    # establish that cached responses or judgments belong to this experiment.
    settings = asdict(config)
    settings.pop("path")  # Moving the config file does not change its contents.
    inputs = {
        "config": settings,
        "prompt": prompt,
        "target": dict(manifest["target"]),
        "sources": manifest["sources"],
        "comparison": manifest.get("comparison"),
        "reference": reference,
        "evaluation_conditions": manifest.get("evaluation_conditions"),
    }
    fingerprint = sha256_text(canonical_json(inputs))
    path = run_dir / "manifest.json"
    if path.exists():
        previous = read_json(path)
        if previous.get("inputs_sha256") != fingerprint:
            raise GuardrailError(
                "Run inputs changed or cannot be verified; use a new run ID."
            )
    elif any(run_dir.iterdir()):
        raise GuardrailError(
            "Existing outputs have no manifest; use a new run ID."
        )
    manifest["inputs_sha256"] = fingerprint
    manifest["inputs"] = inputs


def run_baseline(config: RunConfig, run_id: str) -> Path:
    validate_static_contracts()
    run_dir = ARTIFACTS_ROOT / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    started_at = utc_now()
    prompt = prompt_snapshot()
    datasets = fetch_datasets()
    model_path = expand_path(config.target.model_path)
    registry = read_json(
        Path(__file__).resolve().parents[3] / "ai/models/runtime-models.json"
    )
    artifact = next(
        item
        for item in registry["artifacts"]
        if item["id"] == config.target.model_artifact_id
    )
    if sha256_file(model_path) != artifact["sha256"]:
        raise GuardrailError(
            "Deployment model hash does not match runtime-models.json."
        )

    manifest: dict[str, Any] = {
        "benchmark_id": "petai-guardrail-baseline",
        "benchmark_version": "1.0.0",
        "run_id": run_id,
        "profile": config.profile,
        "status": "failed",
        "git": git_evidence(),
        "target": {
            "model_spec": config.target.model_spec,
            "model_path": str(model_path),
            "model_sha256": artifact["sha256"],
            "runtime_version": _runtime_version(config.target.litert_lm_cli),
            "ios_runtime_version": config.target.ios_runtime_version,
            "sampling": {
                "temperature": config.target.temperature,
                "top_k": config.target.top_k,
                "top_p": config.target.top_p,
                "seeds": list(config.target.seeds),
            },
        },
        "prompt": {
            "configuration_id": prompt["configurationID"],
            "sha256": sha256_text(prompt["systemPrompt"]),
            "condition": "GENERAL-empty-context",
        },
        "sources": {
            "lock": source_lock(),
            "datasets": verify_dataset_sources(),
        },
        "started_at": started_at,
        "ended_at": started_at,
        "outputs": {},
    }
    manifest["evaluation_conditions"] = evaluation_conditions(
        config, prompt, artifact["sha256"],
        manifest["target"]["runtime_version"], manifest["sources"],
    )
    _check_resume(run_dir, config, prompt, manifest)
    write_json(run_dir / "manifest.json", manifest)
    try:
        cases = [
            *load_multijail(datasets["multijail"], config.limits["multijail"]),
            *load_xstest(datasets["xstest"], config.limits["xstest"]),
        ]
        with ensure_server(config.target, run_dir) as managed:
            target = LiteRTTarget(config.target, prompt["systemPrompt"])
            try:
                results = generate_cases(
                    target,
                    cases,
                    config.target.seeds,
                    run_dir / "responses.jsonl",
                )
                garak = run_garak(config, prompt["systemPrompt"], run_dir)
            finally:
                target.close()
            manifest["target"]["server_owned_by_run"] = managed.owned

        qwen_path = fetch_qwen3guard()
        qwen = config.qwen3guard
        judgments = score_responses(
            results,
            qwen_path,
            run_dir / "judgments.jsonl",
            int(qwen["batch_size"]),
            int(qwen["max_new_tokens"]),
            str(qwen["device"]),
        )
        metrics = summarize(results, judgments)
        metrics["garak"] = garak
        write_json(run_dir / "metrics.json", metrics)
        manifest["status"] = "completed"
        manifest["outputs"] = {
            "responses": "responses.jsonl",
            "judgments": "judgments.jsonl",
            "metrics": "metrics.json",
            "report": "report.md",
        }
    finally:
        manifest["ended_at"] = utc_now()
        write_json(run_dir / "manifest.json", manifest)
        validate_manifest(manifest)
    (run_dir / "report.md").write_text(render_report(run_dir), encoding="utf-8")
    return run_dir


def _load_baseline_reference(
    path: Path,
    config: RunConfig,
    prompt_sha256: str,
    model_sha256: str,
    conditions: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = read_json(path / "manifest.json")
    if manifest.get("status") != "completed":
        raise GuardrailError("The baseline reference is not completed.")
    previous = manifest.get("evaluation_conditions")
    if not isinstance(previous, dict) or canonical_json(previous) != canonical_json(conditions):
        raise GuardrailError(
            "Baseline evaluation conditions differ or lack evidence; "
            "create a new baseline with the same evaluation conditions."
        )
    if manifest.get("profile") != config.profile:
        raise GuardrailError("The baseline reference profile does not match.")
    if manifest.get("prompt", {}).get("sha256") != prompt_sha256:
        raise GuardrailError("The baseline reference prompt does not match.")
    if manifest.get("target", {}).get("model_sha256") != model_sha256:
        raise GuardrailError("The baseline reference model does not match.")
    expected_sampling = {
        "temperature": config.target.temperature,
        "top_k": config.target.top_k,
        "top_p": config.target.top_p,
        "seeds": list(config.target.seeds),
    }
    if manifest.get("target", {}).get("sampling") != expected_sampling:
        raise GuardrailError("The baseline reference sampling does not match.")
    return manifest, read_json(path / "metrics.json")


def _comparison_delta(
    baseline: dict[str, Any], guarded: dict[str, Any]
) -> dict[str, float | None]:
    delta: dict[str, float | None] = {}
    for key in COMPARISON_METRICS:
        before = baseline[key].get("rate")
        after = guarded[key].get("rate")
        delta[key] = None if before is None or after is None else after - before
    before_garak = baseline.get("garak", {})
    after_garak = guarded.get("garak", {})
    for key in ("injection_attack_success_rate", "system_prompt_leak_rate"):
        before = before_garak.get(key, {}).get("rate")
        after = after_garak.get(key, {}).get("rate")
        delta[f"garak.{key}"] = (
            None if before is None or after is None else after - before
        )
    return delta


def run_comparison(
    config: RunConfig,
    run_id: str,
    baseline_reference: Path,
) -> Path:
    validate_static_contracts()
    run_dir = ARTIFACTS_ROOT / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    started_at = utc_now()
    prompt = prompt_snapshot()
    datasets = fetch_datasets()
    model_path = expand_path(config.target.model_path)
    registry = read_json(
        Path(__file__).resolve().parents[3] / "ai/models/runtime-models.json"
    )
    artifact = next(
        item
        for item in registry["artifacts"]
        if item["id"] == config.target.model_artifact_id
    )
    if sha256_file(model_path) != artifact["sha256"]:
        raise GuardrailError(
            "Deployment model hash does not match runtime-models.json."
        )
    prompt_hash = sha256_text(prompt["systemPrompt"])
    runtime_version = _runtime_version(config.target.litert_lm_cli)
    sources = {"lock": source_lock(), "datasets": verify_dataset_sources()}
    conditions = evaluation_conditions(
        config, prompt, artifact["sha256"], runtime_version, sources,
    )
    baseline_manifest, baseline_metrics = _load_baseline_reference(
        baseline_reference.resolve(), config, prompt_hash, artifact["sha256"], conditions
    )
    guard_path = fetch_input_guard()
    guard_weights = guard_path / "model.safetensors"
    if not guard_weights.is_file():
        raise GuardrailError("The Korean input guard weights are missing.")
    guard_record = source_lock()["candidate_guards"]["guardrail-ko-11class"]

    manifest: dict[str, Any] = {
        "benchmark_id": "petai-guardrail-baseline",
        "benchmark_version": "1.0.0",
        "run_id": run_id,
        "profile": config.profile,
        "status": "failed",
        "git": git_evidence(),
        "target": {
            "model_spec": config.target.model_spec,
            "model_path": str(model_path),
            "model_sha256": artifact["sha256"],
            "runtime_version": runtime_version,
            "ios_runtime_version": config.target.ios_runtime_version,
            "sampling": {
                "temperature": config.target.temperature,
                "top_k": config.target.top_k,
                "top_p": config.target.top_p,
                "seeds": list(config.target.seeds),
            },
        },
        "prompt": {
            "configuration_id": prompt["configurationID"],
            "sha256": prompt_hash,
            "condition": "GENERAL-empty-context",
        },
        "sources": sources,
        "evaluation_conditions": conditions,
        "comparison": {
            "baseline_run_id": baseline_manifest["run_id"],
            "baseline_path": str(baseline_reference.resolve()),
            "guard": {
                "model_id": guard_record["model_id"],
                "revision": guard_record["revision"],
                "license": guard_record["license"],
                "weights_sha256": sha256_file(guard_weights),
                "safe_label": config.input_guard.safe_label,
                "policy": "argmax SAFE allows; every other label blocks",
            },
        },
        "started_at": started_at,
        "ended_at": started_at,
        "outputs": {},
    }
    _check_resume(
        run_dir, config, prompt, manifest,
        reference={
            "manifest": baseline_manifest,
            "metrics": baseline_metrics,
            "garak_sha256": sha256_file(Path(baseline_metrics["garak"]["report"])),
        },
    )
    write_json(run_dir / "manifest.json", manifest)
    try:
        cases = [
            *load_multijail(datasets["multijail"], config.limits["multijail"]),
            *load_xstest(datasets["xstest"], config.limits["xstest"]),
        ]
        guarded_dir = run_dir / "guarded"
        with ensure_server(config.target, run_dir) as managed:
            target = LiteRTTarget(config.target, prompt["systemPrompt"])
            guard = KoreanBertInputGuard(config.input_guard, guard_path)
            try:
                guarded_target = GuardedTarget(
                    target, guard, config.input_guard.blocked_response
                )
                guarded_results = generate_cases(
                    guarded_target,
                    cases,
                    config.target.seeds,
                    guarded_dir / "responses.jsonl",
                )
                baseline_garak_report = Path(
                    baseline_metrics["garak"]["report"]
                ).resolve()
                guarded_garak = compare_garak_from_reference(
                    config,
                    prompt["systemPrompt"],
                    baseline_garak_report,
                    guarded_dir,
                    guard,
                )
            finally:
                guard.close()
                target.close()
            manifest["target"]["server_owned_by_run"] = managed.owned

        qwen_path = fetch_qwen3guard()
        qwen = config.qwen3guard
        guarded_judgments = score_responses(
            guarded_results,
            qwen_path,
            guarded_dir / "judgments.jsonl",
            int(qwen["batch_size"]),
            int(qwen["max_new_tokens"]),
            str(qwen["device"]),
        )
        guarded_metrics = summarize(guarded_results, guarded_judgments)
        guarded_metrics["garak"] = guarded_garak
        write_json(guarded_dir / "metrics.json", guarded_metrics)
        comparison = {
            "baseline": baseline_metrics,
            "guarded": guarded_metrics,
            "delta": _comparison_delta(baseline_metrics, guarded_metrics),
        }
        write_json(run_dir / "metrics.json", comparison)
        manifest["status"] = "completed"
        manifest["outputs"] = {
            "guarded_responses": "guarded/responses.jsonl",
            "guarded_judgments": "guarded/judgments.jsonl",
            "guarded_metrics": "guarded/metrics.json",
            "comparison_metrics": "metrics.json",
            "report": "report.md",
        }
    finally:
        manifest["ended_at"] = utc_now()
        write_json(run_dir / "manifest.json", manifest)
        validate_manifest(manifest)
    from .report import render_comparison_report

    (run_dir / "report.md").write_text(
        render_comparison_report(run_dir), encoding="utf-8"
    )
    return run_dir
