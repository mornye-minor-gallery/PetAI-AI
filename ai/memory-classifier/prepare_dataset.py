#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

EXPECTED_COUNTS = {
    "train": 1600,
    "validation": 200,
    "test": 200,
    "synthetic_challenge": 100,
}


class DatasetPreparationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_source(path: Path) -> dict[str, list[dict[str, Any]]]:
    splits = {split: [] for split in EXPECTED_COUNTS}
    seen_ids: set[str] = set()
    seen_utterances: set[str] = set()

    with path.open(encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: invalid JSON."
                ) from error
            if not isinstance(row, dict):
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: row must be an object."
                )
            split = row.get("split")
            row_id = row.get("id")
            utterance = row.get("utterance")
            if split not in splits:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: unsupported split {split!r}."
                )
            if not isinstance(row_id, str) or not row_id:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: invalid id."
                )
            if not isinstance(utterance, str) or not utterance.strip():
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: invalid utterance."
                )
            if row_id in seen_ids or utterance in seen_utterances:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: duplicate id or utterance."
                )
            if type(row.get("preference")) is not bool:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: preference must be boolean."
                )
            if type(row.get("event")) is not bool:
                raise DatasetPreparationError(
                    f"{path.name}:{line_number}: event must be boolean."
                )
            for key in (
                "challenge_type",
                "expression_pattern",
                "surface_style",
                "topic_hint",
                "family_id",
            ):
                if not isinstance(row.get(key), str) or not row[key]:
                    raise DatasetPreparationError(
                        f"{path.name}:{line_number}: invalid {key}."
                    )
            seen_ids.add(row_id)
            seen_utterances.add(utterance)
            splits[split].append(row)

    for split, expected_count in EXPECTED_COUNTS.items():
        if len(splits[split]) != expected_count:
            raise DatasetPreparationError(
                f"{split}: expected {expected_count}, found "
                f"{len(splits[split])}."
            )
        combinations = Counter(
            (row["preference"], row["event"]) for row in splits[split]
        )
        if set(combinations.values()) != {expected_count // 4}:
            raise DatasetPreparationError(
                f"{split}: label combinations are not balanced."
            )
    return splits


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(
                json.dumps(
                    row,
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                )
                + "\n"
            )


def prepare_dataset(input_path: Path, output_dir: Path) -> Path:
    input_path = input_path.expanduser().resolve()
    output_dir = output_dir.expanduser().resolve()
    if not input_path.is_file():
        raise DatasetPreparationError(f"Input not found: {input_path}")
    if output_dir.exists():
        raise DatasetPreparationError(
            f"Output directory already exists: {output_dir}"
        )

    splits = load_source(input_path)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(
            prefix=f".{output_dir.name}.",
            dir=output_dir.parent,
        )
    )
    try:
        outputs: dict[str, dict[str, Any]] = {}
        for split, rows in splits.items():
            output_path = temporary_dir / f"{split}.jsonl"
            write_jsonl(output_path, rows)
            outputs[split] = {
                "path": output_path.name,
                "records": len(rows),
                "sha256": sha256_file(output_path),
            }
        manifest = {
            "phase": "dataset_preparation_complete",
            "created_at": datetime.now(UTC).isoformat(),
            "source": {
                "path": str(input_path),
                "sha256": sha256_file(input_path),
                "records": sum(EXPECTED_COUNTS.values()),
            },
            "splits": outputs,
        }
        manifest_path = temporary_dir / "dataset_manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary_dir, output_dir)
        return output_dir / manifest_path.name
    except Exception:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and split the 2,100-record classifier dataset."
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    return parser


def main() -> None:
    arguments = build_parser().parse_args()
    manifest = prepare_dataset(arguments.input, arguments.output_dir)
    print(f"Dataset manifest: {manifest}")


if __name__ == "__main__":
    main()
