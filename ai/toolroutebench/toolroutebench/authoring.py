from __future__ import annotations

import itertools
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from .codex_adapter import complete_json
from .common import (
    CONTRACTS_DIR,
    PROMPTS_DIR,
    REPOSITORY_ROOT,
    SCHEMAS_DIR,
    ToolRouteBenchError,
    append_jsonl,
    git_commit,
    read_json,
    read_jsonl,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import load_benchmark_contract, load_tool_contract, validate_dataset

ALLOWED_STYLES = {
    "short_chat",
    "natural_chat",
    "formal",
    "informal",
    "elliptical",
    "minor_typo",
    "slang",
    "quoted_speech",
}


def build_plan() -> dict[str, Any]:
    benchmark = load_benchmark_contract()
    tools = load_tool_contract()["tool_order"]
    tasks: list[dict[str, Any]] = []

    def add(
        split: str,
        difficulty: str,
        count: int,
        gold: list[str],
        contrast: str | None = None,
    ) -> None:
        label = "normal" if not gold else "-and-".join(gold)
        suffix = f"-{contrast}" if contrast else ""
        task_id = f"{split}-{label}-{difficulty}{suffix}".replace("_", "-")
        tasks.append(
            {
                "task_id": task_id,
                "split": split,
                "track": "multi_label" if len(gold) > 1 else "single_tool",
                "difficulty": difficulty,
                "target_count": count,
                "gold_tool_ids": gold,
                **({"contrast_tool_id": contrast} if contrast else {}),
            }
        )

    authoring = benchmark["counts"]["authoring"]
    for tool in tools:
        for difficulty, count in authoring["positive_per_tool"].items():
            add("authoring", difficulty, count, [tool])
        for difficulty, count in authoring["contrast_normal_per_tool"].items():
            add("authoring", difficulty, count, [], tool)

    for split in ("dev", "holdout"):
        split_contract = benchmark["counts"][split]
        for tool in tools:
            for difficulty, count in split_contract["positive_per_tool"].items():
                add(split, difficulty, count, [tool])
        for index, difficulty in enumerate(
            (
                "mention_or_past",
                "negation",
                "capability_or_meta",
                "quoted_or_third_party",
                "hypothetical_or_wish",
                "semantic_boundary",
            )
        ):
            # Contrast tools rotate without making per-tool balance a frozen score.
            add(
                split,
                difficulty,
                split_contract["normal_per_difficulty"],
                [],
                tools[index % len(tools)],
            )

    pair_counts = benchmark["counts"]["multilabel_challenge"]["per_pair"]
    for left, right in itertools.combinations(tools, 2):
        for difficulty, count in pair_counts.items():
            add("multilabel_challenge", difficulty, count, [left, right])

    total = sum(task["target_count"] for task in tasks)
    if total != benchmark["counts"]["fixed_record_total"]:
        raise ToolRouteBenchError(f"authoring plan totals {total}, expected 615")
    return {
        "schema_version": "toolroutebench-authoring-plan-v1",
        "benchmark_version": benchmark["benchmark_version"],
        "created_at": utc_now(),
        "target_record_count": total,
        "benchmark_contract_sha256": sha256_file(
            CONTRACTS_DIR / "benchmark.v1.json"
        ),
        "tool_contract_sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
        "tasks": tasks,
    }


def write_plan(output: Path) -> Path:
    write_json(output, build_plan())
    return output.resolve()


def _render_template(path: Path, replacements: dict[str, str]) -> str:
    rendered = path.read_text(encoding="utf-8")
    for key, value in replacements.items():
        marker = "{{" + key + "}}"
        if rendered.count(marker) != 1:
            raise ToolRouteBenchError(f"{path}: expected one {marker} marker")
        rendered = rendered.replace(marker, value)
    if "{{" in rendered or "}}" in rendered:
        raise ToolRouteBenchError(f"{path}: unresolved template marker")
    return rendered


def _tool_prompt_contract() -> dict[str, Any]:
    contract = load_tool_contract()
    return {
        tool: contract["tools"][tool]["description_ko"]
        for tool in contract["tool_order"]
    }


def build_generator_prompt(task: dict[str, Any], count: int) -> str:
    return _render_template(
        PROMPTS_DIR / "generate.md",
        {
            "TASK_JSON": json.dumps(
                {
                    **task,
                    "requested_candidate_count": count,
                    "allowed_style_tags": sorted(ALLOWED_STYLES),
                },
                ensure_ascii=False,
                indent=2,
            ),
            "TOOL_CONTRACT_JSON": json.dumps(
                _tool_prompt_contract(), ensure_ascii=False, indent=2
            ),
        },
    )


def _validate_generated_candidate(candidate: dict[str, Any]) -> None:
    if not isinstance(candidate.get("utterance"), str) or not candidate["utterance"].strip():
        raise ToolRouteBenchError("generator returned an empty utterance")
    suffix = candidate.get("expression_family_suffix")
    if not isinstance(suffix, str) or not suffix or not all(
        character.islower() or character.isdigit() or character in "._-"
        for character in suffix
    ):
        raise ToolRouteBenchError("generator returned invalid expression family suffix")
    styles = candidate.get("style_tags")
    if (
        not isinstance(styles, list)
        or not styles
        or len(styles) != len(set(styles))
        or not set(styles) <= ALLOWED_STYLES
    ):
        raise ToolRouteBenchError("generator returned invalid style tags")


def generate_candidates(
    *,
    plan_path: Path,
    output_path: Path,
    calls_path: Path,
    splits: set[str],
    codex_bin: str,
    oversample_factor: float,
    timeout_seconds: float,
) -> Path:
    git_commit(require_clean=True)
    if oversample_factor < 1:
        raise ToolRouteBenchError("oversample factor must be at least one")
    plan = read_json(plan_path)
    if plan.get("schema_version") != "toolroutebench-authoring-plan-v1":
        raise ToolRouteBenchError("unsupported authoring plan")
    unknown = splits - {"authoring", "dev", "holdout", "multilabel_challenge"}
    if unknown:
        raise ToolRouteBenchError(f"unknown requested splits: {sorted(unknown)}")
    existing = read_jsonl(output_path) if output_path.exists() else []
    completed = {item["authoring_task_id"] for item in existing}
    candidates = list(existing)
    template = PROMPTS_DIR / "generate.md"
    schema = SCHEMAS_DIR / "generator-output.schema.json"
    for task in plan["tasks"]:
        if task["split"] not in splits or task["task_id"] in completed:
            continue
        count = math.ceil(task["target_count"] * oversample_factor)
        result, invocation = complete_json(
            prompt=build_generator_prompt(task, count),
            prompt_template=template,
            output_schema=schema,
            codex_bin=codex_bin,
            working_directory=REPOSITORY_ROOT,
            timeout_seconds=timeout_seconds,
        )
        rows = result.get("candidates")
        if not isinstance(rows, list) or len(rows) != count:
            raise ToolRouteBenchError(
                f"{task['task_id']}: expected {count} candidates"
            )
        batch_id = invocation.session_id
        for index, row in enumerate(rows, start=1):
            _validate_generated_candidate(row)
            candidate = {
                "candidate_id": f"{task['task_id']}-{index:03d}",
                "authoring_task_id": task["task_id"],
                "split": task["split"],
                "track": task["track"],
                "difficulty": task["difficulty"],
                "utterance": row["utterance"].strip(),
                "expression_family_id": (
                    f"{task['split']}.{task['task_id']}.{row['expression_family_suffix']}"
                ),
                "style_tags": row["style_tags"],
                "gold_tool_ids": task["gold_tool_ids"],
                **(
                    {"contrast_tool_id": task["contrast_tool_id"]}
                    if task.get("contrast_tool_id")
                    else {}
                ),
                "generation_batch_id": batch_id,
                "generator": invocation.provenance(),
            }
            candidates.append(candidate)
        write_jsonl(output_path, candidates, overwrite=output_path.exists())
        append_jsonl(
            calls_path,
            {
                "task_id": task["task_id"],
                "candidate_count": count,
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "provenance": invocation.provenance(),
            },
        )
    return output_path.resolve()


def build_validator_prompt(
    candidates: Iterable[dict[str, Any]], *, stage: str
) -> str:
    if stage not in {"contract", "blind"}:
        raise ToolRouteBenchError(f"unknown validator stage: {stage}")
    payload = [
        {"candidate_id": item["candidate_id"], "utterance": item["utterance"]}
        for item in candidates
    ]
    return _render_template(
        PROMPTS_DIR / f"validate_{stage}.md",
        {
            "CANDIDATES_JSON": json.dumps(payload, ensure_ascii=False, indent=2),
            "TOOL_CONTRACT_JSON": json.dumps(
                _tool_prompt_contract(), ensure_ascii=False, indent=2
            ),
        },
    )


def validate_candidates(
    *,
    candidates_path: Path,
    accepted_path: Path,
    rejected_path: Path,
    calls_path: Path,
    stage: str,
    codex_bin: str,
    batch_size: int,
    timeout_seconds: float,
) -> tuple[Path, Path]:
    git_commit(require_clean=True)
    if batch_size < 1:
        raise ToolRouteBenchError("validator batch size must be positive")
    candidates = read_jsonl(candidates_path)
    accepted: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    template = PROMPTS_DIR / f"validate_{stage}.md"
    schema = SCHEMAS_DIR / "validator-output.schema.json"
    provenance_key = f"{stage}_validator"
    batch_key = f"{stage}_validation_batch_id"
    for offset in range(0, len(candidates), batch_size):
        batch = candidates[offset : offset + batch_size]
        result, invocation = complete_json(
            prompt=build_validator_prompt(batch, stage=stage),
            prompt_template=template,
            output_schema=schema,
            codex_bin=codex_bin,
            working_directory=REPOSITORY_ROOT,
            timeout_seconds=timeout_seconds,
        )
        predictions = result.get("predictions")
        if not isinstance(predictions, list):
            raise ToolRouteBenchError("validator returned no predictions")
        by_id = {item.get("candidate_id"): item for item in predictions}
        if set(by_id) != {item["candidate_id"] for item in batch}:
            raise ToolRouteBenchError("validator candidate IDs differ from request")
        for candidate in batch:
            prediction = by_id[candidate["candidate_id"]]
            predicted = prediction.get("predicted_tool_ids")
            ambiguous = prediction.get("ambiguous")
            valid = (
                isinstance(predicted, list)
                and set(predicted) <= set(load_tool_contract()["tool_order"])
                and len(predicted) == len(set(predicted))
                and set(predicted) == set(candidate["gold_tool_ids"])
                and ambiguous is False
            )
            enriched = {
                **candidate,
                batch_key: invocation.session_id,
                provenance_key: invocation.provenance(),
                f"{stage}_prediction": {
                    "predicted_tool_ids": predicted,
                    "ambiguous": ambiguous,
                },
            }
            (accepted if valid else rejected).append(enriched)
        append_jsonl(
            calls_path,
            {
                "stage": stage,
                "batch_offset": offset,
                "candidate_count": len(batch),
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "provenance": invocation.provenance(),
            },
        )
    write_jsonl(accepted_path, accepted, overwrite=accepted_path.exists())
    write_jsonl(rejected_path, rejected, overwrite=rejected_path.exists())
    return accepted_path.resolve(), rejected_path.resolve()


def _freeze_dataset(
    *,
    plan_path: Path,
    accepted_path: Path,
    output_dir: Path,
    dataset_version: str,
    included_splits: tuple[str, ...],
    validation_profile: str,
) -> Path:
    git_commit(require_clean=True)
    plan = read_json(plan_path)
    accepted = read_jsonl(accepted_path)
    if output_dir.exists():
        raise ToolRouteBenchError(f"refusing to overwrite frozen dataset: {output_dir}")
    by_task: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for candidate in accepted:
        if candidate.get("split") not in included_splits:
            raise ToolRouteBenchError(
                "accepted candidates contain a split outside the freeze profile"
            )
        if "contract_validator" not in candidate or "blind_validator" not in candidate:
            raise ToolRouteBenchError("freeze requires both independent validations")
        sessions = {
            candidate["generator"]["session_id"],
            candidate["contract_validator"]["session_id"],
            candidate["blind_validator"]["session_id"],
        }
        if len(sessions) != 3:
            raise ToolRouteBenchError("generator and validators must use distinct sessions")
        by_task[candidate["authoring_task_id"]].append(candidate)

    selected: list[dict[str, Any]] = []
    seen_utterances: set[str] = set()
    split_indices: dict[str, int] = defaultdict(int)
    for task in plan["tasks"]:
        if task["split"] not in included_splits:
            continue
        rows = sorted(by_task[task["task_id"]], key=lambda item: item["candidate_id"])
        usable = []
        for row in rows:
            key = " ".join(row["utterance"].lower().split())
            if key in seen_utterances:
                continue
            seen_utterances.add(key)
            usable.append(row)
            if len(usable) == task["target_count"]:
                break
        if len(usable) != task["target_count"]:
            raise ToolRouteBenchError(
                f"{task['task_id']}: needs {task['target_count']} accepted candidates, "
                f"found {len(usable)}"
            )
        for row in usable:
            split_indices[row["split"]] += 1
            selected.append(
                {
                    "case_id": f"trb-{row['split'].replace('_', '-')}-{split_indices[row['split']]:04d}",
                    "dataset_version": dataset_version,
                    "split": row["split"],
                    "track": row["track"],
                    "expression_family_id": row["expression_family_id"],
                    "difficulty": row["difficulty"],
                    "utterance": row["utterance"],
                    "gold_tool_ids": row["gold_tool_ids"],
                    **(
                        {"contrast_tool_id": row["contrast_tool_id"]}
                        if row.get("contrast_tool_id")
                        else {}
                    ),
                    "style_tags": row["style_tags"],
                    "generation_batch_id": row["generation_batch_id"],
                    "contract_validation_batch_id": row[
                        "contract_validation_batch_id"
                    ],
                    "blind_validation_batch_id": row["blind_validation_batch_id"],
                    "provenance": {
                        "generator": row["generator"],
                        "contract_validator": row["contract_validator"],
                        "blind_validator": row["blind_validator"],
                        "ambiguous": False,
                    },
                }
            )
    validate_dataset(selected, profile=validation_profile)
    output_dir.mkdir(parents=True)
    split_metadata: dict[str, Any] = {}
    for split in included_splits:
        path = output_dir / f"{split}.jsonl"
        rows = [row for row in selected if row["split"] == split]
        write_jsonl(path, rows)
        split_metadata[split] = {
            "path": path.name,
            "records": len(rows),
            "sha256": sha256_file(path),
        }
    all_path = output_dir / "dataset.jsonl"
    write_jsonl(all_path, selected)
    manifest = {
        "schema_version": "toolroutebench-dataset-manifest-v1",
        "status": "valid",
        "profile": validation_profile,
        "included_splits": list(included_splits),
        "benchmark_version": load_benchmark_contract()["benchmark_version"],
        "dataset_version": dataset_version,
        "created_at": utc_now(),
        "records": len(selected),
        "dataset": {"path": all_path.name, "sha256": sha256_file(all_path)},
        "contracts": {
            "benchmark_sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
            "tools_sha256": sha256_file(CONTRACTS_DIR / "tools.v1.json"),
            "dataset_schema_sha256": sha256_file(
                CONTRACTS_DIR / "dataset.schema.json"
            ),
        },
        "splits": split_metadata,
    }
    write_json(output_dir / "dataset_manifest.json", manifest)
    return (output_dir / "dataset_manifest.json").resolve()


def freeze_dataset(
    *,
    plan_path: Path,
    accepted_path: Path,
    output_dir: Path,
    dataset_version: str,
) -> Path:
    return _freeze_dataset(
        plan_path=plan_path,
        accepted_path=accepted_path,
        output_dir=output_dir,
        dataset_version=dataset_version,
        included_splits=(
            "authoring",
            "dev",
            "holdout",
            "multilabel_challenge",
        ),
        validation_profile="full",
    )


def freeze_development_dataset(
    *,
    plan_path: Path,
    accepted_path: Path,
    output_dir: Path,
    dataset_version: str,
) -> Path:
    return _freeze_dataset(
        plan_path=plan_path,
        accepted_path=accepted_path,
        output_dir=output_dir,
        dataset_version=dataset_version,
        included_splits=("authoring", "dev"),
        validation_profile="development",
    )


def freeze_holdout_dataset(
    *,
    plan_path: Path,
    accepted_path: Path,
    output_dir: Path,
    dataset_version: str,
) -> Path:
    return _freeze_dataset(
        plan_path=plan_path,
        accepted_path=accepted_path,
        output_dir=output_dir,
        dataset_version=dataset_version,
        included_splits=("holdout",),
        validation_profile="holdout",
    )
