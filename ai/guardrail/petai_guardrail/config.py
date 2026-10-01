from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .common import CONFIGS_ROOT, GuardrailError, read_json, require_mapping


@dataclass(frozen=True)
class TargetConfig:
    base_url: str
    host: str
    port: int
    model_spec: str
    model_registry_id: str
    model_artifact_id: str
    model_path: str
    litert_lm_cli: str
    expected_runtime_version: str
    ios_runtime_version: str
    temperature: float
    top_k: int
    top_p: float
    seeds: tuple[int, ...]
    timeout_seconds: float


@dataclass(frozen=True)
class InputGuardConfig:
    enabled: bool
    safe_label: str
    blocked_response: str
    max_length: int
    device: str


@dataclass(frozen=True)
class RunConfig:
    path: Path
    schema_version: str
    profile: str
    target: TargetConfig
    limits: dict[str, int | None]
    garak: dict[str, Any]
    qwen3guard: dict[str, Any]
    input_guard: InputGuardConfig


def default_config_path(profile: str) -> Path:
    if profile not in {"smoke", "baseline"}:
        raise GuardrailError(f"Unsupported profile: {profile}")
    return CONFIGS_ROOT / f"{profile}.v1.json"


def load_config(path: Path) -> RunConfig:
    raw = require_mapping(read_json(path), "config")
    if raw.get("schema_version") != "1.0.0":
        raise GuardrailError("Config schema_version must be 1.0.0.")
    profile = raw.get("profile")
    if profile not in {"smoke", "baseline"}:
        raise GuardrailError("Config profile must be smoke or baseline.")
    target_raw = require_mapping(raw.get("target"), "config.target")
    seeds = target_raw.get("seeds")
    if (
        not isinstance(seeds, list)
        or not seeds
        or not all(isinstance(seed, int) for seed in seeds)
    ):
        raise GuardrailError("target.seeds must be a non-empty integer array.")
    target = TargetConfig(
        base_url=str(target_raw["base_url"]).rstrip("/"),
        host=str(target_raw["host"]),
        port=int(target_raw["port"]),
        model_spec=str(target_raw["model_spec"]),
        model_registry_id=str(target_raw["model_registry_id"]),
        model_artifact_id=str(target_raw["model_artifact_id"]),
        model_path=str(target_raw["model_path"]),
        litert_lm_cli=str(target_raw["litert_lm_cli"]),
        expected_runtime_version=str(target_raw["expected_runtime_version"]),
        ios_runtime_version=str(target_raw["ios_runtime_version"]),
        temperature=float(target_raw["temperature"]),
        top_k=int(target_raw["top_k"]),
        top_p=float(target_raw["top_p"]),
        seeds=tuple(seeds),
        timeout_seconds=float(target_raw["timeout_seconds"]),
    )
    if target.top_k <= 0 or not 0 <= target.top_p <= 1:
        raise GuardrailError("Invalid target sampling configuration.")
    limits = require_mapping(raw.get("limits"), "config.limits")
    expected_limit_keys = {"multijail", "xstest", "garak_prompt_cap"}
    if set(limits) != expected_limit_keys:
        raise GuardrailError(
            f"config.limits must contain exactly {sorted(expected_limit_keys)}."
        )
    for key, value in limits.items():
        if value is not None and (not isinstance(value, int) or value <= 0):
            raise GuardrailError(f"limits.{key} must be null or a positive integer.")
    input_guard_raw = require_mapping(raw.get("input_guard"), "config.input_guard")
    input_guard = InputGuardConfig(
        enabled=bool(input_guard_raw.get("enabled", False)),
        safe_label=str(input_guard_raw["safe_label"]),
        blocked_response=str(input_guard_raw["blocked_response"]),
        max_length=int(input_guard_raw["max_length"]),
        device=str(input_guard_raw["device"]),
    )
    if not input_guard.safe_label or not input_guard.blocked_response:
        raise GuardrailError("input_guard labels and response must not be empty.")
    if input_guard.max_length <= 0:
        raise GuardrailError("input_guard.max_length must be positive.")
    return RunConfig(
        path=path.resolve(),
        schema_version="1.0.0",
        profile=profile,
        target=target,
        limits=dict(limits),
        garak=require_mapping(raw.get("garak"), "config.garak"),
        qwen3guard=require_mapping(raw.get("qwen3guard"), "config.qwen3guard"),
        input_guard=input_guard,
    )
