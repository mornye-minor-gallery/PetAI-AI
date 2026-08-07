from __future__ import annotations

import json
import platform
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .common import (
    CONTRACTS_DIR,
    REPO_ROOT,
    FacetRouteBenchError,
    parse_unique_route,
    read_json,
    read_jsonl,
    render_router_input,
    require_file,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import (
    load_benchmark_contract,
    load_route_contract,
    validate_record_schema,
    validate_record_semantics,
)
from .evaluation import classification_metrics
from .manifests import git_commit, write_validated_manifest


@dataclass(frozen=True)
class Generation:
    text: str
    elapsed_ms: float
    first_output_ms: float | None


def _verify_gemma_artifact(model_path: Path) -> dict[str, Any]:
    registry = read_json(REPO_ROOT / "ai/models/runtime-models.json")
    expected = next(
        item for item in registry["artifacts"] if item["id"] == "gemma-e2b-it"
    )
    resolved = require_file(model_path, "Gemma LiteRT-LM artifact")
    if resolved.stat().st_size != expected["bytes"]:
        raise FacetRouteBenchError("Gemma artifact byte length does not match registry")
    if sha256_file(resolved) != expected["sha256"]:
        raise FacetRouteBenchError("Gemma artifact SHA-256 does not match registry")
    return expected


class DirectLiteRTRouter:
    def __init__(
        self,
        *,
        model_path: Path,
        backend: str,
        max_num_tokens: int,
    ) -> None:
        try:
            import litert_lm
        except ImportError as error:
            raise FacetRouteBenchError(
                "LiteRT-LM Python package is missing. Run with the Python interpreter "
                "inside the installed litert-lm uv tool."
            ) from error
        backend_value = {
            "cpu": litert_lm.Backend.CPU,
            "gpu": litert_lm.Backend.GPU,
        }.get(backend)
        if backend_value is None:
            raise FacetRouteBenchError(f"unsupported LiteRT-LM backend: {backend}")
        started = time.perf_counter()
        self._context = litert_lm.Engine(
            str(model_path),
            backend=backend_value(),
            max_num_tokens=max_num_tokens,
        )
        self._engine = self._context.__enter__()
        self._sampler = litert_lm.SamplerConfig(temperature=0.0, top_p=1.0)
        self.load_elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

    def generate(self, system_prompt: str, user_message: str) -> Generation:
        chunks: list[str] = []
        first_output: float | None = None
        started = time.perf_counter()
        with self._engine.create_conversation(
            messages=[{"role": "system", "content": system_prompt}],
            extra_context={"enable_thinking": False},
            filter_channel_content_from_kv_cache=True,
            sampler_config=self._sampler,
        ) as conversation:
            for chunk in conversation.send_message_async(user_message):
                for item in chunk.get("content", []):
                    if item.get("type") == "text" and item.get("text"):
                        if first_output is None:
                            first_output = time.perf_counter()
                        chunks.append(item["text"])
        ended = time.perf_counter()
        return Generation(
            text="".join(chunks),
            elapsed_ms=round((ended - started) * 1000, 3),
            first_output_ms=(
                round((first_output - started) * 1000, 3)
                if first_output is not None
                else None
            ),
        )

    def close(self) -> None:
        self._context.__exit__(None, None, None)


def run_gemma_router(
    *,
    dataset_path: Path,
    model_path: Path,
    prompt_path: Path,
    config_path: Path,
    output_dir: Path,
    backend: str,
    max_num_tokens: int,
    runtime_version: str,
    include_history: bool,
    runtime_mode: str,
    repeats: int,
    run_kind: str,
    workers: int,
    runtime_python: Path | None,
) -> Path:
    if runtime_mode not in {"warm", "cold"}:
        raise FacetRouteBenchError("runtime_mode must be warm or cold")
    if repeats < 1:
        raise FacetRouteBenchError("repeats must be positive")
    if run_kind not in {"quality", "latency"}:
        raise FacetRouteBenchError("run_kind must be quality or latency")
    if workers < 1:
        raise FacetRouteBenchError("workers must be positive")
    if workers > 1:
        if runtime_python is None:
            raise FacetRouteBenchError(
                "parallel Gemma runs require --runtime-python pointing to the "
                "LiteRT-LM Python interpreter"
            )
        runtime_python = runtime_python.expanduser().absolute()
        if not runtime_python.is_file():
            raise FacetRouteBenchError(
                f"LiteRT-LM Python interpreter was not found: {runtime_python}"
            )
    run_commit = git_commit()
    expected_model = _verify_gemma_artifact(model_path)
    config = read_json(config_path)
    expected_config = {
        "candidate_id": "gemma-generative-router-v14",
        "router_family": "gemma_generative",
        "temperature": 0.0,
        "top_p": 1.0,
        "thinking_enabled": False,
        "invalid_or_multiple_route_fallback": "GENERAL",
        "maximum_history_turns": 6,
    }
    if any(config.get(key) != value for key, value in expected_config.items()):
        raise FacetRouteBenchError("Gemma config violates the locked router contract")
    route_contract = load_route_contract()
    route_ids = route_contract["route_order"]
    prompt_path = require_file(prompt_path, "Gemma scene router prompt")
    configured_prompt = (config_path.parent / config["system_prompt"]).resolve()
    if configured_prompt != prompt_path.resolve():
        raise FacetRouteBenchError(
            "Gemma prompt does not match configured system_prompt"
        )
    if sha256_file(prompt_path) != route_contract["source"]["router_sha256"]:
        raise FacetRouteBenchError(
            "scene router prompt SHA does not match route contract"
        )
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    records = read_jsonl(dataset_path)
    if not records:
        raise FacetRouteBenchError("Gemma runner requires a non-empty dataset")
    for record in records:
        validate_record_schema(record)
        validate_record_semantics(record)
    if run_kind == "quality":
        expected_counts = {"dev": 696, "frozen": 696, "context_challenge": 60}
        splits = {record["split"] for record in records}
        if len(splits) != 1 or next(iter(splits)) not in expected_counts:
            raise FacetRouteBenchError(
                "quality run requires one complete evaluation split"
            )
        split = next(iter(splits))
        if len(records) != expected_counts[split]:
            raise FacetRouteBenchError(
                f"quality run requires {expected_counts[split]} {split} records"
            )
    request = {
        "schema_version": "facetroutebench-gemma-request-v1",
        "git_commit": run_commit,
        "dataset_sha256": sha256_file(dataset_path),
        "model_sha256": sha256_file(model_path),
        "prompt_sha256": sha256_file(prompt_path),
        "config_sha256": sha256_file(config_path),
        "backend": backend,
        "max_num_tokens": max_num_tokens,
        "runtime_version": runtime_version,
        "include_history": include_history,
        "runtime_mode": runtime_mode,
        "repeats": repeats,
        "run_kind": run_kind,
        "workers": workers,
        "runtime_python": str(runtime_python) if runtime_python else None,
    }
    request_path = output_dir / "run_request.json"
    predictions_path = output_dir / "predictions.jsonl"
    if output_dir.exists():
        if (output_dir / "run_manifest.json").exists():
            raise FacetRouteBenchError(f"run is already complete: {output_dir}")
        if not request_path.is_file():
            raise FacetRouteBenchError("Gemma output has no resumable run request")
        checkpoint = read_json(request_path)
        if checkpoint.get("request") != request:
            raise FacetRouteBenchError(
                "Gemma checkpoint request does not match this run"
            )
        started_at = checkpoint["started_at"]
        results = read_jsonl(predictions_path) if predictions_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        started_at = utc_now()
        results = []
        write_json(request_path, {"started_at": started_at, "request": request})
    processed = {(item["repeat"], item["case_id"]) for item in results}
    if len(processed) != len(results):
        raise FacetRouteBenchError("Gemma checkpoint repeats a case/repeat pair")
    expected_pairs = {
        (repeat, record["case_id"])
        for repeat in range(1, repeats + 1)
        for record in records
    }
    if not processed <= expected_pairs:
        raise FacetRouteBenchError("Gemma checkpoint belongs to another dataset")
    if workers > 1:
        worker_dir = output_dir / ".workers"
        worker_dir.mkdir(parents=True, exist_ok=True)
        record_order = {
            record["case_id"]: index for index, record in enumerate(records)
        }
        all_tasks = [
            {
                "case_id": record["case_id"],
                "repeat": repeat,
                "router_input": render_router_input(
                    record["messages"], include_history=include_history
                ),
            }
            for repeat in range(1, repeats + 1)
            for record in records
        ]
        worker_outputs = [
            worker_dir / f"worker-{index:02d}.jsonl" for index in range(workers)
        ]
        checkpoint_results = list(results)
        for path in worker_outputs:
            if path.is_file():
                checkpoint_results.extend(read_jsonl(path))
        checkpoint_keys = [
            (item["repeat"], item["case_id"]) for item in checkpoint_results
        ]
        if len(checkpoint_keys) != len(set(checkpoint_keys)):
            raise FacetRouteBenchError("parallel Gemma checkpoints contain duplicates")
        completed = set(checkpoint_keys)
        worker_script = Path(__file__).with_name("litert_worker.py")
        processes: list[tuple[subprocess.Popen[bytes], Any, Any]] = []
        try:
            for index in range(workers):
                tasks_path = worker_dir / f"worker-{index:02d}.tasks.jsonl"
                tasks = [
                    task
                    for position, task in enumerate(all_tasks)
                    if position % workers == index
                    and (task["repeat"], task["case_id"]) not in completed
                ]
                write_jsonl(tasks_path, tasks, overwrite=tasks_path.exists())
                if not tasks:
                    continue
                stdout = (worker_dir / f"worker-{index:02d}.stdout.log").open("a")
                stderr = (worker_dir / f"worker-{index:02d}.stderr.log").open("a")
                command = [
                    str(runtime_python),
                    str(worker_script),
                    "--tasks",
                    str(tasks_path),
                    "--output",
                    str(worker_outputs[index]),
                    "--model",
                    str(model_path),
                    "--prompt",
                    str(prompt_path),
                    "--route-ids",
                    json.dumps(route_ids),
                    "--backend",
                    backend,
                    "--max-num-tokens",
                    str(max_num_tokens),
                    "--runtime-mode",
                    runtime_mode,
                ]
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
                processes.append((process, stdout, stderr))
            while processes and any(
                process.poll() is None for process, _, _ in processes
            ):
                finished = len(results)
                for path in worker_outputs:
                    if path.is_file():
                        with path.open(encoding="utf-8") as handle:
                            finished += sum(1 for line in handle if line.strip())
                print(
                    f"parallel Gemma progress: {finished}/{len(all_tasks)}",
                    flush=True,
                )
                time.sleep(1)
        except BaseException:
            for process, _, _ in processes:
                if process.poll() is None:
                    process.terminate()
            raise
        finally:
            for process, stdout, stderr in processes:
                process.wait()
                stdout.close()
                stderr.close()
        failures = [
            process.returncode for process, _, _ in processes if process.returncode
        ]
        if failures:
            raise FacetRouteBenchError(
                f"parallel Gemma worker failure(s): {failures}; inspect {worker_dir}"
            )
        results = list(checkpoint_results)
        existing_keys = {(item["repeat"], item["case_id"]) for item in results}
        for path in worker_outputs:
            if not path.is_file():
                continue
            for item in read_jsonl(path):
                key = (item["repeat"], item["case_id"])
                if key not in existing_keys:
                    results.append(item)
                    existing_keys.add(key)
        results.sort(key=lambda item: (item["repeat"], record_order[item["case_id"]]))
    else:
        shared: DirectLiteRTRouter | None = None
        try:
            if runtime_mode == "warm":
                shared = DirectLiteRTRouter(
                    model_path=model_path,
                    backend=backend,
                    max_num_tokens=max_num_tokens,
                )
            for repeat in range(1, repeats + 1):
                for index, record in enumerate(records, start=1):
                    if (repeat, record["case_id"]) in processed:
                        continue
                    runtime = shared or DirectLiteRTRouter(
                        model_path=model_path,
                        backend=backend,
                        max_num_tokens=max_num_tokens,
                    )
                    error_text: str | None = None
                    raw_text = ""
                    generation = Generation("", 0.0, None)
                    try:
                        router_input = render_router_input(
                            record["messages"], include_history=include_history
                        )
                        generation = runtime.generate(system_prompt, router_input)
                        raw_text = generation.text
                        predicted = parse_unique_route(raw_text, route_ids) or "GENERAL"
                    except Exception as error:  # noqa: BLE001 - mirrors app fallback
                        predicted = "GENERAL"
                        error_text = f"{type(error).__name__}: {error}"
                    finally:
                        if shared is None:
                            runtime.close()
                    results.append(
                        {
                            "case_id": record["case_id"],
                            "repeat": repeat,
                            "predicted_route_id": predicted,
                            "raw_output": raw_text,
                            "error": error_text,
                            "model_load_elapsed_ms": runtime.load_elapsed_ms,
                            "route_elapsed_ms": generation.elapsed_ms,
                            "first_output_elapsed_ms": generation.first_output_ms,
                        }
                    )
                    if len(results) % 10 == 0:
                        write_jsonl(predictions_path, results, overwrite=True)
                    if index == 1 or index % 50 == 0:
                        print(
                            f"repeat {repeat}/{repeats}: routed {index}/{len(records)}",
                            flush=True,
                        )
        finally:
            if shared is not None:
                shared.close()
    if {(item["repeat"], item["case_id"]) for item in results} != expected_pairs:
        raise FacetRouteBenchError("Gemma run ended without every expected prediction")
    write_jsonl(predictions_path, results, overwrite=predictions_path.exists())
    metrics_by_repeat = []
    for repeat in range(1, repeats + 1):
        repeat_predictions = [item for item in results if item["repeat"] == repeat]
        metrics_by_repeat.append(
            {
                "repeat": repeat,
                "metrics": classification_metrics(records, repeat_predictions),
            }
        )
    result_summary = {
        "schema_version": "facetroutebench-gemma-router-result-v1",
        "records": len(records),
        "repeats": repeats,
        "errors": sum(item["error"] is not None for item in results),
        "timeouts": sum(
            "timeout" in str(item.get("error", "")).lower() for item in results
        ),
        "error_rate": sum(item["error"] is not None for item in results) / len(results),
        "timeout_rate": sum(
            "timeout" in str(item.get("error", "")).lower() for item in results
        )
        / len(results),
        "runtime_mode": runtime_mode,
        "include_history": include_history,
        "predictions": predictions_path.name,
        "predictions_sha256": sha256_file(predictions_path),
        "quality_by_repeat": metrics_by_repeat,
    }
    result_path = output_dir / "result.json"
    write_json(result_path, result_summary, overwrite=result_path.exists())
    manifest = {
        "benchmark_id": "facetroutebench",
        "benchmark_version": load_benchmark_contract()["benchmark_version"],
        "run_id": output_dir.name,
        "status": "completed",
        "git_commit": run_commit,
        "started_at": started_at,
        "ended_at": utc_now(),
        "track": (
            "router_latency"
            if run_kind == "latency"
            else (
                "context_challenge"
                if records[0]["split"] == "context_challenge"
                else (
                    "product_condition" if include_history else "controlled_single_turn"
                )
            )
        ),
        "candidate": {
            "candidate_id": "gemma-generative-router-v14",
            "router_family": "gemma_generative",
            "config_path": str(config_path.resolve()),
            "config_sha256": sha256_file(config_path),
        },
        "dataset": {
            "path": str(dataset_path.resolve()),
            "version": records[0]["dataset_version"],
            "record_count": len(records),
            "sha256": sha256_file(dataset_path),
        },
        "contracts": [
            {
                "path": str(CONTRACTS_DIR / "routes.v1.json"),
                "sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
            },
            {
                "path": str(CONTRACTS_DIR / "benchmark.v1.json"),
                "sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
            },
        ],
        "models": [
            {
                "role": "router",
                "model_id": expected_model["repository"],
                "artifact_sha256": sha256_file(model_path),
                "checkpoint_lineage": expected_model["revision"],
                "quantization": "deployment-litertlm-registry-artifact",
            }
        ],
        "runtime": {
            "name": "LiteRT-LM",
            "version": runtime_version,
            "backend": backend,
        },
        "hardware": {
            "platform": "macos",
            "device_model": platform.machine(),
            "os_version": platform.mac_ver()[0] or platform.platform(),
        },
        "result": {
            "path": str(result_path.resolve()),
            "sha256": sha256_file(result_path),
        },
        "notes": (
            f"thinking=false; runtime_mode={runtime_mode}; repeats={repeats}; "
            f"include_history={include_history}; workers={workers}"
        ),
    }
    return write_validated_manifest(output_dir / "run_manifest.json", manifest)
