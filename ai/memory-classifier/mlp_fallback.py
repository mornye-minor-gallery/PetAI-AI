from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

import numpy as np

from hybrid_memory_harness import MemoryDecision


EXPECTED_DIMENSION = 768


class MLPFallbackError(RuntimeError):
    pass


class EmbeddingIndex:
    def __init__(self) -> None:
        self._records: dict[str, tuple[str, np.ndarray]] = {}

    def add_file(self, path: Path) -> None:
        path = path.expanduser().resolve()
        if not path.is_file():
            raise MLPFallbackError(f"Embedding split not found: {path}")

        with path.open(encoding="utf-8") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                if not raw_line.strip():
                    continue
                try:
                    row = json.loads(raw_line)
                except json.JSONDecodeError as error:
                    raise MLPFallbackError(
                        f"{path.name}:{line_number}: invalid JSON."
                    ) from error
                self._add_row(path, line_number, row)

    def get(
        self,
        *,
        record_id: str,
        utterance: str,
    ) -> np.ndarray:
        try:
            indexed_utterance, embedding = self._records[record_id]
        except KeyError as error:
            raise MLPFallbackError(
                f"No embedding found for record {record_id!r}."
            ) from error
        if indexed_utterance != utterance:
            raise MLPFallbackError(
                f"Utterance mismatch for record {record_id!r}."
            )
        return embedding

    def _add_row(
        self,
        path: Path,
        line_number: int,
        row: dict[str, Any],
    ) -> None:
        record_id = row.get("id")
        utterance = row.get("utterance")
        embedding = row.get("embedding")
        if not isinstance(record_id, str) or not record_id:
            raise MLPFallbackError(
                f"{path.name}:{line_number}: invalid id."
            )
        if record_id in self._records:
            raise MLPFallbackError(
                f"{path.name}:{line_number}: duplicate id {record_id!r}."
            )
        if not isinstance(utterance, str) or not utterance:
            raise MLPFallbackError(
                f"{path.name}:{line_number}: invalid utterance."
            )
        if (
            not isinstance(embedding, list)
            or len(embedding) != EXPECTED_DIMENSION
            or not all(
                isinstance(value, (int, float))
                and math.isfinite(value)
                for value in embedding
            )
        ):
            raise MLPFallbackError(
                f"{path.name}:{line_number}: expected "
                f"{EXPECTED_DIMENSION} finite embedding values."
            )
        self._records[record_id] = (
            utterance,
            np.asarray(embedding, dtype=np.float32),
        )


class EmbeddingMLPFallbackClassifier:
    def __init__(
        self,
        *,
        weights_path: Path,
        embeddings: EmbeddingIndex,
    ) -> None:
        weights_path = weights_path.expanduser().resolve()
        if not weights_path.is_file():
            raise MLPFallbackError(
                f"Classifier weights not found: {weights_path}"
            )
        with np.load(weights_path) as values:
            required = {
                "dense_0_weight",
                "dense_0_bias",
                "dense_1_weight",
                "dense_1_bias",
                "thresholds",
            }
            missing = required.difference(values.files)
            if missing:
                raise MLPFallbackError(
                    f"Classifier weights missing keys: {sorted(missing)}"
                )
            self._dense_0_weight = np.asarray(
                values["dense_0_weight"],
                dtype=np.float32,
            )
            self._dense_0_bias = np.asarray(
                values["dense_0_bias"],
                dtype=np.float32,
            )
            self._dense_1_weight = np.asarray(
                values["dense_1_weight"],
                dtype=np.float32,
            )
            self._dense_1_bias = np.asarray(
                values["dense_1_bias"],
                dtype=np.float32,
            )
            self._thresholds = np.asarray(
                values["thresholds"],
                dtype=np.float32,
            )
        self._validate_shapes()
        self._embeddings = embeddings
        self._cache: dict[str, MemoryDecision] = {}

    def classify(
        self,
        *,
        record_id: str,
        utterance: str,
    ) -> MemoryDecision:
        if record_id in self._cache:
            return self._cache[record_id]
        embedding = self._embeddings.get(
            record_id=record_id,
            utterance=utterance,
        )
        hidden = np.maximum(
            embedding @ self._dense_0_weight + self._dense_0_bias,
            0.0,
        )
        logits = hidden @ self._dense_1_weight + self._dense_1_bias
        stable_logits = np.clip(logits, -80.0, 80.0)
        probabilities = 1.0 / (1.0 + np.exp(-stable_logits))
        predictions = probabilities >= self._thresholds
        decision = MemoryDecision.from_flags(
            preference=bool(predictions[0]),
            event=bool(predictions[1]),
        )
        self._cache[record_id] = decision
        return decision

    def _validate_shapes(self) -> None:
        if self._dense_0_weight.shape[0] != EXPECTED_DIMENSION:
            raise MLPFallbackError(
                "First dense layer does not accept 768-value embeddings."
            )
        hidden_units = self._dense_0_weight.shape[1]
        expected = {
            "dense_0_bias": (hidden_units,),
            "dense_1_weight": (hidden_units, 2),
            "dense_1_bias": (2,),
            "thresholds": (2,),
        }
        actual = {
            "dense_0_bias": self._dense_0_bias.shape,
            "dense_1_weight": self._dense_1_weight.shape,
            "dense_1_bias": self._dense_1_bias.shape,
            "thresholds": self._thresholds.shape,
        }
        for name, expected_shape in expected.items():
            if actual[name] != expected_shape:
                raise MLPFallbackError(
                    f"{name} has shape {actual[name]}, expected "
                    f"{expected_shape}."
                )
