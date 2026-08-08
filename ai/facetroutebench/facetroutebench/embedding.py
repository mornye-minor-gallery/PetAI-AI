from __future__ import annotations

import importlib.metadata
import math
import platform
import time
from pathlib import Path
from typing import Any

from .common import (
    CONTRACTS_DIR,
    REPO_ROOT,
    FacetRouteBenchError,
    final_user_text,
    read_json,
    read_jsonl,
    require_file,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import (
    load_benchmark_contract,
    load_route_contract,
    validate_dataset_counts,
    validate_record_schema,
    validate_record_semantics,
)
from .manifests import git_commit

MODEL_ID = "litert-community/embeddinggemma-300m-seq256-mixed-precision"
MODEL_REVISION = "870cbe05ef460385363c6b574c851ae5d8989ce3"
CLASSIFICATION_PREFIX = "task: classification | query: "
SEQUENCE_LENGTH = 256
EXPECTED_DIMENSION = 768


def _runtime_registry() -> dict[str, dict[str, Any]]:
    registry = read_json(REPO_ROOT / "ai/models/runtime-models.json")
    return {item["id"]: item for item in registry["artifacts"]}


def verify_embedding_assets(model_path: Path, tokenizer_path: Path) -> None:
    registry = _runtime_registry()
    expected_model = registry["embeddinggemma-300m-seq256"]
    expected_tokenizer = registry["embeddinggemma-300m-sentencepiece"]
    for path, expected, label in (
        (model_path, expected_model, "EmbeddingGemma model"),
        (tokenizer_path, expected_tokenizer, "SentencePiece tokenizer"),
    ):
        resolved = require_file(path, label)
        if resolved.stat().st_size != expected["bytes"]:
            raise FacetRouteBenchError(f"{label} byte length does not match registry")
        if sha256_file(resolved) != expected["sha256"]:
            raise FacetRouteBenchError(f"{label} SHA-256 does not match registry")


def build_input_tokens(
    text: str,
    tokenizer: Any,
    sequence_length: int = SEQUENCE_LENGTH,
) -> Any:
    try:
        import numpy as np
    except ImportError as error:
        raise FacetRouteBenchError("numpy is required; run through `uv run`") from error
    normalized = text.strip()
    if not normalized:
        raise FacetRouteBenchError("embedding text must not be empty")
    bos_id = int(tokenizer.bos_id())
    eos_id = int(tokenizer.eos_id())
    pad_id = int(tokenizer.pad_id())
    if min(bos_id, eos_id, pad_id) < 0:
        raise FacetRouteBenchError("tokenizer must define BOS, EOS, and PAD")
    encoded = list(tokenizer.encode(CLASSIFICATION_PREFIX + normalized, out_type=int))[
        : sequence_length - 2
    ]
    tokens = [bos_id, *encoded, eos_id]
    tokens.extend([pad_id] * (sequence_length - len(tokens)))
    return np.asarray(tokens, dtype=np.int32)


class EmbeddingGemmaRuntime:
    def __init__(self, model_path: Path, tokenizer_path: Path) -> None:
        try:
            import numpy as np
            import sentencepiece
            from ai_edge_litert.compiled_model import (
                CompiledModel,
                HardwareAccelerator,
            )
        except ImportError as error:
            raise FacetRouteBenchError(
                "EmbeddingGemma dependencies are missing; run through `uv run`"
            ) from error
        self._np = np
        started = time.perf_counter()
        self._tokenizer = sentencepiece.SentencePieceProcessor(
            model_file=str(tokenizer_path)
        )
        self._model = CompiledModel.from_file(
            str(model_path),
            hardware_accel=HardwareAccelerator.CPU,
        )
        signatures = self._model.get_signature_list()
        if len(signatures) != 1:
            raise FacetRouteBenchError("EmbeddingGemma must expose one signature")
        signature = next(iter(signatures.values()))
        if len(signature["inputs"]) != 1 or len(signature["outputs"]) != 1:
            raise FacetRouteBenchError(
                "EmbeddingGemma must expose one input and one output"
            )
        self._input_buffers = self._model.create_input_buffers(0)
        self._output_buffers = self._model.create_output_buffers(0)
        self.load_elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

    def embed(self, text: str) -> tuple[list[float], float]:
        tokens = build_input_tokens(text, self._tokenizer)
        started = time.perf_counter()
        self._input_buffers[0].write(tokens)
        self._model.run_by_index(0, self._input_buffers, self._output_buffers)
        vector = self._output_buffers[0].read(EXPECTED_DIMENSION, self._np.float32)
        elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
        if vector.shape != (EXPECTED_DIMENSION,) or not self._np.isfinite(vector).all():
            raise FacetRouteBenchError("EmbeddingGemma returned an invalid vector")
        norm = float(self._np.linalg.norm(vector))
        if not math.isfinite(norm) or not 0.99 <= norm <= 1.01:
            raise FacetRouteBenchError(
                f"EmbeddingGemma vector norm must be approximately one, got {norm}"
            )
        return vector.tolist(), elapsed_ms

    def close(self) -> None:
        for buffer in (*self._input_buffers, *self._output_buffers):
            buffer.destroy()


def prepare_embedding_inputs(dataset_dir: Path, output_path: Path) -> Path:
    route_contract = load_route_contract()
    manifest = read_json(dataset_dir / "dataset_manifest.json")
    if manifest.get("status") != "valid":
        raise FacetRouteBenchError("dataset manifest is not marked valid")
    persona_core = (
        REPO_ROOT
        / "ios/EdgeLLM/Sources/EdgeLLM/Resources/Prompts/RoutedPersona/persona_core.md"
    )
    expected_contracts = {
        "benchmark_sha256": sha256_file(
            CONTRACTS_DIR / "benchmark.v1.json"
        ),
        "routes_sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
        "dataset_schema_sha256": sha256_file(
            CONTRACTS_DIR / "dataset.schema.json"
        ),
        "persona_core_sha256": sha256_file(persona_core),
    }
    if any(
        manifest.get("contracts", {}).get(key) != value
        for key, value in expected_contracts.items()
    ):
        raise FacetRouteBenchError("dataset manifest contracts are stale")
    datasets = {
        split: read_jsonl(dataset_dir / manifest["splits"][split]["path"])
        for split in ("authoring", "dev", "frozen", "context_challenge")
    }
    for split, metadata in manifest["splits"].items():
        path = dataset_dir / metadata["path"]
        if sha256_file(path) != metadata["sha256"]:
            raise FacetRouteBenchError(f"dataset split SHA mismatch: {split}")
    all_records = [record for records in datasets.values() for record in records]
    for record in all_records:
        validate_record_schema(record)
        validate_record_semantics(record)
    validate_dataset_counts(all_records, load_benchmark_contract())
    inputs: list[dict[str, Any]] = []
    for route in route_contract["route_order"][:-1]:
        detail = route_contract["routes"][route]
        inputs.append(
            {
                "embedding_id": f"route-card:{route}",
                "kind": "route_card",
                "route_id": route,
                "case_id": None,
                "text": detail["scene_card"],
            }
        )
        inputs.append(
            {
                "embedding_id": f"route-description:{route}",
                "kind": "route_description",
                "route_id": route,
                "case_id": None,
                "text": detail["definition"],
            }
        )
    for split in ("authoring", "dev", "frozen", "context_challenge"):
        for record in datasets[split]:
            kind = "prototype" if split == "authoring" else "query"
            inputs.append(
                {
                    "embedding_id": f"{kind}:{record['case_id']}",
                    "kind": kind,
                    "route_id": record["gold_route_id"]
                    if kind == "prototype"
                    else None,
                    "case_id": record["case_id"],
                    "text": final_user_text(record["messages"]),
                }
            )
    ids = [item["embedding_id"] for item in inputs]
    if len(ids) != len(set(ids)):
        raise FacetRouteBenchError("embedding inputs contain duplicate IDs")
    write_jsonl(output_path, inputs)
    return output_path.resolve()


def extract_embeddings(
    *,
    inputs_path: Path,
    model_path: Path,
    tokenizer_path: Path,
    output_dir: Path,
    runtime_mode: str,
) -> Path:
    if runtime_mode not in {"warm", "cold"}:
        raise FacetRouteBenchError("runtime_mode must be warm or cold")
    run_commit = git_commit()
    verify_embedding_assets(model_path, tokenizer_path)
    inputs = read_jsonl(inputs_path)
    output_path = output_dir / "embeddings.jsonl"
    request_path = output_dir / "run_request.json"
    request = {
        "schema_version": "facetroutebench-embedding-request-v1",
        "git_commit": run_commit,
        "inputs_sha256": sha256_file(inputs_path),
        "model_sha256": sha256_file(model_path),
        "tokenizer_sha256": sha256_file(tokenizer_path),
        "runtime_mode": runtime_mode,
    }
    if output_dir.exists():
        if (output_dir / "embedding_manifest.json").exists():
            raise FacetRouteBenchError(
                f"embedding run is already complete: {output_dir}"
            )
        if not request_path.is_file():
            raise FacetRouteBenchError("embedding output has no resumable run request")
        checkpoint = read_json(request_path)
        if checkpoint.get("request") != request:
            raise FacetRouteBenchError(
                "embedding checkpoint request does not match this run"
            )
        created_at = checkpoint["created_at"]
        results = read_jsonl(output_path) if output_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        created_at = utc_now()
        results = []
        write_json(request_path, {"created_at": created_at, "request": request})
    processed_ids = {item["embedding_id"] for item in results}
    expected_ids = {item["embedding_id"] for item in inputs}
    if len(processed_ids) != len(results) or not processed_ids <= expected_ids:
        raise FacetRouteBenchError("embedding checkpoint is duplicated or stale")
    shared_runtime: EmbeddingGemmaRuntime | None = None
    started = time.perf_counter()
    try:
        if runtime_mode == "warm":
            shared_runtime = EmbeddingGemmaRuntime(model_path, tokenizer_path)
        for index, item in enumerate(inputs, start=1):
            if item["embedding_id"] in processed_ids:
                continue
            runtime = shared_runtime or EmbeddingGemmaRuntime(
                model_path, tokenizer_path
            )
            try:
                vector, inference_ms = runtime.embed(item["text"])
                results.append(
                    {
                        **item,
                        "embedding": vector,
                        "model_load_elapsed_ms": runtime.load_elapsed_ms,
                        "inference_elapsed_ms": inference_ms,
                    }
                )
            finally:
                if shared_runtime is None:
                    runtime.close()
            if len(results) % 25 == 0:
                write_jsonl(output_path, results, overwrite=True)
            if index == 1 or index % 50 == 0:
                print(f"embedded {index}/{len(inputs)}", flush=True)
    finally:
        if shared_runtime is not None:
            shared_runtime.close()
    if {item["embedding_id"] for item in results} != expected_ids:
        raise FacetRouteBenchError("embedding run ended without every expected vector")
    write_jsonl(output_path, results, overwrite=output_path.exists())
    manifest = {
        "schema_version": "facetroutebench-embedding-run-v1",
        "created_at": created_at,
        "git_commit": run_commit,
        "runtime_mode": runtime_mode,
        "inputs": {
            "path": str(inputs_path.resolve()),
            "records": len(inputs),
            "sha256": sha256_file(inputs_path),
        },
        "output": {
            "path": output_path.name,
            "records": len(results),
            "sha256": sha256_file(output_path),
        },
        "model": {
            "id": MODEL_ID,
            "revision": MODEL_REVISION,
            "path": str(model_path.resolve()),
            "sha256": sha256_file(model_path),
            "sequence_length": SEQUENCE_LENGTH,
            "dimension": EXPECTED_DIMENSION,
            "prefix": CLASSIFICATION_PREFIX,
        },
        "tokenizer": {
            "path": str(tokenizer_path.resolve()),
            "sha256": sha256_file(tokenizer_path),
        },
        "runtime": {
            "name": "ai-edge-litert",
            "version": importlib.metadata.version("ai-edge-litert"),
            "backend": "CPU",
            "python": platform.python_version(),
            "platform": platform.platform(),
        },
        "elapsed_seconds": round(time.perf_counter() - started, 6),
    }
    write_json(output_dir / "embedding_manifest.json", manifest)
    return (output_dir / "embedding_manifest.json").resolve()
