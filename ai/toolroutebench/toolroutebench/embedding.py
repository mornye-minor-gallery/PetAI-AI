from __future__ import annotations

import importlib.metadata
import math
import platform
import time
from pathlib import Path
from typing import Any

from .common import (
    REPOSITORY_ROOT,
    ToolRouteBenchError,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import load_benchmark_contract, load_tool_contract, validate_record_schema

CLASSIFICATION_PREFIX = "task: classification | query: "
SEQUENCE_LENGTH = 256
EXPECTED_DIMENSION = 768


def _registry() -> dict[str, dict[str, Any]]:
    value = read_json(REPOSITORY_ROOT / "ai/models/runtime-models.json")
    return {item["id"]: item for item in value["artifacts"]}


def verify_embedding_assets(model_path: Path, tokenizer_path: Path) -> None:
    registry = _registry()
    for path, artifact_id, label in (
        (model_path, "embeddinggemma-300m-seq256", "EmbeddingGemma model"),
        (
            tokenizer_path,
            "embeddinggemma-300m-sentencepiece",
            "SentencePiece tokenizer",
        ),
    ):
        if not path.is_file():
            raise ToolRouteBenchError(f"{label} is missing: {path}")
        expected = registry[artifact_id]
        if path.stat().st_size != expected["bytes"]:
            raise ToolRouteBenchError(f"{label} byte length differs from registry")
        if sha256_file(path) != expected["sha256"]:
            raise ToolRouteBenchError(f"{label} SHA-256 differs from registry")


def build_input_tokens(text: str, tokenizer: Any) -> Any:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    text = text.strip()
    if not text:
        raise ToolRouteBenchError("embedding input must not be empty")
    bos, eos, pad = (
        int(tokenizer.bos_id()),
        int(tokenizer.eos_id()),
        int(tokenizer.pad_id()),
    )
    if min(bos, eos, pad) < 0:
        raise ToolRouteBenchError("tokenizer must define BOS, EOS and PAD")
    encoded = list(
        tokenizer.encode(CLASSIFICATION_PREFIX + text, out_type=int)
    )[: SEQUENCE_LENGTH - 2]
    tokens = [bos, *encoded, eos]
    tokens.extend([pad] * (SEQUENCE_LENGTH - len(tokens)))
    return np.asarray(tokens, dtype=np.int32)


class EmbeddingGemmaRuntime:
    def __init__(self, model_path: Path, tokenizer_path: Path) -> None:
        try:
            import numpy as np
            import sentencepiece
            from ai_edge_litert.compiled_model import CompiledModel, HardwareAccelerator
        except ImportError as error:
            raise ToolRouteBenchError(
                "EmbeddingGemma dependencies are missing; run through uv"
            ) from error
        self._np = np
        started = time.perf_counter()
        self._tokenizer = sentencepiece.SentencePieceProcessor(
            model_file=str(tokenizer_path)
        )
        self._model = CompiledModel.from_file(
            str(model_path), hardware_accel=HardwareAccelerator.CPU
        )
        signatures = self._model.get_signature_list()
        if len(signatures) != 1:
            raise ToolRouteBenchError("EmbeddingGemma must expose one signature")
        signature = next(iter(signatures.values()))
        if len(signature["inputs"]) != 1 or len(signature["outputs"]) != 1:
            raise ToolRouteBenchError("EmbeddingGemma signature must be one-in/one-out")
        self._inputs = self._model.create_input_buffers(0)
        self._outputs = self._model.create_output_buffers(0)
        self.load_elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

    def embed(self, text: str) -> tuple[list[float], float]:
        tokens = build_input_tokens(text, self._tokenizer)
        started = time.perf_counter()
        self._inputs[0].write(tokens)
        self._model.run_by_index(0, self._inputs, self._outputs)
        vector = self._outputs[0].read(EXPECTED_DIMENSION, self._np.float32)
        elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
        if vector.shape != (EXPECTED_DIMENSION,) or not self._np.isfinite(vector).all():
            raise ToolRouteBenchError("EmbeddingGemma returned an invalid vector")
        norm = float(self._np.linalg.norm(vector))
        if not math.isfinite(norm) or not 0.99 <= norm <= 1.01:
            raise ToolRouteBenchError(f"embedding norm is invalid: {norm}")
        return vector.tolist(), elapsed_ms

    def close(self) -> None:
        for buffer in (*self._inputs, *self._outputs):
            buffer.destroy()


def _load_split(dataset_dir: Path, split: str) -> list[dict[str, Any]]:
    manifest = read_json(dataset_dir / "dataset_manifest.json")
    metadata = manifest.get("splits", {}).get(split)
    if not isinstance(metadata, dict):
        raise ToolRouteBenchError(f"dataset manifest has no split {split}")
    path = dataset_dir / metadata["path"]
    if sha256_file(path) != metadata["sha256"]:
        raise ToolRouteBenchError(f"dataset split SHA mismatch: {split}")
    rows = read_jsonl(path)
    for row in rows:
        validate_record_schema(row)
    return rows


def prepare_embedding_inputs(
    dataset_dir: Path,
    output_path: Path,
    query_splits: tuple[str, ...],
    prototype_dataset_dir: Path | None = None,
) -> Path:
    if not query_splits:
        raise ToolRouteBenchError("at least one query split is required")
    tool_contract = load_tool_contract()
    authoring = _load_split(prototype_dataset_dir or dataset_dir, "authoring")
    inputs: list[dict[str, Any]] = []
    for tool in tool_contract["tool_order"]:
        inputs.extend(
            [
                {
                    "embedding_id": f"tool-id:{tool}",
                    "kind": "tool_id",
                    "tool_id": tool,
                    "case_id": None,
                    "text": tool,
                },
                {
                    "embedding_id": f"tool-description:{tool}",
                    "kind": "tool_description",
                    "tool_id": tool,
                    "case_id": None,
                    "text": tool_contract["tools"][tool]["description_ko"],
                },
            ]
        )
    for row in authoring:
        if row["gold_tool_ids"]:
            inputs.append(
                {
                    "embedding_id": f"positive:{row['case_id']}",
                    "kind": "positive_prototype",
                    "tool_id": row["gold_tool_ids"][0],
                    "case_id": row["case_id"],
                    "text": row["utterance"],
                }
            )
        else:
            inputs.append(
                {
                    "embedding_id": f"normal:{row['case_id']}",
                    "kind": "normal_prototype",
                    "tool_id": row["contrast_tool_id"],
                    "case_id": row["case_id"],
                    "text": row["utterance"],
                }
            )
    for split in query_splits:
        if split == "authoring":
            raise ToolRouteBenchError("authoring is reserved for prototypes")
        for row in _load_split(dataset_dir, split):
            inputs.append(
                {
                    "embedding_id": f"query:{row['case_id']}",
                    "kind": "query",
                    "tool_id": None,
                    "case_id": row["case_id"],
                    "text": row["utterance"],
                }
            )
    ids = [item["embedding_id"] for item in inputs]
    if len(ids) != len(set(ids)):
        raise ToolRouteBenchError("embedding input IDs are duplicated")
    write_jsonl(output_path, inputs)
    return output_path.resolve()


def extract_embeddings(
    *,
    inputs_path: Path,
    model_path: Path,
    tokenizer_path: Path,
    output_dir: Path,
) -> Path:
    commit = git_commit(require_clean=True)
    verify_embedding_assets(model_path, tokenizer_path)
    inputs = read_jsonl(inputs_path)
    output_path = output_dir / "embeddings.jsonl"
    request_path = output_dir / "run_request.json"
    request = {
        "schema_version": "toolroutebench-embedding-request-v1",
        "git_commit": commit,
        "inputs_sha256": sha256_file(inputs_path),
        "model_sha256": sha256_file(model_path),
        "tokenizer_sha256": sha256_file(tokenizer_path),
    }
    if output_dir.exists():
        if (output_dir / "embedding_manifest.json").exists():
            raise ToolRouteBenchError(f"embedding run already completed: {output_dir}")
        if not request_path.is_file() or read_json(request_path).get("request") != request:
            raise ToolRouteBenchError("embedding checkpoint does not match request")
        results = read_jsonl(output_path) if output_path.exists() else []
    else:
        output_dir.mkdir(parents=True)
        write_json(request_path, {"created_at": utc_now(), "request": request})
        results = []
    processed = {item["embedding_id"] for item in results}
    if len(processed) != len(results):
        raise ToolRouteBenchError("embedding checkpoint has duplicate IDs")
    runtime = EmbeddingGemmaRuntime(model_path, tokenizer_path)
    started = time.perf_counter()
    try:
        for index, item in enumerate(inputs, start=1):
            if item["embedding_id"] in processed:
                continue
            vector, elapsed_ms = runtime.embed(item["text"])
            results.append(
                {
                    **item,
                    "embedding": vector,
                    "inference_elapsed_ms": elapsed_ms,
                }
            )
            if len(results) % 25 == 0:
                write_jsonl(output_path, results, overwrite=output_path.exists())
            if index == 1 or index % 50 == 0:
                print(f"embedded {index}/{len(inputs)}", flush=True)
    finally:
        runtime.close()
    expected = {item["embedding_id"] for item in inputs}
    if {item["embedding_id"] for item in results} != expected:
        raise ToolRouteBenchError("embedding run ended before all inputs completed")
    write_jsonl(output_path, results, overwrite=output_path.exists())
    registry = _registry()
    manifest = {
        "schema_version": "toolroutebench-embedding-run-v1",
        "git_commit": commit,
        "created_at": utc_now(),
        "inputs": {"path": str(inputs_path.resolve()), "sha256": sha256_file(inputs_path)},
        "output": {
            "path": output_path.name,
            "records": len(results),
            "sha256": sha256_file(output_path),
        },
        "model": {
            "id": "embeddinggemma-300m-seq256",
            "revision": registry["embeddinggemma-300m-seq256"]["revision"],
            "sha256": sha256_file(model_path),
            "sequence_length": SEQUENCE_LENGTH,
            "dimension": EXPECTED_DIMENSION,
            "prefix": CLASSIFICATION_PREFIX,
        },
        "tokenizer": {
            "id": "embeddinggemma-300m-sentencepiece",
            "sha256": sha256_file(tokenizer_path),
        },
        "runtime": {
            "name": "ai-edge-litert",
            "version": importlib.metadata.version("ai-edge-litert"),
            "backend": "cpu",
            "platform": platform.platform(),
        },
        "elapsed_seconds": round(time.perf_counter() - started, 6),
    }
    write_json(output_dir / "embedding_manifest.json", manifest)
    return (output_dir / "embedding_manifest.json").resolve()


def load_dataset_split(dataset_dir: Path, split: str) -> list[dict[str, Any]]:
    return _load_split(dataset_dir, split)
