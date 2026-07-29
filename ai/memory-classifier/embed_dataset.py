from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import shutil
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np
import sentencepiece as sentencepiece
from ai_edge_litert.compiled_model import CompiledModel, HardwareAccelerator

MODEL_ID = "litert-community/embeddinggemma-300m"
MODEL_REVISION = "870cbe05ef460385363c6b574c851ae5d8989ce3"
CLASSIFICATION_PREFIX = "task: classification | query: "
SEQUENCE_LENGTH = 256
EXPECTED_DIMENSION = 768
EXPECTED_SPLIT_COUNTS = {
    "train": 300,
    "validation": 50,
    "test": 100,
}
SUPPORTED_SPLITS = (
    "train",
    "validation",
    "test",
    "synthetic_challenge",
)


class DatasetEmbeddingError(RuntimeError):
    """Raised when an input, runtime, or output contract is violated."""


@dataclass(frozen=True)
class DatasetRecord:
    id: str
    utterance: str
    preference: bool
    event: bool
    challenge_type: str
    split: str


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path, description: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise DatasetEmbeddingError(f"{description} was not found: {resolved}")
    return resolved


def parse_split_argument(value: str) -> tuple[str, Path]:
    split, separator, raw_path = value.partition("=")
    if not separator or not split or not raw_path:
        raise argparse.ArgumentTypeError("Use SPLIT=/absolute/path/to/file.jsonl.")
    if split not in SUPPORTED_SPLITS:
        allowed = ", ".join(SUPPORTED_SPLITS)
        raise argparse.ArgumentTypeError(f"Split must be one of: {allowed}.")
    return split, Path(raw_path)


def parse_count_argument(value: str) -> tuple[str, int]:
    split, separator, raw_count = value.partition("=")
    if not separator or split not in SUPPORTED_SPLITS:
        allowed = ", ".join(SUPPORTED_SPLITS)
        raise argparse.ArgumentTypeError(
            f"Use SPLIT=COUNT where split is one of: {allowed}."
        )
    try:
        count = int(raw_count)
    except ValueError as error:
        raise argparse.ArgumentTypeError("COUNT must be an integer.") from error
    if count < 1:
        raise argparse.ArgumentTypeError("COUNT must be at least one.")
    return split, count


def _require_string(data: dict[str, Any], key: str, line_number: int) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise DatasetEmbeddingError(
            f"Line {line_number}: {key!r} must be a non-empty string."
        )
    return value


def _require_bool(data: dict[str, Any], key: str, line_number: int) -> bool:
    value = data.get(key)
    if type(value) is not bool:
        raise DatasetEmbeddingError(
            f"Line {line_number}: {key!r} must be a JSON boolean."
        )
    return value


def load_split(
    path: Path,
    split: str,
    *,
    expected_count: int | None = None,
) -> list[DatasetRecord]:
    records: list[DatasetRecord] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.strip():
                continue
            try:
                data = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise DatasetEmbeddingError(
                    f"{path.name}:{line_number}: invalid JSON: {error.msg}"
                ) from error
            if not isinstance(data, dict):
                raise DatasetEmbeddingError(
                    f"{path.name}:{line_number}: each line must be a JSON object."
                )
            records.append(
                DatasetRecord(
                    id=_require_string(data, "id", line_number),
                    utterance=_require_string(data, "utterance", line_number),
                    preference=_require_bool(data, "preference", line_number),
                    event=_require_bool(data, "event", line_number),
                    challenge_type=_require_string(
                        data, "challenge_type", line_number
                    ),
                    split=split,
                )
            )

    resolved_count = (
        expected_count
        if expected_count is not None
        else EXPECTED_SPLIT_COUNTS.get(split)
    )
    if resolved_count is not None and len(records) != resolved_count:
        raise DatasetEmbeddingError(
            f"{path.name}: expected {resolved_count} {split} records, "
            f"found {len(records)}."
        )
    return records


def load_dataset(
    inputs: Sequence[tuple[str, Path]],
    expected_counts: dict[str, int] | None = None,
) -> tuple[list[DatasetRecord], dict[str, Path]]:
    provided = [split for split, _ in inputs]
    if len(provided) != len(set(provided)):
        raise DatasetEmbeddingError("Each split may be provided only once.")
    resolved_counts = expected_counts or EXPECTED_SPLIT_COUNTS
    if set(provided) != set(resolved_counts):
        missing = sorted(set(resolved_counts) - set(provided))
        extra = sorted(set(provided) - set(resolved_counts))
        raise DatasetEmbeddingError(
            f"Provide every expected split exactly once. "
            f"Missing={missing}, extra={extra}."
        )

    input_paths = {
        split: require_file(path, f"{split} JSONL") for split, path in inputs
    }
    records: list[DatasetRecord] = []
    split_order = [
        split for split in SUPPORTED_SPLITS if split in resolved_counts
    ]
    for split in split_order:
        records.extend(
            load_split(
                input_paths[split],
                split,
                expected_count=resolved_counts[split],
            )
        )

    ids = [record.id for record in records]
    utterances = [record.utterance for record in records]
    if len(ids) != len(set(ids)):
        raise DatasetEmbeddingError("The dataset contains duplicate IDs.")
    if len(utterances) != len(set(utterances)):
        raise DatasetEmbeddingError("The dataset contains duplicate utterances.")
    if len(records) != sum(resolved_counts.values()):
        raise DatasetEmbeddingError(
            "The combined dataset count does not match expected counts."
        )
    return records, input_paths


def build_input_tokens(
    text: str,
    tokenizer: Any,
    sequence_length: int = SEQUENCE_LENGTH,
) -> np.ndarray:
    normalized = text.strip()
    if not normalized:
        raise DatasetEmbeddingError("Embedding text must not be empty.")
    if sequence_length <= 2:
        raise DatasetEmbeddingError("Sequence length must be greater than two.")

    bos_id = int(tokenizer.bos_id())
    eos_id = int(tokenizer.eos_id())
    pad_id = int(tokenizer.pad_id())
    if min(bos_id, eos_id, pad_id) < 0:
        raise DatasetEmbeddingError("Tokenizer must define BOS, EOS, and PAD IDs.")

    encoded = list(
        tokenizer.encode(
            CLASSIFICATION_PREFIX + normalized,
            out_type=int,
        )
    )
    encoded = encoded[: sequence_length - 2]
    tokens = [bos_id, *encoded, eos_id]
    tokens.extend([pad_id] * (sequence_length - len(tokens)))
    return np.asarray(tokens, dtype=np.int32)


class EmbeddingGemmaRuntime:
    def __init__(self, model_path: Path, tokenizer_path: Path) -> None:
        self._tokenizer = sentencepiece.SentencePieceProcessor(
            model_file=str(tokenizer_path)
        )
        self._model = CompiledModel.from_file(
            str(model_path),
            hardware_accel=HardwareAccelerator.CPU,
        )
        signatures = self._model.get_signature_list()
        if len(signatures) != 1:
            raise DatasetEmbeddingError(
                f"Expected one model signature, found {len(signatures)}."
            )
        signature = next(iter(signatures.values()))
        if len(signature["inputs"]) != 1 or len(signature["outputs"]) != 1:
            raise DatasetEmbeddingError(
                "EmbeddingGemma must expose one input and one output tensor."
            )
        self._input_buffers = self._model.create_input_buffers(0)
        self._output_buffers = self._model.create_output_buffers(0)

    def embed(self, text: str) -> np.ndarray:
        tokens = build_input_tokens(text, self._tokenizer)
        self._input_buffers[0].write(tokens)
        self._model.run_by_index(
            0,
            self._input_buffers,
            self._output_buffers,
        )
        vector = self._output_buffers[0].read(
            EXPECTED_DIMENSION,
            np.float32,
        )
        if vector.shape != (EXPECTED_DIMENSION,):
            raise DatasetEmbeddingError(
                f"Expected {EXPECTED_DIMENSION} values, got {vector.shape}."
            )
        if not np.isfinite(vector).all():
            raise DatasetEmbeddingError("Embedding contains a non-finite value.")
        norm = float(np.linalg.norm(vector))
        if not math.isfinite(norm) or not 0.99 <= norm <= 1.01:
            raise DatasetEmbeddingError(
                f"Embedding norm must be approximately one, got {norm}."
            )
        return vector

    def close(self) -> None:
        for buffer in (*self._input_buffers, *self._output_buffers):
            buffer.destroy()


def output_record(record: DatasetRecord, embedding: np.ndarray) -> dict[str, Any]:
    return {
        "id": record.id,
        "utterance": record.utterance,
        "preference": record.preference,
        "event": record.event,
        "challenge_type": record.challenge_type,
        "split": record.split,
        "embedding": embedding.tolist(),
    }


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(
                json.dumps(
                    record,
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                )
            )
            handle.write("\n")


def validate_output(
    output_path: Path,
    source_records: Sequence[DatasetRecord],
) -> None:
    output_records: list[dict[str, Any]] = []
    with output_path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise DatasetEmbeddingError(
                    f"{output_path.name}:{line_number}: invalid output JSON."
                ) from error
            output_records.append(value)

    if len(output_records) != len(source_records):
        raise DatasetEmbeddingError(
            f"{output_path.name}: expected {len(source_records)} records, "
            f"found {len(output_records)}."
        )
    for source, output in zip(source_records, output_records, strict=True):
        for key in (
            "id",
            "utterance",
            "preference",
            "event",
            "challenge_type",
            "split",
        ):
            if output.get(key) != getattr(source, key):
                raise DatasetEmbeddingError(
                    f"{output_path.name}: {source.id} changed field {key!r}."
                )
        embedding = output.get("embedding")
        if not isinstance(embedding, list) or len(embedding) != EXPECTED_DIMENSION:
            raise DatasetEmbeddingError(
                f"{output_path.name}: {source.id} has an invalid embedding."
            )
        if not all(
            isinstance(value, (int, float)) and math.isfinite(value)
            for value in embedding
        ):
            raise DatasetEmbeddingError(
                f"{output_path.name}: {source.id} has a non-finite embedding."
            )


def build_manifest(
    *,
    model_path: Path,
    tokenizer_path: Path,
    input_paths: dict[str, Path],
    output_paths: dict[str, Path],
    split_records: dict[str, list[DatasetRecord]],
    started_at: datetime,
    elapsed_seconds: float,
) -> dict[str, Any]:
    return {
        "phase": "feature_extraction_complete",
        "training_started": False,
        "created_at": datetime.now(UTC).isoformat(),
        "started_at": started_at.isoformat(),
        "elapsed_seconds": elapsed_seconds,
        "model": {
            "id": MODEL_ID,
            "revision": MODEL_REVISION,
            "filename": model_path.name,
            "sha256": sha256(model_path),
            "sequence_length": SEQUENCE_LENGTH,
            "dimension": EXPECTED_DIMENSION,
            "prefix": CLASSIFICATION_PREFIX,
        },
        "tokenizer": {
            "filename": tokenizer_path.name,
            "sha256": sha256(tokenizer_path),
            "preprocessing": "SentencePiece + BOS + EOS + PAD",
        },
        "runtime": {
            "name": "ai-edge-litert",
            "version": importlib.metadata.version("ai-edge-litert"),
            "api": "CompiledModel",
            "backend": "CPU",
            "python": platform.python_version(),
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
        "splits": {
            split: {
                "records": len(split_records[split]),
                "input": {
                    "path": str(input_paths[split]),
                    "sha256": sha256(input_paths[split]),
                },
                "output": {
                    "path": output_paths[split].name,
                    "sha256": sha256(output_paths[split]),
                },
            }
            for split in split_records
        },
        "total_records": sum(len(records) for records in split_records.values()),
    }


def run(args: argparse.Namespace) -> Path:
    model_path = require_file(args.model, "EmbeddingGemma TFLite model")
    tokenizer_path = require_file(args.tokenizer, "SentencePiece model")
    expected_counts = (
        dict(args.expected_count) if args.expected_count else None
    )
    if args.expected_count and len(expected_counts) != len(args.expected_count):
        raise DatasetEmbeddingError(
            "Each expected split count may be provided only once."
        )
    records, input_paths = load_dataset(args.input, expected_counts)
    output_dir = args.output_dir.expanduser().resolve()
    if output_dir.exists():
        raise DatasetEmbeddingError(
            f"Output directory already exists; choose a new path: {output_dir}"
        )
    output_dir.parent.mkdir(parents=True, exist_ok=True)

    split_order = [
        split for split in SUPPORTED_SPLITS if split in input_paths
    ]
    split_records = {
        split: [record for record in records if record.split == split]
        for split in split_order
    }
    started_at = datetime.now(UTC)
    started_clock = time.perf_counter()
    temporary_dir = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}-",
            dir=output_dir.parent,
        )
    )

    runtime: EmbeddingGemmaRuntime | None = None
    try:
        runtime = EmbeddingGemmaRuntime(model_path, tokenizer_path)
        output_paths: dict[str, Path] = {}
        processed_count = 0
        total_count = len(records)

        for split in split_order:
            output_path = temporary_dir / f"{split}.embeddings.jsonl"
            embedded: list[dict[str, Any]] = []
            for record in split_records[split]:
                embedded.append(output_record(record, runtime.embed(record.utterance)))
                processed_count += 1
                if processed_count == 1 or processed_count % 25 == 0:
                    print(f"Embedded {processed_count}/{total_count}", flush=True)
            write_jsonl(output_path, embedded)
            validate_output(output_path, split_records[split])
            output_paths[split] = output_path

        elapsed_seconds = time.perf_counter() - started_clock
        manifest = build_manifest(
            model_path=model_path,
            tokenizer_path=tokenizer_path,
            input_paths=input_paths,
            output_paths=output_paths,
            split_records=split_records,
            started_at=started_at,
            elapsed_seconds=elapsed_seconds,
        )
        manifest_path = temporary_dir / "embedding_manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary_dir, output_dir)
        return output_dir / manifest_path.name
    except Exception:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise
    finally:
        if runtime is not None:
            runtime.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Extract classification embeddings with the same EmbeddingGemma "
            "model and preprocessing contract used by EdgeLLM."
        )
    )
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--tokenizer", required=True, type=Path)
    parser.add_argument(
        "--input",
        required=True,
        action="append",
        type=parse_split_argument,
        metavar="SPLIT=PATH",
        help="Repeat once for every expected split.",
    )
    parser.add_argument(
        "--expected-count",
        action="append",
        type=parse_count_argument,
        metavar="SPLIT=COUNT",
        help=(
            "Repeat for custom split sizes. When omitted, the legacy "
            "300/50/100 contract is used."
        ),
    )
    parser.add_argument("--output-dir", required=True, type=Path)
    return parser


def main() -> None:
    try:
        manifest_path = run(build_parser().parse_args())
    except DatasetEmbeddingError as error:
        raise SystemExit(f"error: {error}") from error
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
