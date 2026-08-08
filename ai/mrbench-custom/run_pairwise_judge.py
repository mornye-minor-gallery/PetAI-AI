from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

from codex_cli_adapter import codex_cli_completion, codex_cli_version
from common import ROOT, create_output_dir, load_json, load_jsonl, sha256_file, utc_now, write_json, write_jsonl
from run_judge import RUBRIC_FILES, index_results
from validate import validate_all


def parse_pairwise_json(text: str) -> tuple[str, str]:
    stripped = text.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL)
    if fenced:
        stripped = fenced.group(1)
    value = json.loads(stripped)
    if not isinstance(value, dict) or value.get("winner") not in {"A", "B", "tie"}:
        raise ValueError("pairwise judge winner must be A, B, or tie")
    rationale = value.get("rationale")
    if not isinstance(rationale, str) or not rationale.strip():
        raise ValueError("pairwise judge rationale must be non-empty")
    return value["winner"], rationale.strip()


def presentation_order(case_id: str, seed: int, repetition: int = 0) -> tuple[str, str]:
    digest = hashlib.sha256(f"{seed}:{case_id}".encode()).digest()
    base = ("primary", "challenger") if digest[0] % 2 == 0 else ("challenger", "primary")
    return base if repetition % 2 == 0 else (base[1], base[0])


def build_pairwise_prompt(
    *,
    metric: str,
    rubric: str,
    persona: dict[str, Any],
    case: dict[str, Any],
    reply_a: str,
    reply_b: str,
) -> str:
    payload = {
        "metric": metric,
        "canonical_persona": persona,
        "scene_facet": case["facet_id"],
        "dialogue": case["dialogue"],
        "expected_contract": case["expected"],
        "reply_A": reply_a,
        "reply_B": reply_b,
    }
    return (
        "You are a strict blinded role-playing benchmark evaluator. Compare only the two supplied replies "
        "under the supplied metric and contract. Do not reward verbosity. Choose tie only when neither reply "
        "has a meaningful advantage. Return exactly one JSON object shaped as "
        '{"winner":"A|B|tie","rationale":"concise Korean rationale"}.\n\n'
        f"RUBRIC\n{rubric}\n\nEVALUATION_INPUT\n"
        + json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Blindly compare two MRBench-Custom generation runs.")
    parser.add_argument("--primary-dir", type=Path, required=True)
    parser.add_argument("--challenger-dir", type=Path, required=True)
    parser.add_argument("--metric", choices=("ME-MAC", "ME-HLE"), required=True)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/evaluation.jsonl")
    parser.add_argument("--model", default="gpt-5.6-luna")
    parser.add_argument("--reasoning-effort", choices=("low", "medium", "high", "xhigh"), default="low")
    parser.add_argument("--codex-bin", default="codex")
    parser.add_argument("--output-schema", type=Path, default=ROOT / "schemas/pairwise_judge_response.schema.json")
    parser.add_argument("--selection-seed", type=int, default=42)
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--changed-only", action="store_true")
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.repetitions < 1:
        raise ValueError("--repetitions must be at least 1")
    validate_all()
    primary_path = args.primary_dir / "results.jsonl"
    challenger_path = args.challenger_dir / "results.jsonl"
    primary = index_results(load_jsonl(primary_path))
    challenger = index_results(load_jsonl(challenger_path))
    cases = {row["case_id"]: row for row in load_jsonl(args.dataset)}
    selected_ids = [
        case_id
        for case_id, case in cases.items()
        if case["ability"] == "MS"
        and args.metric in case["metrics"]
        and case_id in primary
        and case_id in challenger
        and (not args.changed_only or primary[case_id]["response"] != challenger[case_id]["response"])
    ]
    if not selected_ids:
        raise ValueError("no matching pairwise cases selected")
    rubric_path = ROOT / "rubrics" / RUBRIC_FILES[args.metric]
    rubric = rubric_path.read_text(encoding="utf-8").strip()
    persona = load_json(ROOT / "persona/canonical.json")
    create_output_dir(args.output_dir)
    manifest = {
        "schema_version": "mrbench-custom-pairwise-judge-run-v0",
        "status": "running",
        "started_at": utc_now(),
        "judge_model": args.model,
        "judge_backend": "codex-cli",
        "judge_reasoning_effort": args.reasoning_effort,
        "codex_cli_version": codex_cli_version(args.codex_bin),
        "codex_ephemeral": True,
        "codex_ignore_user_config": True,
        "codex_sandbox": "read-only",
        "metric": args.metric,
        "rubric_sha256": sha256_file(rubric_path),
        "output_schema_sha256": sha256_file(args.output_schema),
        "primary_results_sha256": sha256_file(primary_path),
        "challenger_results_sha256": sha256_file(challenger_path),
        "selection_seed": args.selection_seed,
        "repetitions": args.repetitions,
        "changed_only": args.changed_only,
        "selected_case_count": len(selected_ids),
        "selected_count": len(selected_ids) * args.repetitions,
    }
    write_json(args.output_dir / "run_manifest.json", manifest)
    results: list[dict[str, Any]] = []
    try:
        total = len(selected_ids) * args.repetitions
        index = 0
        for case_id in selected_ids:
            for repetition in range(args.repetitions):
                index += 1
                order = presentation_order(case_id, args.selection_seed, repetition)
                replies = {"primary": primary[case_id]["response"], "challenger": challenger[case_id]["response"]}
                prompt = build_pairwise_prompt(
                    metric=args.metric,
                    rubric=rubric,
                    persona=persona,
                    case=cases[case_id],
                    reply_a=replies[order[0]],
                    reply_b=replies[order[1]],
                )
                content, usage, timing = codex_cli_completion(
                    prompt=prompt,
                    model=args.model,
                    reasoning_effort=args.reasoning_effort,
                    output_schema=args.output_schema,
                    codex_bin=args.codex_bin,
                    working_directory=ROOT,
                    timeout_seconds=args.timeout_seconds,
                )
                presented_winner, rationale = parse_pairwise_json(content)
                winner = "tie" if presented_winner == "tie" else order[0 if presented_winner == "A" else 1]
                results.append({
                    "schema_version": "mrbench-custom-pairwise-judge-result-v0",
                    "case_id": case_id,
                    "repetition": repetition + 1,
                    "metric": args.metric,
                    "presentation": {"A": order[0], "B": order[1]},
                    "winner": winner,
                    "rationale": rationale,
                    "usage": usage,
                    "timing": timing,
                })
                print(f"[{index}/{total}] {case_id} rep={repetition + 1} winner={winner}", file=sys.stderr)
    except Exception:
        if results:
            write_jsonl(args.output_dir / "partial_results.jsonl", results)
        manifest.update(status="failed", completed_count=len(results), finished_at=utc_now())
        write_json(args.output_dir / "run_manifest.json", manifest)
        raise
    write_jsonl(args.output_dir / "results.jsonl", results)
    raw_wins = {name: sum(row["winner"] == name for row in results) for name in ("primary", "challenger", "tie")}
    case_majorities: dict[str, str] = {}
    for case_id in selected_ids:
        votes = [row["winner"] for row in results if row["case_id"] == case_id]
        counts = {name: votes.count(name) for name in ("primary", "challenger", "tie")}
        highest = max(counts.values())
        leaders = [name for name, count in counts.items() if count == highest]
        case_majorities[case_id] = leaders[0] if len(leaders) == 1 else "tie"
    majority_wins = {name: sum(winner == name for winner in case_majorities.values()) for name in ("primary", "challenger", "tie")}
    manifest.update(status="completed", completed_count=len(results), raw_wins=raw_wins, case_majorities=case_majorities, majority_wins=majority_wins, finished_at=utc_now())
    write_json(args.output_dir / "run_manifest.json", manifest)
    print(json.dumps({"completed": len(results), "raw_wins": raw_wins, "majority_wins": majority_wins}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
