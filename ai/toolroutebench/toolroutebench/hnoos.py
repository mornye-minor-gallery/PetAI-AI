from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable

from .actionability import normalize_utterance
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

HNOOS_CONFIG = CONFIGS_DIR / "actionability-hnoos-en-aux.v1.json"


def parse_hnoos_records(
    value: Any,
    *,
    source_dataset: str,
) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ToolRouteBenchError(f"HN-OOS {source_dataset} must contain a JSON array")
    rows: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for index, item in enumerate(value, start=1):
        if (
            not isinstance(item, list)
            or len(item) != 2
            or not all(isinstance(part, str) for part in item)
        ):
            raise ToolRouteBenchError(
                f"HN-OOS {source_dataset}:{index} must be [utterance, target_intent]"
            )
        utterance = normalize_utterance(item[0])
        target_intent = item[1].strip()
        if not utterance or not target_intent:
            raise ToolRouteBenchError(f"HN-OOS {source_dataset}:{index} is empty")
        identity = (utterance, target_intent)
        if identity in seen:
            continue
        seen.add(identity)
        rows.append(
            {
                "source_dataset": source_dataset,
                "source_index": str(index),
                "utterance": utterance,
                "target_intent": target_intent,
            }
        )
    if not rows:
        raise ToolRouteBenchError(f"HN-OOS {source_dataset} is empty")
    return rows


def select_petai_relevant_hnoos(
    rows: Iterable[dict[str, str]],
    *,
    included_target_intents: set[str],
    excluded_petai_call_utterances: set[str],
) -> list[dict[str, Any]]:
    normalized_exclusions = {
        normalize_utterance(utterance) for utterance in excluded_petai_call_utterances
    }
    selected: list[dict[str, Any]] = []
    seen_utterances: set[str] = set()
    encountered_exclusions: set[str] = set()
    for row in sorted(
        rows,
        key=lambda item: (
            item["target_intent"],
            item["utterance"],
            item["source_dataset"],
        ),
    ):
        if row["target_intent"] not in included_target_intents:
            continue
        utterance = row["utterance"]
        if utterance in normalized_exclusions:
            encountered_exclusions.add(utterance)
            continue
        if utterance in seen_utterances:
            continue
        seen_utterances.add(utterance)
        case_hash = hashlib.sha256(
            f"{row['source_dataset']}\x1f{row['target_intent']}\x1f{utterance}".encode(
                "utf-8"
            )
        ).hexdigest()[:16]
        selected.append(
            {
                "case_id": f"hnoos-en-train-{case_hash}",
                "split": "train",
                "utterance": utterance,
                "call": False,
                "label": "NO_CALL",
                "source": "hnoos_en",
                "source_dataset": row["source_dataset"],
                "source_index": int(row["source_index"]),
                "source_label": row["target_intent"],
                "source_label_name": f"hnoos:{row['target_intent']}",
            }
        )
    missing_exclusions = normalized_exclusions - encountered_exclusions
    if missing_exclusions:
        raise ToolRouteBenchError(
            "HN-OOS exclusions were not found in the pinned sources: "
            + ", ".join(sorted(missing_exclusions))
        )
    if not selected:
        raise ToolRouteBenchError("PetAI-relevant HN-OOS selection is empty")
    return sorted(selected, key=lambda row: row["case_id"])


def _read_source_array(path: Path, *, source_dataset: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ToolRouteBenchError(
            f"could not read HN-OOS {source_dataset}: {error}"
        ) from error


def prepare_hnoos_actionability_auxiliary(
    *,
    source_cache_dir: Path,
    output_dir: Path,
    config_path: Path = HNOOS_CONFIG,
) -> Path:
    if output_dir.exists():
        raise ToolRouteBenchError(f"output directory already exists: {output_dir}")
    config = read_json(config_path)
    parsed_rows: list[dict[str, str]] = []
    cached_sources: dict[str, Any] = {}
    for source_dataset, source in sorted(config["sources"].items()):
        source_path = download_pinned_source(
            label=f"HN-OOS {source_dataset}",
            url=source["url"],
            expected_sha256=source["sha256"],
            output_path=source_cache_dir / source["filename"],
        )
        parsed_rows.extend(
            parse_hnoos_records(
                _read_source_array(source_path, source_dataset=source_dataset),
                source_dataset=source_dataset,
            )
        )
        cached_sources[source_dataset] = {
            **source,
            "cached_path": str(source_path.resolve()),
        }
    selected = select_petai_relevant_hnoos(
        parsed_rows,
        included_target_intents=set(config["included_target_intents"]),
        excluded_petai_call_utterances=set(
            config["excluded_petai_call_utterances"]
        ),
    )
    output_dir.mkdir(parents=True)
    dataset_path = output_dir / "dataset.jsonl"
    embedding_inputs_path = output_dir / "embedding_inputs.jsonl"
    write_jsonl(dataset_path, selected)
    write_jsonl(
        embedding_inputs_path,
        [
            {
                "embedding_id": f"actionability-aux:{row['case_id']}",
                "kind": "actionability_auxiliary",
                "case_id": row["case_id"],
                "split": row["split"],
                "text": row["utterance"],
                "call": row["call"],
                "label": row["label"],
                "source": row["source"],
                "source_dataset": row["source_dataset"],
                "source_label": row["source_label"],
                "source_label_name": row["source_label_name"],
            }
            for row in selected
        ],
    )
    source_counts = Counter(row["source_dataset"] for row in selected)
    intent_counts = Counter(row["source_label"] for row in selected)
    manifest = {
        "schema_version": "toolroutebench-actionability-aux-dataset-v1",
        "experiment_id": config["experiment_id"],
        "created_at": utc_now(),
        "language": "en",
        "role": "train_only_no_call_auxiliary",
        "license": config["license"],
        "source_repository": config["source_repository"],
        "sources": cached_sources,
        "selection": {
            "included_target_intents": config["included_target_intents"],
            "excluded_petai_call_utterances": config[
                "excluded_petai_call_utterances"
            ],
            "meaning": (
                "Source target intent is provenance only; every retained row is "
                "re-labeled NO_CALL relative to the fixed PetAI tool inventory."
            ),
        },
        "counts": {
            "records": len(selected),
            "by_source_dataset": dict(sorted(source_counts.items())),
            "by_target_intent": dict(sorted(intent_counts.items())),
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
