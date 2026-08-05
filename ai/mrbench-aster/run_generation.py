from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from common import (
    CONDITIONS,
    FORMATS,
    ROOT,
    create_output_dir,
    load_jsonl,
    openai_chat_completion,
    optional_env,
    safe_endpoint_label,
    sha256_file,
    utc_now,
    write_json,
    write_jsonl,
)
from validate import validate_all


FACET_CARDS = {
    "first_contact": "아스테르라고 소개하고 교신에 응답한 사용자를 밝게 반긴다.",
    "earth_culture_unknown": (
        "처음 보는 지구 말·관계·음식을 아는 척하지 말고 해당 뜻·쓰임·맛을 질문한다. "
        "나침반은 사용하지 않는다."
    ),
    "ambiguous_direction": (
        "첫 문장에서 나침반 확인을 언급한다. 사용자가 제시한 두 가능성을 모두 말하고 "
        "판단에 필요한 단서 하나만 질문한다."
    ),
    "return_or_twin": (
        "아는 범위만 말한다. 쌍둥이의 위치·상태, 파장의 발신자, 귀환 방법을 확정하지 "
        "말고 불안을 가볍게 감춘다."
    ),
    "user_needs_support": (
        "사용자의 감정을 먼저 인정하고 명확히 요청한 도움만 따른다. 원하는 도움이 "
        "모호할 때만 나침반을 사용한다."
    ),
    "playful_exchange": (
        "장난을 밝고 능글맞게 받아치며 속마음을 전부 설명하지 않는다."
    ),
}


def build_requests(
    cases: list[dict],
    *,
    system_prompt: str,
    persona_format: str,
    memory_condition: str,
    inject_facet_hint: bool = False,
    inject_facet_card: bool = False,
) -> list[dict]:
    if inject_facet_hint and inject_facet_card:
        raise ValueError("facet ID and facet card oracle modes are mutually exclusive")
    requests: list[dict] = []
    for case in cases:
        case_prompt = system_prompt
        facet_hint_mode = "none"
        if inject_facet_hint and case.get("ability") == "MS":
            facet_id = case.get("facet_id")
            case_prompt += (
                "\n\n## Active Scene Facet\n"
                f"현재 대화에서는 `{facet_id}` Scene Facet만 활성화한다. "
                "그 Facet의 behavior_pattern과 Knowledge Boundaries를 적용해 답한다."
            )
            facet_hint_mode = "evaluation_oracle_id"
        elif inject_facet_card and case.get("ability") == "MS":
            facet_id = case.get("facet_id")
            case_prompt += (
                "\n\n## 이번 응답의 활성 장면 카드\n"
                + FACET_CARDS[facet_id]
                + " 다른 장면 규칙은 이번 응답에 사용하지 않는다."
            )
            facet_hint_mode = "evaluation_oracle_card"
        requests.append(
            {
                "case_id": case["case_id"],
                "ability": case["ability"],
                "facet_id": case.get("facet_id"),
                "boundary_type": case.get("boundary_type"),
                "metrics": case["metrics"],
                "persona_format": persona_format,
                "memory_condition": memory_condition,
                "facet_hint_mode": facet_hint_mode,
                "messages": [{"role": "system", "content": case_prompt}, *case["dialogue"]],
            }
        )
    return requests


def select_cases_for_condition(cases: list[dict], memory_condition: str) -> list[dict]:
    if memory_condition == "full":
        return cases
    return [case for case in cases if case.get("ability") == "MS"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run MRBench-Aster target generations.")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-artifact", type=Path)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--runtime-version", default="unknown")
    parser.add_argument("--backend", required=True)
    prompt_source = parser.add_mutually_exclusive_group(required=True)
    prompt_source.add_argument("--persona-format", choices=FORMATS)
    prompt_source.add_argument("--prompt-file", type=Path)
    parser.add_argument(
        "--prompt-id",
        help="Versioned label required when --prompt-file is used.",
    )
    parser.add_argument(
        "--inject-facet-card",
        action="store_true",
        help="Diagnostic oracle: inject the active facet's static behavior card for MS cases.",
    )
    parser.add_argument("--memory-condition", choices=CONDITIONS, required=True)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/evaluation.jsonl")
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument(
        "--inject-facet-hint",
        action="store_true",
        help="Diagnostic oracle: inject each MS case's gold facet ID into the system prompt.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    validate_all()
    if args.model_artifact is not None and not args.model_artifact.is_file():
        raise FileNotFoundError(f"model artifact does not exist: {args.model_artifact}")
    if args.prompt_file is not None:
        if not args.prompt_id:
            raise ValueError("--prompt-id is required with --prompt-file")
        prompt_path = args.prompt_file.expanduser().resolve()
        try:
            prompt_label = str(prompt_path.relative_to(ROOT))
        except ValueError as exc:
            raise ValueError("--prompt-file must be inside MRBench-Aster") from exc
        persona_format = args.prompt_id
    else:
        if args.prompt_id:
            raise ValueError("--prompt-id is only valid with --prompt-file")
        prompt_path = ROOT / "prompts" / args.persona_format / f"{args.memory_condition}.md"
        prompt_label = str(prompt_path.relative_to(ROOT))
        persona_format = args.persona_format
    if not prompt_path.is_file():
        raise FileNotFoundError(f"prompt does not exist: {prompt_path}")
    system_prompt = prompt_path.read_text(encoding="utf-8").strip()
    cases = select_cases_for_condition(load_jsonl(args.dataset), args.memory_condition)
    requests = build_requests(
        cases,
        system_prompt=system_prompt,
        persona_format=persona_format,
        memory_condition=args.memory_condition,
        inject_facet_hint=args.inject_facet_hint,
        inject_facet_card=args.inject_facet_card,
    )
    create_output_dir(args.output_dir)
    started_at = utc_now()
    request_path = args.output_dir / "requests.jsonl"
    write_jsonl(request_path, requests)
    manifest = {
        "schema_version": "mrbench-aster-generation-run-v0",
        "status": "prepared" if args.prepare_only else "running",
        "started_at": started_at,
        "benchmark_manifest_sha256": sha256_file(ROOT / "benchmark_manifest.json"),
        "dataset": str(args.dataset),
        "dataset_sha256": sha256_file(args.dataset),
        "prompt": prompt_label,
        "prompt_sha256": sha256_file(prompt_path),
        "persona_format": persona_format,
        "memory_condition": args.memory_condition,
        "model_id": args.model,
        "model_artifact_sha256": sha256_file(args.model_artifact) if args.model_artifact else None,
        "runtime": args.runtime,
        "runtime_version": args.runtime_version,
        "backend": args.backend,
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
        "endpoint": safe_endpoint_label(args.base_url),
        "request_count": len(requests),
        "facet_hint_mode": (
            "evaluation_oracle_card"
            if args.inject_facet_card
            else "evaluation_oracle_id"
            if args.inject_facet_hint
            else "none"
        ),
        "requests_sha256": sha256_file(request_path),
    }
    write_json(args.output_dir / "run_manifest.json", manifest)
    if args.prepare_only:
        print(f"prepared {len(requests)} requests in {args.output_dir}")
        return 0

    api_key = optional_env("MRBENCH_ASTER_TARGET_API_KEY")
    results: list[dict] = []
    try:
        for index, request in enumerate(requests, start=1):
            content, usage, timing = openai_chat_completion(
                base_url=args.base_url,
                model=args.model,
                messages=request["messages"],
                temperature=args.temperature,
                max_tokens=args.max_tokens,
                api_key=api_key,
                timeout_seconds=args.timeout_seconds,
            )
            record = {
                "schema_version": "mrbench-aster-generation-result-v0",
                "case_id": request["case_id"],
                "ability": request["ability"],
                "facet_id": request["facet_id"],
                "boundary_type": request["boundary_type"],
                "metrics": request["metrics"],
                "persona_format": persona_format,
                "memory_condition": args.memory_condition,
                "facet_hint_mode": request["facet_hint_mode"],
                "response": content,
                "usage": usage,
                "timing": timing,
            }
            results.append(record)
            print(f"[{index}/{len(requests)}] {request['case_id']}", file=sys.stderr)
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
