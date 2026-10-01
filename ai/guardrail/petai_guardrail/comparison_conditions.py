from dataclasses import asdict
from typing import Any

from .common import PROJECT_ROOT, REPOSITORY_ROOT, sha256_file
from .config import RunConfig


def evaluation_conditions(
    config: RunConfig, prompt: dict[str, Any], model_sha256: str,
    runtime_version: str, sources: dict[str, Any],
) -> dict[str, Any]:
    # Guard policy is the experimental variable. Paths and run metadata are not
    # evaluation conditions; compare the content identities instead.
    target = asdict(config.target)
    target = {key: target[key] for key in (
        "model_spec", "expected_runtime_version", "ios_runtime_version",
        "temperature", "top_k", "top_p", "seeds", "timeout_seconds",
    )}
    code_paths = [
        PROJECT_ROOT / "petai_guardrail" / name for name in (
            "datasets.py", "generation.py", "litert_target.py", "server.py",
            "prompt_adapter.py", "qwen_judge.py", "garak_runner.py", "metrics.py",
        )
    ] + [
        PROJECT_ROOT / "uv.lock",
        PROJECT_ROOT / "contracts/benchmark.v1.json",
        PROJECT_ROOT / "swift/ProductPromptAdapter/Sources/ProductAdapterCore/ProductAdapterCore.swift",
        PROJECT_ROOT / "swift/ProductPromptAdapter/Sources/ProductPromptAdapter/main.swift",
        REPOSITORY_ROOT / "ios/EdgeLLM/Sources/EdgeLLM/Memory/MemoryTaggedChat.swift",
    ]
    datasets = {
        name: {key: value for key, value in evidence.items() if key != "path"}
        if isinstance(evidence, dict) else evidence
        for name, evidence in sources["datasets"].items()
    }
    return {
        "version": 1,
        "profile": config.profile,
        "limits": config.limits,
        "target": target,
        "model_sha256": model_sha256,
        "runtime_version": runtime_version,
        "prompt": prompt,
        "datasets": datasets,
        "dataset_sources": sources["lock"]["datasets"],
        "scorers": sources["lock"]["scorers"],
        "qwen3guard": config.qwen3guard,
        "garak": config.garak,
        "implementation": {
            str(path.relative_to(REPOSITORY_ROOT)): sha256_file(path)
            for path in code_paths
        },
    }
