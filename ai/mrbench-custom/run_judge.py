from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path
from typing import Any

from common import (
    METRICS,
    ROOT,
    create_output_dir,
    load_json,
    load_jsonl,
    openai_chat_completion,
    optional_env,
    safe_endpoint_label,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from codex_cli_adapter import codex_cli_completion, codex_cli_version
from validate import validate_all


PAIR_METRICS = {"MS-FA": "anti", "MS-FU": "no_scene"}
RUBRIC_FILES = {
    "MS-FA": "ms_fa.md",
    "MS-FU": "ms_fu.md",
    "MB-AL": "mb_al.md",
    "MB-CR": "mb_cr.md",
    "ME-MAC": "me_mac.md",
    "ME-HLE": "me_hle.md",
}


def index_results(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for record in records:
        case_id = record.get("case_id")
        if not isinstance(case_id, str) or case_id in indexed:
            raise ValueError("generation results must have unique string case_id values")
        indexed[case_id] = record
    return indexed


def parse_judge_json(text: str) -> tuple[float, str]:
    stripped = text.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL)
    if fenced:
        stripped = fenced.group(1)
    value = json.loads(stripped)
    if not isinstance(value, dict):
        raise ValueError("judge output must be a JSON object")
    score = value.get("score")
    rationale = value.get("rationale")
    if not isinstance(score, (int, float)) or isinstance(score, bool) or not 1 <= score <= 10:
        raise ValueError("judge score must be a number from 1 to 10")
    if not isinstance(rationale, str) or not rationale.strip():
        raise ValueError("judge rationale must be non-empty text")
    return float(score), rationale.strip()


def build_judge_prompt(
    *,
    metric: str,
    rubric: str,
    persona: dict[str, Any],
    case: dict[str, Any],
    primary: dict[str, Any],
    comparison: dict[str, Any] | None,
) -> str:
    payload: dict[str, Any] = {
        "metric": metric,
        "ability": case["ability"],
        "canonical_persona": persona,
        "dialogue": case["dialogue"],
        "expected_contract": case["expected"],
        "candidate_reply": primary["response"],
    }
    if case["ability"] == "MS":
        payload["scene_facet"] = case["facet_id"]
    else:
        payload["boundary_type"] = case["boundary_type"]
        payload["paired_final_turns"] = case["paired_final_turns"]
    if comparison is not None:
        if metric == "MS-FA":
            payload["counter_facet_reply"] = comparison["response"]
        elif metric == "MS-FU":
            payload["facetless_reply"] = comparison["response"]
    return (
        "You are a strict role-playing benchmark evaluator. Evaluate only the supplied metric. "
        "Do not infer model identity or reward verbosity. Return exactly one JSON object with "
        'the shape {"score": <number 1-10>, "rationale": "<concise Korean rationale>"}.\n\n'
        f"RUBRIC\n{rubric}\n\nEVALUATION_INPUT\n"
        + json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Score MRBench-Custom generations with an automatic judge.")
    parser.add_argument(
        "--backend",
        choices=("codex-cli", "openai-compatible"),
        default="codex-cli",
    )
    parser.add_argument("--base-url")
    parser.add_argument("--model", default="gpt-5.6-luna")
    parser.add_argument("--reasoning-effort", choices=("low", "medium", "high", "xhigh"), default="low")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument(
        "--output-schema",
        type=Path,
        default=ROOT / "schemas/judge_response.schema.json",
    )
    parser.add_argument("--generation-dir", type=Path, required=True)
    parser.add_argument("--comparison-dir", type=Path)
    parser.add_argument("--metric", choices=METRICS, required=True)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/evaluation.jsonl")
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--selection-seed", type=int, default=42)
    parser.add_argument("--ability", choices=("MS", "MB"))
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def validate_backend_args(args: argparse.Namespace) -> None:
    if args.backend == "openai-compatible" and not args.base_url:
        raise ValueError("--base-url is required for the openai-compatible judge backend")
    if args.backend == "codex-cli" and args.base_url:
        raise ValueError("--base-url is not used by the codex-cli judge backend")


def validate_pair_manifests(
    primary: dict[str, Any],
    comparison: dict[str, Any],
    *,
    metric: str,
) -> None:
    expected_condition = PAIR_METRICS[metric]
    if primary.get("status") != "completed" or comparison.get("status") != "completed":
        raise ValueError("paired judge inputs must come from completed generation runs")
    if primary.get("memory_condition") != "full":
        raise ValueError(f"{metric} primary generation must use the full memory condition")
    if comparison.get("memory_condition") != expected_condition:
        raise ValueError(f"{metric} comparison generation must use {expected_condition}")
    matching_fields = (
        "dataset_sha256",
        "persona_format",
        "model_id",
        "model_artifact_sha256",
        "runtime",
        "runtime_version",
        "backend",
        "temperature",
        "max_tokens",
    )
    mismatched = [field for field in matching_fields if primary.get(field) != comparison.get(field)]
    if mismatched:
        raise ValueError(f"paired generation manifests differ in controlled fields: {mismatched}")


def main() -> int:
    args = parse_args()
    validate_all()
    validate_backend_args(args)
    requires_pair = args.metric in PAIR_METRICS
    if requires_pair and args.comparison_dir is None:
        raise ValueError(f"{args.metric} requires --comparison-dir")
    if not requires_pair and args.comparison_dir is not None:
        raise ValueError(f"{args.metric} does not accept --comparison-dir")
    primary_path = args.generation_dir / "results.jsonl"
    primary_manifest = load_json(args.generation_dir / "run_manifest.json")
    primary_records = index_results(load_jsonl(primary_path))
    comparison_records: dict[str, dict[str, Any]] = {}
    comparison_path: Path | None = None
    if args.comparison_dir is not None:
        comparison_path = args.comparison_dir / "results.jsonl"
        comparison_manifest = load_json(args.comparison_dir / "run_manifest.json")
        validate_pair_manifests(primary_manifest, comparison_manifest, metric=args.metric)
        comparison_records = index_results(load_jsonl(comparison_path))
    cases = {case["case_id"]: case for case in load_jsonl(args.dataset)}
    selected_ids = [
        case_id
        for case_id, case in cases.items()
        if args.metric in case["metrics"]
        and case_id in primary_records
        and (args.ability is None or case["ability"] == args.ability)
    ]
    if requires_pair:
        missing = set(selected_ids) - set(comparison_records)
        if missing:
            raise ValueError(f"comparison results missing cases: {sorted(missing)}")
    random.Random(args.selection_seed).shuffle(selected_ids)
    if not selected_ids:
        raise ValueError(f"no generation records selected for {args.metric}")

    persona = load_json(ROOT / "persona/canonical.json")
    rubric_path = ROOT / "rubrics" / RUBRIC_FILES[args.metric]
    rubric = rubric_path.read_text(encoding="utf-8").strip()
    create_output_dir(args.output_dir)
    judge_endpoint = safe_endpoint_label(args.base_url) if args.base_url else None
    cli_version = codex_cli_version(args.codex_bin) if args.backend == "codex-cli" else None
    manifest = {
        "schema_version": "mrbench-custom-judge-run-v0",
        "status": "running",
        "started_at": utc_now(),
        "score_label": "MRBench-Custom AutoJudge Raw Score",
        "human_calibration": False,
        "judge_model": args.model,
        "judge_backend": args.backend,
        "judge_temperature": 0,
        "judge_endpoint": judge_endpoint,
        "judge_reasoning_effort": args.reasoning_effort if args.backend == "codex-cli" else None,
        "codex_cli_version": cli_version,
        "codex_ephemeral": True if args.backend == "codex-cli" else None,
        "codex_ignore_user_config": True if args.backend == "codex-cli" else None,
        "codex_sandbox": "read-only" if args.backend == "codex-cli" else None,
        "output_schema_sha256": sha256_file(args.output_schema) if args.backend == "codex-cli" else None,
        "metric": args.metric,
        "rubric_sha256": sha256_file(rubric_path),
        "generation_results_sha256": sha256_file(primary_path),
        "comparison_results_sha256": sha256_file(comparison_path) if comparison_path else None,
        "selection_seed": args.selection_seed,
        "selected_count": len(selected_ids),
        "ability_filter": args.ability,
    }
    write_json(args.output_dir / "run_manifest.json", manifest)
    api_key = optional_env("MRBENCH_CUSTOM_JUDGE_API_KEY")
    results: list[dict[str, Any]] = []
    try:
        for index, case_id in enumerate(selected_ids, start=1):
            primary = primary_records[case_id]
            comparison = comparison_records.get(case_id)
            prompt = build_judge_prompt(
                metric=args.metric,
                rubric=rubric,
                persona=persona,
                case=cases[case_id],
                primary=primary,
                comparison=comparison,
            )
            if args.backend == "codex-cli":
                content, usage, timing = codex_cli_completion(
                    prompt=prompt,
                    model=args.model,
                    reasoning_effort=args.reasoning_effort,
                    output_schema=args.output_schema,
                    codex_bin=args.codex_bin,
                    working_directory=ROOT,
                    timeout_seconds=args.timeout_seconds,
                )
            else:
                content, usage, timing = openai_chat_completion(
                    base_url=args.base_url,
                    model=args.model,
                    messages=[{"role": "user", "content": prompt}],
                    temperature=0,
                    max_tokens=512,
                    api_key=api_key,
                    timeout_seconds=args.timeout_seconds,
                )
            score, rationale = parse_judge_json(content)
            results.append(
                {
                    "schema_version": "mrbench-custom-judge-result-v0",
                    "case_id": case_id,
                    "metric": args.metric,
                    "persona_format": primary["persona_format"],
                    "memory_condition": primary["memory_condition"],
                    "score": score,
                    "rationale": rationale,
                    "usage": usage,
                    "timing": timing,
                }
            )
            print(f"[{index}/{len(selected_ids)}] {case_id}", file=sys.stderr)
    except Exception:
        if results:
            write_jsonl(args.output_dir / "partial_results.jsonl", results)
        manifest["status"] = "failed"
        manifest["completed_count"] = len(results)
        manifest["finished_at"] = utc_now()
        write_json(args.output_dir / "run_manifest.json", manifest)
        raise

    result_path = args.output_dir / "results.jsonl"
    write_jsonl(result_path, results)
    manifest["status"] = "completed"
    manifest["completed_count"] = len(results)
    manifest["finished_at"] = utc_now()
    manifest["results_sha256"] = sha256_file(result_path)
    write_json(args.output_dir / "run_manifest.json", manifest)
    print(json.dumps({"completed": len(results), "output_dir": str(args.output_dir)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
