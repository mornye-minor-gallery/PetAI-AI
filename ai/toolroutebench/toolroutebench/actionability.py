from __future__ import annotations

import hashlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from .common import (
    CONFIGS_DIR,
    ToolRouteBenchError,
    read_json,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .source_download import download_pinned_source

ACTIONABILITY_CONFIG = CONFIGS_DIR / "actionability-3i4k-mlp-smoke.v1.json"
SOURCE_LABEL_NAMES = {
    0: "fragment",
    1: "statement",
    2: "question",
    3: "command",
    4: "rhetorical_question",
    5: "rhetorical_command",
    6: "intonation_dependent",
}


def normalize_utterance(text: str) -> str:
    return " ".join(text.split())


def parse_3i4k_lines(lines: Iterable[str], *, source_split: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\r\n")
        if not line.strip():
            continue
        try:
            raw_label, raw_text = line.split("\t", 1)
            source_label = int(raw_label)
        except (ValueError, TypeError) as error:
            raise ToolRouteBenchError(
                f"3i4K {source_split}:{line_number}: expected label<TAB>utterance"
            ) from error
        if source_label not in SOURCE_LABEL_NAMES:
            raise ToolRouteBenchError(
                f"3i4K {source_split}:{line_number}: unknown label {source_label}"
            )
        utterance = normalize_utterance(raw_text)
        if not utterance or utterance in seen:
            continue
        seen.add(utterance)
        rows.append(
            {
                "source": "3i4k",
                "source_split": source_split,
                "source_line": line_number,
                "source_label": source_label,
                "source_label_name": SOURCE_LABEL_NAMES[source_label],
                "utterance": utterance,
            }
        )
    if not rows:
        raise ToolRouteBenchError(f"3i4K {source_split} is empty")
    return rows


def binary_label(source_label: int) -> bool:
    if source_label in (2, 3):
        return True
    if source_label in (0, 1, 4, 5, 6):
        return False
    raise ToolRouteBenchError(f"unknown 3i4K source label: {source_label}")


def _stable_rank(seed: int, *values: str) -> str:
    payload = "\x1f".join((str(seed), *values)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def split_train_validation(
    rows: Iterable[dict[str, Any]],
    *,
    seed: int,
    validation_fraction: float,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not 0.0 < validation_fraction < 1.0:
        raise ToolRouteBenchError("validation_fraction must be between zero and one")
    boundary = int(validation_fraction * 10_000)
    train: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    for row in rows:
        rank = int(_stable_rank(seed, row["utterance"])[:8], 16) % 10_000
        (validation if rank < boundary else train).append(row)
    return train, validation


def sample_per_source_label(
    rows: Iterable[dict[str, Any]],
    *,
    quotas: dict[str, int],
    seed: int,
    split: str,
) -> list[dict[str, Any]]:
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[int(row["source_label"])].append(row)
    selected: list[dict[str, Any]] = []
    for raw_label, quota in sorted(quotas.items(), key=lambda item: int(item[0])):
        label = int(raw_label)
        candidates = sorted(
            grouped.get(label, []),
            key=lambda row: _stable_rank(
                seed,
                split,
                str(label),
                row["utterance"],
            ),
        )
        if len(candidates) < quota:
            raise ToolRouteBenchError(
                f"3i4K {split} label {label} has {len(candidates)} rows, needs {quota}"
            )
        for row in candidates[:quota]:
            call = binary_label(label)
            case_hash = _stable_rank(seed, split, str(label), row["utterance"])[:16]
            selected.append(
                {
                    "case_id": f"3i4k-{split}-{label}-{case_hash}",
                    "split": split,
                    "utterance": row["utterance"],
                    "call": call,
                    "label": "CALL" if call else "NO_CALL",
                    "source": row["source"],
                    "source_split": row["source_split"],
                    "source_line": row["source_line"],
                    "source_label": label,
                    "source_label_name": row["source_label_name"],
                }
            )
    return sorted(selected, key=lambda row: row["case_id"])


def validate_split_boundaries(rows: Iterable[dict[str, Any]]) -> None:
    ids: set[str] = set()
    utterance_splits: dict[str, set[str]] = defaultdict(set)
    for row in rows:
        case_id = row["case_id"]
        if case_id in ids:
            raise ToolRouteBenchError(f"duplicate actionability case ID: {case_id}")
        ids.add(case_id)
        utterance_splits[row["utterance"]].add(row["split"])
    leaked = {
        utterance: sorted(splits)
        for utterance, splits in utterance_splits.items()
        if len(splits) > 1
    }
    if leaked:
        first = next(iter(leaked.items()))
        raise ToolRouteBenchError(
            f"3i4K utterance crosses splits: {first[0]!r} -> {first[1]}"
        )


def load_full_3i4k_splits(
    *,
    source_cache_dir: Path,
    config_path: Path = ACTIONABILITY_CONFIG,
) -> tuple[
    dict[str, Any],
    Path,
    Path,
    dict[str, list[dict[str, Any]]],
    dict[str, int],
]:
    """Load deterministic, deduplicated 3i4K splits without quota sampling."""
    config = read_json(config_path)
    seed = int(config["seed"])
    sources = config["sources"]
    train_source = download_pinned_source(
        label="3i4K train/validation source",
        url=sources["train_validation"]["url"],
        expected_sha256=sources["train_validation"]["sha256"],
        output_path=source_cache_dir / "fci_train_val.txt",
    )
    test_source = download_pinned_source(
        label="3i4K test source",
        url=sources["test"]["url"],
        expected_sha256=sources["test"]["sha256"],
        output_path=source_cache_dir / "fci_test.txt",
    )
    train_validation_rows = parse_3i4k_lines(
        train_source.read_text(encoding="utf-8").splitlines(),
        source_split="train_validation",
    )
    raw_train, raw_validation = split_train_validation(
        train_validation_rows,
        seed=seed,
        validation_fraction=float(config["validation_fraction"]),
    )
    raw_test = parse_3i4k_lines(
        test_source.read_text(encoding="utf-8").splitlines(),
        source_split="test",
    )
    test_utterances = {row["utterance"] for row in raw_test}
    train_before_deduplication = len(raw_train)
    validation_before_deduplication = len(raw_validation)
    raw_train = [
        row for row in raw_train if row["utterance"] not in test_utterances
    ]
    raw_validation = [
        row for row in raw_validation if row["utterance"] not in test_utterances
    ]
    source_overlap_removed = {
        "train": train_before_deduplication - len(raw_train),
        "validation": validation_before_deduplication - len(raw_validation),
    }
    return (
        config,
        train_source,
        test_source,
        {
            "train": raw_train,
            "validation": raw_validation,
            "test": raw_test,
        },
        source_overlap_removed,
    )


def prepare_3i4k_actionability_dataset(
    *,
    source_cache_dir: Path,
    output_dir: Path,
    config_path: Path = ACTIONABILITY_CONFIG,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    (
        config,
        train_source,
        test_source,
        source_splits,
        source_overlap_removed,
    ) = load_full_3i4k_splits(
        source_cache_dir=source_cache_dir,
        config_path=config_path,
    )
    seed = int(config["seed"])
    sources = config["sources"]
    raw_train = source_splits["train"]
    raw_validation = source_splits["validation"]
    raw_test = source_splits["test"]
    quotas = config["sample_quotas_per_source_label"]
    rows = [
        *sample_per_source_label(
            raw_train,
            quotas=quotas["train"],
            seed=seed,
            split="train",
        ),
        *sample_per_source_label(
            raw_validation,
            quotas=quotas["validation"],
            seed=seed,
            split="validation",
        ),
        *sample_per_source_label(
            raw_test,
            quotas=quotas["test"],
            seed=seed,
            split="test",
        ),
    ]
    validate_split_boundaries(rows)
    output_dir.mkdir(parents=True)
    dataset_path = output_dir / "dataset.jsonl"
    embedding_inputs_path = output_dir / "embedding_inputs.jsonl"
    write_jsonl(dataset_path, rows)
    write_jsonl(
        embedding_inputs_path,
        [
            {
                "embedding_id": f"actionability:{row['case_id']}",
                "kind": "actionability_example",
                "case_id": row["case_id"],
                "split": row["split"],
                "text": row["utterance"],
                "call": row["call"],
                "label": row["label"],
                "source": row["source"],
                "source_label": row["source_label"],
                "source_label_name": row["source_label_name"],
            }
            for row in rows
        ],
    )
    split_counts = Counter(row["split"] for row in rows)
    label_counts = {
        split: Counter(row["label"] for row in rows if row["split"] == split)
        for split in ("train", "validation", "test")
    }
    source_label_counts = {
        split: Counter(
            row["source_label_name"] for row in rows if row["split"] == split
        )
        for split in ("train", "validation", "test")
    }
    manifest = {
        "schema_version": "toolroutebench-actionability-dataset-v1",
        "experiment_id": config["experiment_id"],
        "created_at": utc_now(),
        "seed": seed,
        "mapping": {
            "CALL": ["question", "command"],
            "NO_CALL": [
                "fragment",
                "statement",
                "rhetorical_question",
                "rhetorical_command",
                "intonation_dependent",
            ],
            "meaning": "CALL is a downstream-router candidate, not guaranteed tool execution",
        },
        "sources": {
            "train_validation": {
                **sources["train_validation"],
                "cached_path": str(train_source.resolve()),
            },
            "test": {
                **sources["test"],
                "cached_path": str(test_source.resolve()),
            },
        },
        "sampling": {
            "validation_fraction": config["validation_fraction"],
            "quotas_per_source_label": quotas,
            "balanced_binary_labels": True,
            "official_test_overlap_removed_from_train_validation": source_overlap_removed,
        },
        "counts": {
            "records": len(rows),
            "by_split": dict(split_counts),
            "by_binary_label": {
                split: dict(counts) for split, counts in label_counts.items()
            },
            "by_source_label": {
                split: dict(counts)
                for split, counts in source_label_counts.items()
            },
        },
        "artifacts": {
            "dataset": {
                "path": dataset_path.name,
                "sha256": sha256_file(dataset_path),
            },
            "embedding_inputs": {
                "path": embedding_inputs_path.name,
                "sha256": sha256_file(embedding_inputs_path),
            },
            "config": {
                "path": str(config_path.resolve()),
                "sha256": sha256_file(config_path),
            },
        },
    }
    manifest_path = output_dir / "dataset_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path.resolve()
