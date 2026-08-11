from __future__ import annotations

import argparse
import math
import tempfile
from pathlib import Path
from typing import Any

from .common import (
    ToolRouteBenchError,
    read_json,
    read_jsonl,
    sha256_file,
    write_json,
)
from .contracts import load_tool_contract


SCHEMA_VERSION = "petai-native-tool-router-v1"
ARTIFACT_ID = "toolroutebench-two-stage-v1-retrospective"
RUNTIME_MODEL_ID = (
    "litert-community/embeddinggemma-300m-seq256-mixed-precision"
)
CLASSIFICATION_PREFIX = "task: classification | query: "
EXPECTED_DIMENSION = 768
EXPECTED_HIDDEN_UNITS = 64
EXPECTED_PROTOTYPES_PER_TOOL = 12
MLP_FILE_NAME = "native_tool_actionability_v1.f32"
PROTOTYPE_FILE_NAME = "native_tool_prototypes_v1.f32"
MANIFEST_FILE_NAME = "native_tool_router_v1.json"


def _require_sha256(path: Path, expected: str, description: str) -> None:
    actual = sha256_file(path)
    if actual != expected:
        raise ToolRouteBenchError(
            f"{description} SHA-256 differs: expected {expected}, got {actual}"
        )


def _float32_bytes(values: Any) -> bytes:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error
    array = np.asarray(values, dtype="<f4")
    if not np.isfinite(array).all():
        raise ToolRouteBenchError("runtime artifact contains a non-finite float")
    return array.tobytes(order="C")


def export_ios_tool_router(
    *,
    weights_path: Path,
    result_path: Path,
    selected_candidate_path: Path,
    prototype_embeddings_path: Path,
    prototype_embedding_manifest_path: Path,
    output_dir: Path,
    replace: bool = False,
) -> Path:
    try:
        import numpy as np
    except ImportError as error:
        raise ToolRouteBenchError("numpy is required; run through uv") from error

    result = read_json(result_path)
    expected_weights_sha = result.get("artifacts", {}).get("weights", {}).get(
        "sha256"
    )
    if not isinstance(expected_weights_sha, str):
        raise ToolRouteBenchError("MLP result is missing the weights SHA-256")
    _require_sha256(weights_path, expected_weights_sha, "MLP weights")

    model = result.get("model", {})
    if (
        model.get("type") != "sklearn.neural_network.MLPClassifier"
        or model.get("input_dimension") != EXPECTED_DIMENSION
        or model.get("hidden_units") != EXPECTED_HIDDEN_UNITS
        or model.get("output_dimension") != 1
    ):
        raise ToolRouteBenchError("unsupported MLP runtime contract")

    with np.load(weights_path) as weights:
        required = {
            "dense_0_weight",
            "dense_0_bias",
            "dense_1_weight",
            "dense_1_bias",
            "threshold",
        }
        if set(weights.files) != required:
            raise ToolRouteBenchError("MLP weights contain unexpected tensors")
        dense_0_weight = np.asarray(weights["dense_0_weight"], dtype=np.float32)
        dense_0_bias = np.asarray(weights["dense_0_bias"], dtype=np.float32)
        dense_1_weight = np.asarray(weights["dense_1_weight"], dtype=np.float32)
        dense_1_bias = np.asarray(weights["dense_1_bias"], dtype=np.float32)
        threshold_values = np.asarray(weights["threshold"], dtype=np.float32)

    expected_shapes = {
        "dense_0_weight": (EXPECTED_DIMENSION, EXPECTED_HIDDEN_UNITS),
        "dense_0_bias": (EXPECTED_HIDDEN_UNITS,),
        "dense_1_weight": (EXPECTED_HIDDEN_UNITS, 1),
        "dense_1_bias": (1,),
        "threshold": (1,),
    }
    actual_shapes = {
        "dense_0_weight": dense_0_weight.shape,
        "dense_0_bias": dense_0_bias.shape,
        "dense_1_weight": dense_1_weight.shape,
        "dense_1_bias": dense_1_bias.shape,
        "threshold": threshold_values.shape,
    }
    if actual_shapes != expected_shapes:
        raise ToolRouteBenchError(
            f"MLP tensor shapes differ: expected {expected_shapes}, got {actual_shapes}"
        )

    threshold = float(threshold_values[0])
    if not math.isfinite(threshold) or not 0 < threshold < 1:
        raise ToolRouteBenchError("MLP threshold must be finite and between 0 and 1")
    if abs(threshold - float(model.get("threshold", -1))) > 1e-6:
        raise ToolRouteBenchError("MLP threshold differs from result metadata")

    candidate = read_json(selected_candidate_path)
    if (
        candidate.get("candidate_id") != "embedding-09"
        or candidate.get("representation") != "utterance_prototype"
        or candidate.get("aggregation") != "max_similarity"
        or candidate.get("normal_decision") != "absolute_tool_threshold"
        or candidate.get("threshold_structure") != "cv_shrunk_per_tool"
    ):
        raise ToolRouteBenchError("unsupported downstream Tool Router candidate")

    embedding_manifest = read_json(prototype_embedding_manifest_path)
    expected_embedding_sha = embedding_manifest.get("output", {}).get("sha256")
    if not isinstance(expected_embedding_sha, str):
        raise ToolRouteBenchError("embedding manifest is missing the output SHA-256")
    _require_sha256(
        prototype_embeddings_path,
        expected_embedding_sha,
        "prototype embeddings",
    )
    embedding_model = embedding_manifest.get("model", {})
    if (
        embedding_model.get("dimension") != EXPECTED_DIMENSION
        or embedding_model.get("prefix") != CLASSIFICATION_PREFIX
    ):
        raise ToolRouteBenchError("prototype embeddings use an unsupported model contract")

    tool_order = load_tool_contract()["tool_order"]
    thresholds = candidate.get("thresholds")
    if not isinstance(thresholds, dict) or set(thresholds) != set(tool_order):
        raise ToolRouteBenchError("candidate thresholds differ from the Tool contract")

    positive_rows = [
        row
        for row in read_jsonl(prototype_embeddings_path)
        if row.get("kind") == "positive_prototype"
    ]
    ordered_vectors: list[list[float]] = []
    routes: list[dict[str, Any]] = []
    offset = 0
    for tool in tool_order:
        rows = [row for row in positive_rows if row.get("tool_id") == tool]
        if len(rows) != EXPECTED_PROTOTYPES_PER_TOOL:
            raise ToolRouteBenchError(
                f"{tool} must have {EXPECTED_PROTOTYPES_PER_TOOL} prototypes"
            )
        for row in rows:
            vector = row.get("embedding")
            if not isinstance(vector, list) or len(vector) != EXPECTED_DIMENSION:
                raise ToolRouteBenchError(f"{tool} contains an invalid prototype")
            ordered_vectors.append(vector)
        routes.append(
            {
                "tool_id": tool,
                "threshold": float(thresholds[tool]),
                "prototype_offset": offset,
                "prototype_count": len(rows),
            }
        )
        offset += len(rows)

    output_dir.mkdir(parents=True, exist_ok=True)
    destination_paths = [
        output_dir / MLP_FILE_NAME,
        output_dir / PROTOTYPE_FILE_NAME,
        output_dir / MANIFEST_FILE_NAME,
    ]
    existing = [path for path in destination_paths if path.exists()]
    if existing and not replace:
        raise ToolRouteBenchError(
            "runtime artifacts already exist; pass --replace to update exactly "
            + ", ".join(path.name for path in existing)
        )

    with tempfile.TemporaryDirectory(
        prefix=".native-tool-router-export-",
        dir=output_dir,
    ) as temporary_directory:
        temporary_root = Path(temporary_directory)
        mlp_path = temporary_root / MLP_FILE_NAME
        prototype_path = temporary_root / PROTOTYPE_FILE_NAME
        manifest_path = temporary_root / MANIFEST_FILE_NAME
        mlp_path.write_bytes(
            b"".join(
                _float32_bytes(values)
                for values in (
                    dense_0_weight,
                    dense_0_bias,
                    dense_1_weight,
                    dense_1_bias,
                )
            )
        )
        prototype_path.write_bytes(_float32_bytes(ordered_vectors))

        manifest = {
            "schema_version": SCHEMA_VERSION,
            "artifact_id": ARTIFACT_ID,
            "model": {
                "id": RUNTIME_MODEL_ID,
                "classification_prefix": CLASSIFICATION_PREFIX,
                "dimension": EXPECTED_DIMENSION,
            },
            "actionability": {
                "architecture": "dense_relu_dense_sigmoid",
                "hidden_units": EXPECTED_HIDDEN_UNITS,
                "threshold": threshold,
                "weights": {
                    "file": MLP_FILE_NAME,
                    "sha256": sha256_file(mlp_path),
                    "encoding": "float32_little_endian",
                    "layout": [
                        "dense_0_weight_row_major",
                        "dense_0_bias",
                        "dense_1_weight_row_major",
                        "dense_1_bias",
                    ],
                    "value_count": mlp_path.stat().st_size // 4,
                },
            },
            "tool_selection": {
                "candidate_id": "embedding-09",
                "similarity": "cosine",
                "prototype_aggregation": "max_similarity",
                "decision": "absolute_tool_threshold",
                "conflict": "all_routes_above_threshold",
                "vectors": {
                    "file": PROTOTYPE_FILE_NAME,
                    "sha256": sha256_file(prototype_path),
                    "encoding": "float32_little_endian",
                    "prototype_count": len(ordered_vectors),
                },
                "tool_order": tool_order,
                "routes": routes,
            },
            "provenance": {
                "status": "retrospective_research_candidate",
                "mlp_experiment_id": result.get("experiment_id"),
                "mlp_training_commit": result.get("git_commit"),
                "mlp_source_weights_sha256": expected_weights_sha,
                "embedding_candidate_sha256": sha256_file(
                    selected_candidate_path
                ),
                "prototype_embedding_sha256": expected_embedding_sha,
            },
        }
        write_json(manifest_path, manifest)
        for source in (mlp_path, prototype_path, manifest_path):
            source.replace(output_dir / source.name)
    return (output_dir / MANIFEST_FILE_NAME).resolve()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export frozen ToolRouteBench artifacts for the Swift runtime."
    )
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--selected-candidate", type=Path, required=True)
    parser.add_argument("--prototype-embeddings", type=Path, required=True)
    parser.add_argument("--prototype-embedding-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Atomically replace the three existing runtime artifact files.",
    )
    args = parser.parse_args()
    manifest = export_ios_tool_router(
        weights_path=args.weights,
        result_path=args.result,
        selected_candidate_path=args.selected_candidate,
        prototype_embeddings_path=args.prototype_embeddings,
        prototype_embedding_manifest_path=args.prototype_embedding_manifest,
        output_dir=args.output_dir,
        replace=args.replace,
    )
    print(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
