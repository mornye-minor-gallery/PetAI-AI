from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from common import (
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


DEFAULT_ROUTE_TO_FACET = {
    "FIRST_CONTACT": "first_contact",
    "EARTH_CULTURE": "earth_culture_unknown",
    "AMBIGUOUS": "ambiguous_direction",
    "RETURN_TWIN": "return_or_twin",
    "SUPPORT": "user_needs_support",
    "PLAYFUL": "playful_exchange",
    "GENERAL": None,
}


def parse_route(text: str, allowed_routes: set[str] | None = None) -> str | None:
    routes = allowed_routes or set(DEFAULT_ROUTE_TO_FACET)
    pattern = re.compile(r"\b(" + "|".join(map(re.escape, sorted(routes, key=len, reverse=True))) + r")\b")
    matches = pattern.findall(text.upper())
    return matches[0] if len(set(matches)) == 1 else None


def load_facet_cards(path: Path) -> tuple[dict[str, str | None], dict[str, str | None]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    expected = {facet_id for facet_id in DEFAULT_ROUTE_TO_FACET.values() if facet_id}
    if isinstance(value, dict) and set(value) == expected and all(isinstance(card, str) and card.strip() for card in value.values()):
        route_facets = dict(DEFAULT_ROUTE_TO_FACET)
        route_cards = {
            route: value[facet_id] if facet_id else None
            for route, facet_id in route_facets.items()
        }
        return route_facets, route_cards
    if not isinstance(value, dict) or "GENERAL" not in value:
        raise ValueError("granular route cards must be an object containing GENERAL")
    route_facets: dict[str, str | None] = {}
    route_cards: dict[str, str | None] = {}
    for route, config in value.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", route) or not isinstance(config, dict):
            raise ValueError(f"invalid granular route entry: {route}")
        facet_id = config.get("facet_id")
        card = config.get("card")
        if facet_id is not None and facet_id not in expected:
            raise ValueError(f"unknown facet_id for route {route}: {facet_id}")
        if card is not None and (not isinstance(card, str) or not card.strip()):
            raise ValueError(f"invalid card for route {route}")
        if facet_id is not None and card is None:
            raise ValueError(f"route {route} with a scene facet must provide a card")
        route_facets[route] = facet_id
        route_cards[route] = card
    return route_facets, route_cards


def route_to_card(route: str, cards: dict[str, str | None]) -> str | None:
    return cards[route]


def parse_boundary_route(text: str) -> str | None:
    matches = re.findall(r"\b(BOUNDARY|IN_SCOPE)\b", text.upper())
    return matches[0] if len(set(matches)) == 1 else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run two-pass routed MRBench-Custom generation.")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-artifact", type=Path, required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--runtime-version", default="unknown")
    parser.add_argument("--backend", required=True)
    parser.add_argument("--persona-prompt", type=Path, required=True)
    parser.add_argument("--router-prompt", type=Path, default=ROOT / "prompts/router/scene-v1.md")
    parser.add_argument("--facet-cards", type=Path, required=True)
    parser.add_argument("--boundary-router-prompt", type=Path)
    parser.add_argument("--boundary-card", type=Path)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/evaluation.jsonl")
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--router-max-tokens", type=int, default=16)
    parser.add_argument("--ability", choices=("MS", "MB", "all"), default="MS")
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if (args.boundary_router_prompt is None) != (args.boundary_card is None):
        raise ValueError("--boundary-router-prompt and --boundary-card must be used together")
    validate_all()
    for path in (
        args.model_artifact,
        args.persona_prompt,
        args.router_prompt,
        args.facet_cards,
        args.dataset,
        *([args.boundary_router_prompt, args.boundary_card] if args.boundary_router_prompt else []),
    ):
        if not path.is_file():
            raise FileNotFoundError(path)
    cases = [
        case
        for case in load_jsonl(args.dataset)
        if args.ability == "all" or case.get("ability") == args.ability
    ]
    persona_prompt = args.persona_prompt.read_text(encoding="utf-8").strip()
    router_prompt = args.router_prompt.read_text(encoding="utf-8").strip()
    boundary_router_prompt = args.boundary_router_prompt.read_text(encoding="utf-8").strip() if args.boundary_router_prompt else None
    boundary_card = args.boundary_card.read_text(encoding="utf-8").strip() if args.boundary_card else None
    route_facets, route_cards = load_facet_cards(args.facet_cards)
    core_id = f"{args.persona_prompt.parent.name}-{args.persona_prompt.stem}"
    pass_id = f"hierarchical-{args.boundary_router_prompt.stem}" if args.boundary_router_prompt else "two-pass"
    experiment_id = f"{pass_id}-{core_id}-{args.router_prompt.stem}-{args.facet_cards.stem}"
    create_output_dir(args.output_dir)
    started_at = utc_now()
    manifest = {
        "schema_version": "mrbench-custom-routed-generation-run-v0",
        "status": "running",
        "started_at": started_at,
        "dataset": str(args.dataset),
        "dataset_sha256": sha256_file(args.dataset),
        "persona_format": experiment_id,
        "memory_condition": "full",
        "persona_prompt": str(args.persona_prompt),
        "persona_prompt_sha256": sha256_file(args.persona_prompt),
        "router_prompt": str(args.router_prompt),
        "router_prompt_sha256": sha256_file(args.router_prompt),
        "facet_cards": str(args.facet_cards),
        "facet_cards_sha256": sha256_file(args.facet_cards),
        "boundary_router_prompt": str(args.boundary_router_prompt) if args.boundary_router_prompt else None,
        "boundary_router_prompt_sha256": sha256_file(args.boundary_router_prompt) if args.boundary_router_prompt else None,
        "boundary_card": str(args.boundary_card) if args.boundary_card else None,
        "boundary_card_sha256": sha256_file(args.boundary_card) if args.boundary_card else None,
        "model_id": args.model,
        "model_artifact_sha256": sha256_file(args.model_artifact),
        "runtime": args.runtime,
        "runtime_version": args.runtime_version,
        "backend": args.backend,
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
        "router_temperature": 0,
        "router_max_tokens": args.router_max_tokens,
        "endpoint": safe_endpoint_label(args.base_url),
        "request_count": len(cases),
        "ability_filter": args.ability,
        "inference_passes_per_case": "2_or_3" if args.boundary_router_prompt else 2,
    }
    write_json(args.output_dir / "run_manifest.json", manifest)
    api_key = optional_env("MRBENCH_CUSTOM_TARGET_API_KEY")
    results: list[dict[str, Any]] = []
    try:
        for index, case in enumerate(cases, start=1):
            dialogue = case["dialogue"]
            boundary_text = None
            boundary_usage: dict[str, Any] = {}
            boundary_timing = {"elapsed_ms": 0.0}
            boundary_route = "IN_SCOPE"
            if boundary_router_prompt:
                boundary_text, boundary_usage, boundary_timing = openai_chat_completion(
                    base_url=args.base_url,
                    model=args.model,
                    messages=[{"role": "system", "content": boundary_router_prompt}, *dialogue],
                    temperature=0,
                    max_tokens=args.router_max_tokens,
                    api_key=api_key,
                    timeout_seconds=args.timeout_seconds,
                )
                boundary_route = parse_boundary_route(boundary_text) or "IN_SCOPE"
            route_text = None
            route_usage: dict[str, Any] = {}
            route_timing = {"elapsed_ms": 0.0}
            if boundary_route == "BOUNDARY":
                route = "BOUNDARY_UNKNOWN"
                card = boundary_card
            else:
                route_text, route_usage, route_timing = openai_chat_completion(
                    base_url=args.base_url,
                    model=args.model,
                    messages=[{"role": "system", "content": router_prompt}, *dialogue],
                    temperature=0,
                    max_tokens=args.router_max_tokens,
                    api_key=api_key,
                    timeout_seconds=args.timeout_seconds,
                )
                route = parse_route(route_text, set(route_facets)) or "GENERAL"
                card = route_to_card(route, route_cards)
            active_prompt = persona_prompt
            if card:
                active_prompt += (
                    "\n\n## 이번 응답의 활성 장면 카드\n"
                    + card
                    + " 다른 장면 규칙은 이번 응답에 사용하지 않는다."
                )
            response, response_usage, response_timing = openai_chat_completion(
                base_url=args.base_url,
                model=args.model,
                messages=[{"role": "system", "content": active_prompt}, *dialogue],
                temperature=args.temperature,
                max_tokens=args.max_tokens,
                api_key=api_key,
                timeout_seconds=args.timeout_seconds,
            )
            results.append(
                {
                    "schema_version": "mrbench-custom-generation-result-v0",
                    "case_id": case["case_id"],
                    "ability": case["ability"],
                    "facet_id": case.get("facet_id"),
                    "boundary_type": case.get("boundary_type"),
                    "metrics": case["metrics"],
                    "persona_format": experiment_id,
                    "memory_condition": "full",
                    "route": route,
                    "route_raw": route_text,
                    "boundary_route": boundary_route if boundary_router_prompt else None,
                    "boundary_route_raw": boundary_text,
                    "boundary_correct": (
                        (boundary_route == "BOUNDARY") == (case.get("ability") == "MB")
                        if boundary_router_prompt
                        else None
                    ),
                    "route_correct": (
                        boundary_route != "BOUNDARY" and route_facets[route] == case.get("facet_id")
                        if case.get("facet_id") is not None
                        else None
                    ),
                    "response": response,
                    "usage": {"boundary_route": boundary_usage, "route": route_usage, "response": response_usage},
                    "timing": {
                        "boundary_route_elapsed_ms": boundary_timing["elapsed_ms"],
                        "scene_route_elapsed_ms": route_timing["elapsed_ms"],
                        "route_elapsed_ms": boundary_timing["elapsed_ms"] + route_timing["elapsed_ms"],
                        "response_elapsed_ms": response_timing["elapsed_ms"],
                        "elapsed_ms": boundary_timing["elapsed_ms"] + route_timing["elapsed_ms"] + response_timing["elapsed_ms"],
                    },
                }
            )
            print(
                f"[{index}/{len(cases)}] {case['case_id']} route={route} "
                f"correct={results[-1]['route_correct']}",
                file=sys.stderr,
            )
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
    scored_routes = [row["route_correct"] for row in results if row["route_correct"] is not None]
    manifest["route_accuracy"] = sum(scored_routes) / len(scored_routes) if scored_routes else None
    manifest["finished_at"] = utc_now()
    manifest["results_sha256"] = sha256_file(result_path)
    write_json(args.output_dir / "run_manifest.json", manifest)
    print(json.dumps({"completed": len(results), "route_accuracy": manifest["route_accuracy"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
