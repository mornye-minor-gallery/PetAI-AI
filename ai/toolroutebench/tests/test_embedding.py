from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from toolroutebench.common import append_jsonl, read_json, read_jsonl, write_jsonl
from toolroutebench.embedding import EXPECTED_DIMENSION, extract_embeddings


class _FakeEmbeddingRuntime:
    def __init__(self, _model_path: Path, _tokenizer_path: Path) -> None:
        pass

    def embed(self, text: str) -> tuple[list[float], float]:
        vector = [0.0] * EXPECTED_DIMENSION
        vector[len(text) % EXPECTED_DIMENSION] = 1.0
        return vector, 1.0

    def close(self) -> None:
        pass


class EmbeddingExtractionTests(unittest.TestCase):
    def test_large_run_checkpoint_appends_without_rewriting_full_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            inputs_path = root / "inputs.jsonl"
            model_path = root / "model.tflite"
            tokenizer_path = root / "tokenizer.model"
            output_dir = root / "run"
            rows = [
                {
                    "embedding_id": f"query-{index}",
                    "kind": "query",
                    "text": f"문장 {index}",
                }
                for index in range(3)
            ]
            write_jsonl(inputs_path, rows)
            model_path.write_bytes(b"model")
            tokenizer_path.write_bytes(b"tokenizer")

            with (
                patch("toolroutebench.embedding.git_commit", return_value="abc123"),
                patch("toolroutebench.embedding.verify_embedding_assets"),
                patch(
                    "toolroutebench.embedding.EmbeddingGemmaRuntime",
                    _FakeEmbeddingRuntime,
                ),
                patch(
                    "toolroutebench.embedding._registry",
                    return_value={
                        "embeddinggemma-300m-seq256": {"revision": "revision"}
                    },
                ),
                patch(
                    "toolroutebench.embedding.importlib.metadata.version",
                    return_value="test-runtime",
                ),
                patch(
                    "toolroutebench.embedding.append_jsonl",
                    wraps=append_jsonl,
                ) as append_mock,
                patch(
                    "toolroutebench.embedding.write_jsonl",
                    wraps=write_jsonl,
                ) as rewrite_mock,
            ):
                manifest_path = extract_embeddings(
                    inputs_path=inputs_path,
                    model_path=model_path,
                    tokenizer_path=tokenizer_path,
                    output_dir=output_dir,
                )

            self.assertEqual(append_mock.call_count, len(rows))
            rewrite_mock.assert_not_called()
            self.assertEqual(len(read_jsonl(output_dir / "embeddings.jsonl")), 3)
            self.assertEqual(read_json(manifest_path)["output"]["records"], 3)


if __name__ == "__main__":
    unittest.main()
