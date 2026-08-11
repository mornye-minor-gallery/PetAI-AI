from pathlib import Path

import numpy as np

from toolroutebench.common import sha256_file, write_json, write_jsonl
from toolroutebench.contracts import load_tool_contract
from toolroutebench.ios_tool_router_export import export_ios_tool_router


def test_export_ios_tool_router_writes_frozen_runtime_contract(
    tmp_path: Path,
) -> None:
    weights_path = tmp_path / "model_weights.npz"
    np.savez_compressed(
        weights_path,
        dense_0_weight=np.zeros((768, 64), dtype=np.float32),
        dense_0_bias=np.zeros(64, dtype=np.float32),
        dense_1_weight=np.zeros((64, 1), dtype=np.float32),
        dense_1_bias=np.zeros(1, dtype=np.float32),
        threshold=np.asarray([0.51], dtype=np.float32),
    )
    result_path = tmp_path / "result.json"
    write_json(
        result_path,
        {
            "experiment_id": "test-sota",
            "git_commit": "abc123",
            "model": {
                "type": "sklearn.neural_network.MLPClassifier",
                "input_dimension": 768,
                "hidden_units": 64,
                "output_dimension": 1,
                "threshold": 0.51,
            },
            "artifacts": {
                "weights": {"sha256": sha256_file(weights_path)},
            },
        },
    )

    tools = load_tool_contract()["tool_order"]
    candidate_path = tmp_path / "selected_candidate.json"
    write_json(
        candidate_path,
        {
            "candidate_id": "embedding-09",
            "representation": "utterance_prototype",
            "aggregation": "max_similarity",
            "normal_decision": "absolute_tool_threshold",
            "threshold_structure": "cv_shrunk_per_tool",
            "thresholds": {tool: 0.7 for tool in tools},
        },
    )

    embedding_rows = []
    for tool_index, tool in enumerate(tools):
        for prototype_index in range(12):
            vector = [0.0] * 768
            vector[(tool_index * 12 + prototype_index) % 768] = 1.0
            embedding_rows.append(
                {
                    "kind": "positive_prototype",
                    "tool_id": tool,
                    "embedding": vector,
                }
            )
    embeddings_path = tmp_path / "embeddings.jsonl"
    write_jsonl(embeddings_path, embedding_rows)
    embedding_manifest_path = tmp_path / "embedding_manifest.json"
    write_json(
        embedding_manifest_path,
        {
            "output": {"sha256": sha256_file(embeddings_path)},
            "model": {
                "dimension": 768,
                "prefix": "task: classification | query: ",
            },
        },
    )

    output_dir = tmp_path / "runtime"
    manifest_path = export_ios_tool_router(
        weights_path=weights_path,
        result_path=result_path,
        selected_candidate_path=candidate_path,
        prototype_embeddings_path=embeddings_path,
        prototype_embedding_manifest_path=embedding_manifest_path,
        output_dir=output_dir,
    )

    assert manifest_path == (output_dir / "native_tool_router_v1.json").resolve()
    assert (output_dir / "native_tool_actionability_v1.f32").stat().st_size == (
        (768 * 64 + 64 + 64 + 1) * 4
    )
    assert (output_dir / "native_tool_prototypes_v1.f32").stat().st_size == (
        7 * 12 * 768 * 4
    )
