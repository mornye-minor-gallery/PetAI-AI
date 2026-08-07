from __future__ import annotations

import json
import math
from collections import Counter, defaultdict
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from .codex_adapter import complete_json
from .common import (
    CONTRACTS_DIR,
    PROMPTS_DIR,
    REPO_ROOT,
    SCHEMAS_DIR,
    FacetRouteBenchError,
    canonical_json,
    chunked,
    conversation_text,
    final_user_text,
    normalized_text,
    read_json,
    read_jsonl,
    sha256_file,
    sha256_text,
    utc_now,
    write_json,
    write_jsonl,
)
from .contracts import (
    load_benchmark_contract,
    load_route_contract,
    validate_dataset_counts,
    validate_record_schema,
)

ALLOWED_STYLES = {
    "short_chat",
    "daily_natural",
    "emotional",
    "narrative",
    "formal",
    "informal",
    "elliptical",
    "indirect",
    "minor_typo",
}
ALLOWED_DOMAINS = {"narrative", "shared_daily", "mixed"}
GENERAL_HARD_NEGATIVE_DOMAINS = ("shared_daily", "narrative", "mixed")
PERSONA_CORE_PATH = (
    REPO_ROOT
    / "ios/EdgeLLM/Sources/EdgeLLM/Resources/Prompts/RoutedPersona/persona_core.md"
)


def _domain_targets(
    count: int, benchmark: dict[str, Any]
) -> tuple[tuple[str, int], ...]:
    distributions = benchmark["authoring"]["domain_allocation_by_cell_size"]
    try:
        allocation = distributions[str(count)]
    except KeyError as error:
        raise FacetRouteBenchError(
            f"no preregistered domain allocation for target count {count}"
        ) from error
    if set(allocation) != ALLOWED_DOMAINS or sum(allocation.values()) != count:
        raise FacetRouteBenchError(
            f"invalid preregistered domain allocation for target count {count}"
        )
    return tuple((domain, allocation[domain]) for domain in sorted(allocation))


def _oversampled_domain_targets(
    task: dict[str, Any], oversample_factor: float
) -> dict[str, int]:
    desired_total = math.ceil(task["target_count"] * oversample_factor)
    scaled = {
        domain: target * oversample_factor
        for domain, target in task["domain_targets"].items()
    }
    desired = {domain: math.floor(value) for domain, value in scaled.items()}
    remainder = desired_total - sum(desired.values())
    order = sorted(scaled, key=lambda domain: (-(scaled[domain] % 1), domain))
    for domain in order[:remainder]:
        desired[domain] += 1
    if any(desired[domain] < target for domain, target in task["domain_targets"].items()):
        raise FacetRouteBenchError("oversampling cannot reduce a domain below target")
    return desired


def build_plan() -> dict[str, Any]:
    benchmark = load_benchmark_contract()
    route_contract = load_route_contract()
    routes = route_contract["route_order"]
    tasks: list[dict[str, Any]] = []

    def add_task(split: str, route: str, difficulty: str, count: int) -> None:
        tasks.append(
            {
                "task_id": f"{split}-{route.lower()}-{difficulty}",
                "split": split,
                "track": (
                    "context_challenge"
                    if split == "context_challenge"
                    else "single_turn"
                ),
                "gold_route_id": route,
                "facet_id": route_contract["routes"][route]["facet_id"],
                "difficulty": difficulty,
                "domain_targets": dict(_domain_targets(count, benchmark)),
                "target_count": count,
            }
        )

    for split, count in (("authoring", 4), ("dev", 8), ("frozen", 8)):
        for route in routes[:-1]:
            for difficulty in ("direct", "natural", "neighbor"):
                add_task(split, route, difficulty, count)

    add_task("authoring", "GENERAL", "general", 120)
    # Six routes receive one extra example so 19 route-boundary tasks total 120.
    # The extras rotate across domains, preserving the global 40/40/40 contract.
    for index, contrast_route in enumerate(routes[:-1]):
        domain_targets = {domain: 2 for domain in GENERAL_HARD_NEGATIVE_DOMAINS}
        if index < 6:
            domain_targets[GENERAL_HARD_NEGATIVE_DOMAINS[index // 2]] += 1
        target_count = sum(domain_targets.values())
        tasks.append(
            {
                "task_id": (
                    "authoring-general-hard-negative-"
                    + contrast_route.lower().replace("_", "-")
                ),
                "split": "authoring",
                "track": "single_turn",
                "gold_route_id": "GENERAL",
                "facet_id": None,
                "difficulty": "hard_negative",
                "domain_targets": domain_targets,
                "target_count": target_count,
                "contrast_route_id": contrast_route,
            }
        )
    for split in ("dev", "frozen"):
        add_task(split, "GENERAL", "general", 120)
        add_task(split, "GENERAL", "hard_negative", 120)
    for route in routes:
        add_task("context_challenge", route, "context_dependent", 3)

    if sum(task["target_count"] for task in tasks) != 1920:
        raise FacetRouteBenchError("authoring plan does not total 1,920 records")
    return {
        "schema_version": "facetroutebench-authoring-plan-v3",
        "benchmark_version": benchmark["benchmark_version"],
        "created_at": utc_now(),
        "route_contract_sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
        "benchmark_contract_sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
        "persona_core_path": str(PERSONA_CORE_PATH.relative_to(REPO_ROOT)),
        "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
        "oversample_factor": benchmark["authoring"]["oversample_factor"],
        "target_record_count": 1920,
        "tasks": tasks,
    }


def write_plan(output: Path) -> Path:
    write_json(output, build_plan())
    return output.resolve()


def refill_requests(
    plan: dict[str, Any], accepted: Sequence[dict[str, Any]]
) -> list[dict[str, Any]]:
    accepted_counts = Counter(
        (item.get("authoring_task_id"), item.get("domain")) for item in accepted
    )
    requests: list[dict[str, Any]] = []
    for task in plan["tasks"]:
        for domain, target in sorted(task["domain_targets"].items()):
            shortage = target - accepted_counts[(task["task_id"], domain)]
            if shortage > 0:
                requests.append(
                    {
                        "task_id": task["task_id"],
                        "domain": domain,
                        "count": shortage,
                    }
                )
    return requests


def _render_template(path: Path, replacements: dict[str, str]) -> str:
    rendered = path.read_text(encoding="utf-8")
    for marker, value in replacements.items():
        token = "{{" + marker + "}}"
        if rendered.count(token) != 1:
            raise FacetRouteBenchError(f"{path}: expected one {token} marker")
        rendered = rendered.replace(token, value)
    if "{{" in rendered or "}}" in rendered:
        raise FacetRouteBenchError(f"{path}: unresolved template marker")
    return rendered


def build_generator_prompt(
    task: dict[str, Any],
    *,
    count: int,
    domain_counts: dict[str, int],
    route_contract: dict[str, Any],
) -> str:
    template = PROMPTS_DIR / "generate.md"
    route = task["gold_route_id"]
    route_detail = route_contract["routes"][route]
    neighbor_details = {
        neighbor: route_contract["routes"][neighbor]["definition"]
        for neighbor in route_detail["neighbor_route_ids"]
    }
    payload = {
        "split": task["split"],
        "track": task["track"],
        "target_route_id": route,
        "target_definition": route_detail["definition"],
        "target_facet_id": route_detail["facet_id"],
        "difficulty": task["difficulty"],
        "domain_counts": domain_counts,
        "neighbor_routes": neighbor_details,
        "contrast_route_id": task.get("contrast_route_id"),
        "contrast_route_definition": (
            route_contract["routes"][task["contrast_route_id"]]["definition"]
            if task.get("contrast_route_id")
            else None
        ),
        "boundary_rules": route_contract["boundary_rules"],
        "allowed_style_tags": sorted(ALLOWED_STYLES),
        "count": count,
    }
    return _render_template(
        template,
        {
            "PERSONA_CORE_MD": PERSONA_CORE_PATH.read_text(encoding="utf-8").strip(),
            "TASK_JSON": json.dumps(payload, ensure_ascii=False, indent=2),
            "ROUTE_CONTRACT_JSON": json.dumps(
                {
                    key: {
                        "definition": value["definition"],
                        "facet_id": value["facet_id"],
                    }
                    for key, value in route_contract["routes"].items()
                },
                ensure_ascii=False,
                indent=2,
            ),
        },
    )


def _validate_candidate_shape(
    candidate: dict[str, Any],
    task: dict[str, Any],
) -> None:
    if candidate.get("domain") not in ALLOWED_DOMAINS:
        raise FacetRouteBenchError("generator returned an invalid domain")
    styles = candidate.get("style_tags")
    if (
        not isinstance(styles, list)
        or not styles
        or len(styles) != len(set(styles))
        or not set(styles) <= ALLOWED_STYLES
    ):
        raise FacetRouteBenchError("generator returned invalid style_tags")
    messages = candidate.get("messages")
    if not isinstance(messages, list):
        raise FacetRouteBenchError("generator candidate must contain messages")
    final_user_text(messages)
    if task["track"] == "single_turn":
        if len(messages) != 1 or messages[0].get("role") != "user":
            raise FacetRouteBenchError(
                "single-turn candidate must contain one user message"
            )
    else:
        if not 3 <= len(messages) <= 7:
            raise FacetRouteBenchError("context candidate must contain 3 to 7 messages")
        expected_roles = [
            "user" if index % 2 == 0 else "assistant" for index in range(len(messages))
        ]
        if [message.get("role") for message in messages] != expected_roles:
            raise FacetRouteBenchError(
                "context messages must alternate user/assistant and end with user"
            )
    neighbor = candidate.get("neighbor_route_id")
    if task["difficulty"] == "neighbor":
        allowed = load_route_contract()["routes"][task["gold_route_id"]][
            "neighbor_route_ids"
        ]
        if neighbor not in allowed:
            raise FacetRouteBenchError(
                f"neighbor candidate must name one contracted neighbor: {allowed}"
            )
    elif neighbor is not None:
        raise FacetRouteBenchError("neighbor_route_id is only valid for neighbor cases")


def generate_candidates(
    *,
    plan_path: Path,
    output_path: Path,
    calls_path: Path,
    codex_bin: str,
    working_directory: Path,
    oversample_factor: float,
    max_candidates_per_call: int,
    timeout_seconds: float,
    task_start: int,
    task_end: int | None,
) -> tuple[Path, Path]:
    if oversample_factor < 1:
        raise FacetRouteBenchError("oversample factor must be at least one")
    plan = read_json(plan_path)
    benchmark = load_benchmark_contract()
    if oversample_factor != benchmark["authoring"]["oversample_factor"]:
        raise FacetRouteBenchError(
            "oversample factor differs from the preregistered authoring contract"
        )
    if plan.get("schema_version") != "facetroutebench-authoring-plan-v3":
        raise FacetRouteBenchError("generation requires an authoring v3 plan")
    if plan.get("oversample_factor") != oversample_factor:
        raise FacetRouteBenchError("authoring plan oversample factor is stale")
    route_contract = load_route_contract()
    if plan.get("route_contract_sha256") != sha256_file(
        CONTRACTS_DIR / "routes.v1.json"
    ):
        raise FacetRouteBenchError("authoring plan route contract SHA is stale")
    if plan.get("benchmark_contract_sha256") != sha256_file(
        CONTRACTS_DIR / "benchmark.v1.json"
    ):
        raise FacetRouteBenchError("authoring plan benchmark contract SHA is stale")
    if plan.get("persona_core_sha256") != sha256_file(PERSONA_CORE_PATH):
        raise FacetRouteBenchError("authoring plan persona core SHA is stale")
    existing = [output_path.exists(), calls_path.exists()]
    if any(existing) and not all(existing):
        raise FacetRouteBenchError(
            "resume requires both candidate and call-log files, or neither"
        )
    candidates = read_jsonl(output_path) if all(existing) else []
    calls = read_jsonl(calls_path) if all(existing) else []
    seen_texts = {
        normalized_text(conversation_text(item["messages"])) for item in candidates
    }
    schema = SCHEMAS_DIR / "generator-output.schema.json"
    prompt_template = PROMPTS_DIR / "generate.md"
    if any(
        item.get("prompt_template_sha256") != sha256_file(prompt_template)
        for item in calls
    ):
        raise FacetRouteBenchError("generation checkpoint uses another prompt version")

    tasks = plan["tasks"]
    end = len(tasks) if task_end is None else task_end
    if task_start < 0 or end < task_start or end > len(tasks):
        raise FacetRouteBenchError("invalid authoring task range")
    for task in tasks[task_start:end]:
        desired_by_domain = _oversampled_domain_targets(task, oversample_factor)
        accepted_by_domain = Counter(
            item["domain"]
            for item in candidates
            if item.get("authoring_task_id") == task["task_id"]
        )
        call_index = sum(item.get("task_id") == task["task_id"] for item in calls)
        while any(
            accepted_by_domain[domain] < desired
            for domain, desired in desired_by_domain.items()
        ):
            call_index += 1
            remaining_slots = max_candidates_per_call
            request_domain_counts: dict[str, int] = {}
            for domain in sorted(desired_by_domain):
                remaining = desired_by_domain[domain] - accepted_by_domain[domain]
                requested = min(remaining_slots, remaining)
                if requested:
                    request_domain_counts[domain] = requested
                    remaining_slots -= requested
                if remaining_slots == 0:
                    break
            request_count = sum(request_domain_counts.values())
            prompt = build_generator_prompt(
                task,
                count=request_count,
                domain_counts=request_domain_counts,
                route_contract=route_contract,
            )
            output, invocation = complete_json(
                prompt=prompt,
                prompt_template=prompt_template,
                output_schema=schema,
                codex_bin=codex_bin,
                working_directory=working_directory,
                timeout_seconds=timeout_seconds,
            )
            raw_candidates = output.get("candidates")
            if (
                not isinstance(raw_candidates, list)
                or len(raw_candidates) != request_count
            ):
                raise FacetRouteBenchError(
                    f"{task['task_id']}: requested {request_count} candidates, "
                    f"received {len(raw_candidates) if isinstance(raw_candidates, list) else 'invalid'}"
                )
            returned_domain_counts = Counter(
                item.get("domain") for item in raw_candidates
            )
            if returned_domain_counts != Counter(request_domain_counts):
                raise FacetRouteBenchError(
                    f"{task['task_id']}: domain counts differ from the fixed request"
                )
            batch_id = f"{task['task_id']}-call-{call_index:03d}"
            call_record = {
                "batch_id": batch_id,
                "phase": "generation",
                "task_id": task["task_id"],
                "session_id": invocation.session_id,
                "prompt_template_sha256": invocation.prompt_sha256,
                "request_sha256": invocation.request_sha256,
                "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
                "domain_counts": request_domain_counts,
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "candidate_count": request_count,
            }
            calls.append(call_record)
            for raw in raw_candidates:
                if not isinstance(raw, dict):
                    raise FacetRouteBenchError("generator candidate must be an object")
                _validate_candidate_shape(raw, task)
                text_key = normalized_text(conversation_text(raw["messages"]))
                if not text_key or text_key in seen_texts:
                    continue
                seen_texts.add(text_key)
                candidate_id = (
                    "candidate-"
                    + sha256_text(
                        canonical_json(
                            {
                                "task": task["task_id"],
                                "messages": raw["messages"],
                            }
                        )
                    )[:20]
                )
                candidates.append(
                    {
                        "candidate_id": candidate_id,
                        "authoring_task_id": task["task_id"],
                        "split": task["split"],
                        "track": task["track"],
                        "gold_route_id": task["gold_route_id"],
                        "facet_id": task["facet_id"],
                        "difficulty": task["difficulty"],
                        "domain": raw["domain"],
                        "messages": raw["messages"],
                        "style_tags": raw["style_tags"],
                        "neighbor_route_id": raw.get("neighbor_route_id"),
                        "contrast_route_id": task.get("contrast_route_id"),
                        "generation_batch_id": batch_id,
                        "generator": invocation.provenance(),
                    }
                )
                accepted_by_domain[raw["domain"]] += 1
            write_jsonl(output_path, candidates, overwrite=True)
            write_jsonl(calls_path, calls, overwrite=True)
    return output_path.resolve(), calls_path.resolve()


def build_canon_validator_prompt(
    candidates: Sequence[dict[str, Any]],
) -> str:
    visible_candidates = [
        {"candidate_id": item["candidate_id"], "messages": item["messages"]}
        for item in candidates
    ]
    return _render_template(
        PROMPTS_DIR / "validate_canon.md",
        {
            "PERSONA_CORE_MD": PERSONA_CORE_PATH.read_text(encoding="utf-8").strip(),
            "CANDIDATES_JSON": json.dumps(
                visible_candidates,
                ensure_ascii=False,
                indent=2,
            ),
        },
    )


def validate_canon_candidates(
    *,
    candidates_path: Path,
    accepted_path: Path,
    rejected_path: Path,
    calls_path: Path,
    codex_bin: str,
    working_directory: Path,
    batch_size: int,
    timeout_seconds: float,
    candidate_start: int,
    candidate_end: int | None,
) -> tuple[Path, Path, Path]:
    candidates = read_jsonl(candidates_path)
    end = len(candidates) if candidate_end is None else candidate_end
    if candidate_start < 0 or end < candidate_start or end > len(candidates):
        raise FacetRouteBenchError("invalid canon-validation candidate range")
    candidates = candidates[candidate_start:end]
    schema = SCHEMAS_DIR / "canon-validator-output.schema.json"
    prompt_template = PROMPTS_DIR / "validate_canon.md"
    existing = [accepted_path.exists(), rejected_path.exists(), calls_path.exists()]
    if any(existing) and not all(existing):
        raise FacetRouteBenchError(
            "resume requires canon accepted, rejected, and call-log files together"
        )
    accepted = read_jsonl(accepted_path) if all(existing) else []
    rejected = read_jsonl(rejected_path) if all(existing) else []
    calls = read_jsonl(calls_path) if all(existing) else []
    processed_ids = {
        item["candidate_id"] for item in (*accepted, *rejected)
    }
    if len(processed_ids) != len(accepted) + len(rejected):
        raise FacetRouteBenchError("canon-validation checkpoint repeats candidate IDs")
    candidate_ids = {item["candidate_id"] for item in candidates}
    if not processed_ids <= candidate_ids:
        raise FacetRouteBenchError(
            "canon-validation checkpoint belongs to another candidate file"
        )
    if any(
        item.get("prompt_template_sha256") != sha256_file(prompt_template)
        for item in calls
    ):
        raise FacetRouteBenchError(
            "canon-validation checkpoint uses another prompt version"
        )
    remaining = [
        item for item in candidates if item["candidate_id"] not in processed_ids
    ]
    for call_index, batch in enumerate(
        chunked(remaining, batch_size), start=len(calls) + 1
    ):
        prompt = build_canon_validator_prompt(batch)
        output, invocation = complete_json(
            prompt=prompt,
            prompt_template=prompt_template,
            output_schema=schema,
            codex_bin=codex_bin,
            working_directory=working_directory,
            timeout_seconds=timeout_seconds,
        )
        raw = output.get("decisions")
        if not isinstance(raw, list):
            raise FacetRouteBenchError("canon validator returned invalid decisions")
        by_id = {
            item.get("candidate_id"): item for item in raw if isinstance(item, dict)
        }
        expected_ids = {item["candidate_id"] for item in batch}
        if set(by_id) != expected_ids:
            raise FacetRouteBenchError(
                "canon validator candidate IDs did not match request"
            )
        validation_batch_id = (
            f"canon-validation-{candidate_start:04d}-call-{call_index:04d}"
        )
        calls.append(
            {
                "batch_id": validation_batch_id,
                "phase": "canon_validation",
                "session_id": invocation.session_id,
                "prompt_template_sha256": invocation.prompt_sha256,
                "request_sha256": invocation.request_sha256,
                "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "candidate_count": len(batch),
            }
        )
        for candidate in batch:
            decision = by_id[candidate["candidate_id"]]
            accepted_decision = decision.get("accepted") is True
            reason_code = decision.get("reason_code")
            if accepted_decision != (reason_code == "NONE"):
                raise FacetRouteBenchError(
                    "canon validator must use NONE exactly for accepted candidates"
                )
            record = {
                **candidate,
                "canon_validation_batch_id": validation_batch_id,
                "canon_validator": invocation.provenance(),
                "canon_validation_result": {
                    "accepted": accepted_decision,
                    "reason_code": reason_code,
                },
            }
            if invocation.session_id == candidate["generator"]["session_id"]:
                raise FacetRouteBenchError(
                    "generator and canon validator sessions must differ"
                )
            (accepted if accepted_decision else rejected).append(record)
        write_jsonl(accepted_path, accepted, overwrite=True)
        write_jsonl(rejected_path, rejected, overwrite=True)
        write_jsonl(calls_path, calls, overwrite=True)
    if not all(existing) and not remaining:
        write_jsonl(accepted_path, accepted)
        write_jsonl(rejected_path, rejected)
        write_jsonl(calls_path, calls)
    return accepted_path.resolve(), rejected_path.resolve(), calls_path.resolve()


def build_validator_prompt(
    candidates: Sequence[dict[str, Any]],
    route_contract: dict[str, Any],
) -> str:
    template = PROMPTS_DIR / "validate_blind.md"
    blind_candidates = [
        {"candidate_id": item["candidate_id"], "messages": item["messages"]}
        for item in candidates
    ]
    return _render_template(
        template,
        {
            "ROUTE_CONTRACT_JSON": json.dumps(
                {
                    "routes": {
                        key: value["definition"]
                        for key, value in route_contract["routes"].items()
                    },
                    "boundary_rules": route_contract["boundary_rules"],
                },
                ensure_ascii=False,
                indent=2,
            ),
            "CANDIDATES_JSON": json.dumps(
                blind_candidates,
                ensure_ascii=False,
                indent=2,
            ),
        },
    )


def validate_candidates(
    *,
    candidates_path: Path,
    accepted_path: Path,
    rejected_path: Path,
    calls_path: Path,
    codex_bin: str,
    working_directory: Path,
    batch_size: int,
    timeout_seconds: float,
    candidate_start: int,
    candidate_end: int | None,
) -> tuple[Path, Path, Path]:
    candidates = read_jsonl(candidates_path)
    if any(
        item.get("canon_validation_result", {}).get("accepted") is not True
        for item in candidates
    ):
        raise FacetRouteBenchError(
            "blind validation requires candidates accepted by canon validation"
        )
    end = len(candidates) if candidate_end is None else candidate_end
    if candidate_start < 0 or end < candidate_start or end > len(candidates):
        raise FacetRouteBenchError("invalid validation candidate range")
    candidates = candidates[candidate_start:end]
    route_contract = load_route_contract()
    schema = SCHEMAS_DIR / "validator-output.schema.json"
    prompt_template = PROMPTS_DIR / "validate_blind.md"
    existing = [accepted_path.exists(), rejected_path.exists(), calls_path.exists()]
    if any(existing) and not all(existing):
        raise FacetRouteBenchError(
            "resume requires accepted, rejected, and call-log files together"
        )
    accepted = read_jsonl(accepted_path) if all(existing) else []
    rejected = read_jsonl(rejected_path) if all(existing) else []
    calls = read_jsonl(calls_path) if all(existing) else []
    processed_ids = {item["candidate_id"] for item in (*accepted, *rejected)}
    if len(processed_ids) != len(accepted) + len(rejected):
        raise FacetRouteBenchError(
            "validation checkpoint contains duplicate candidates"
        )
    candidate_ids = {item["candidate_id"] for item in candidates}
    if not processed_ids <= candidate_ids:
        raise FacetRouteBenchError(
            "validation checkpoint belongs to another candidate file"
        )
    if any(
        item.get("prompt_template_sha256") != sha256_file(prompt_template)
        for item in calls
    ):
        raise FacetRouteBenchError("validation checkpoint uses another prompt version")
    remaining = [
        item for item in candidates if item["candidate_id"] not in processed_ids
    ]

    for call_index, batch in enumerate(
        chunked(remaining, batch_size), start=len(calls) + 1
    ):
        prompt = build_validator_prompt(batch, route_contract)
        output, invocation = complete_json(
            prompt=prompt,
            prompt_template=prompt_template,
            output_schema=schema,
            codex_bin=codex_bin,
            working_directory=working_directory,
            timeout_seconds=timeout_seconds,
        )
        predictions = output.get("predictions")
        if not isinstance(predictions, list):
            raise FacetRouteBenchError("validator returned invalid predictions")
        by_id = {
            item.get("candidate_id"): item.get("predicted_route_id")
            for item in predictions
            if isinstance(item, dict)
        }
        expected_ids = {item["candidate_id"] for item in batch}
        if set(by_id) != expected_ids:
            raise FacetRouteBenchError("validator candidate IDs did not match request")
        validation_batch_id = f"validation-{candidate_start:04d}-call-{call_index:04d}"
        calls.append(
            {
                "batch_id": validation_batch_id,
                "phase": "blind_validation",
                "session_id": invocation.session_id,
                "prompt_template_sha256": invocation.prompt_sha256,
                "request_sha256": invocation.request_sha256,
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "candidate_count": len(batch),
            }
        )
        for candidate in batch:
            predicted = by_id[candidate["candidate_id"]]
            if predicted == candidate["gold_route_id"]:
                if invocation.session_id == candidate["generator"]["session_id"]:
                    raise FacetRouteBenchError(
                        "generator and validator sessions must differ"
                    )
                record = dict(candidate)
                record["validation_batch_id"] = validation_batch_id
                record["blind_validator"] = invocation.provenance()
                record["validation_result"] = {
                    "predicted_route_id": predicted,
                    "accepted": True,
                }
                accepted.append(record)
            else:
                rejected.append(
                    {
                        **candidate,
                        "validation_batch_id": validation_batch_id,
                        "blind_validator": invocation.provenance(),
                        "validation_result": {
                            "predicted_route_id": predicted,
                            "accepted": False,
                        },
                    }
                )
        write_jsonl(accepted_path, accepted, overwrite=True)
        write_jsonl(rejected_path, rejected, overwrite=True)
        write_jsonl(calls_path, calls, overwrite=True)
    if not all(existing) and not remaining:
        write_jsonl(accepted_path, accepted)
        write_jsonl(rejected_path, rejected)
        write_jsonl(calls_path, calls)
    return accepted_path.resolve(), rejected_path.resolve(), calls_path.resolve()


def refill_shortages(
    *,
    plan_path: Path,
    candidates_path: Path,
    generation_calls_path: Path,
    canon_accepted_path: Path,
    canon_rejected_path: Path,
    canon_calls_path: Path,
    accepted_path: Path,
    rejected_path: Path,
    validation_calls_path: Path,
    codex_bin: str,
    working_directory: Path,
    max_candidates_per_call: int,
    generation_workers: int,
    validation_batch_size: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    required_paths = (
        plan_path,
        candidates_path,
        generation_calls_path,
        canon_accepted_path,
        canon_rejected_path,
        canon_calls_path,
        accepted_path,
        rejected_path,
        validation_calls_path,
    )
    missing = [str(path) for path in required_paths if not path.is_file()]
    if missing:
        raise FacetRouteBenchError(
            "refill requires a completed initial generation and validation pass; "
            f"missing: {missing}"
        )
    if (
        max_candidates_per_call < 1
        or generation_workers < 1
        or validation_batch_size < 1
    ):
        raise FacetRouteBenchError("refill batch sizes and worker count must be positive")

    plan = read_json(plan_path)
    benchmark = load_benchmark_contract()
    if plan.get("schema_version") != "facetroutebench-authoring-plan-v3":
        raise FacetRouteBenchError("refill requires an authoring v3 plan")
    if plan.get("benchmark_contract_sha256") != sha256_file(
        CONTRACTS_DIR / "benchmark.v1.json"
    ):
        raise FacetRouteBenchError("authoring plan benchmark contract SHA is stale")
    if plan.get("route_contract_sha256") != sha256_file(
        CONTRACTS_DIR / "routes.v1.json"
    ):
        raise FacetRouteBenchError("authoring plan route contract SHA is stale")
    if plan.get("persona_core_sha256") != sha256_file(PERSONA_CORE_PATH):
        raise FacetRouteBenchError("authoring plan persona core SHA is stale")

    refill_contract = benchmark["authoring"]["rejection_sampling"]
    if (
        refill_contract.get("enabled") is not True
        or refill_contract.get("unit") != "authoring_task_id_and_domain"
        or refill_contract.get("candidates_per_shortage") != 1
        or refill_contract.get("prompt_or_contract_tuning_between_rounds") is not False
    ):
        raise FacetRouteBenchError("unsupported rejection-sampling contract")
    max_rounds = refill_contract["max_rounds"]
    if not isinstance(max_rounds, int) or max_rounds < 1:
        raise FacetRouteBenchError("invalid rejection-sampling round limit")

    tasks_by_id = {task["task_id"]: task for task in plan["tasks"]}
    candidates = read_jsonl(candidates_path)
    generation_calls = read_jsonl(generation_calls_path)
    if any(
        item.get("prompt_template_sha256")
        != sha256_file(PROMPTS_DIR / "generate.md")
        for item in generation_calls
    ):
        raise FacetRouteBenchError(
            "generation checkpoint uses another prompt version; start a new artifact"
        )
    seen_texts = {
        normalized_text(conversation_text(item["messages"])) for item in candidates
    }
    route_contract = load_route_contract()
    schema = SCHEMAS_DIR / "generator-output.schema.json"
    prompt_template = PROMPTS_DIR / "generate.md"

    # Resume validation first in case a previous refill run stopped after generation.
    validate_canon_candidates(
        candidates_path=candidates_path,
        accepted_path=canon_accepted_path,
        rejected_path=canon_rejected_path,
        calls_path=canon_calls_path,
        codex_bin=codex_bin,
        working_directory=working_directory,
        batch_size=validation_batch_size,
        timeout_seconds=timeout_seconds,
        candidate_start=0,
        candidate_end=None,
    )
    validate_candidates(
        candidates_path=canon_accepted_path,
        accepted_path=accepted_path,
        rejected_path=rejected_path,
        calls_path=validation_calls_path,
        codex_bin=codex_bin,
        working_directory=working_directory,
        batch_size=validation_batch_size,
        timeout_seconds=timeout_seconds,
        candidate_start=0,
        candidate_end=None,
    )
    initial_requests = refill_requests(plan, read_jsonl(accepted_path))
    completed_rounds = 0
    for round_index in range(1, max_rounds + 1):
        requests = refill_requests(plan, read_jsonl(accepted_path))
        if not requests:
            return {
                "status": "complete",
                "completed_rounds": completed_rounds,
                "initial_shortage_count": sum(
                    item["count"] for item in initial_requests
                ),
                "remaining_shortages": [],
            }

        requests_by_task: dict[str, Counter[str]] = defaultdict(Counter)
        for request in requests:
            requests_by_task[request["task_id"]][request["domain"]] = request[
                "count"
            ]

        generation_jobs: list[dict[str, Any]] = []
        for task_id in sorted(requests_by_task):
            task = tasks_by_id[task_id]
            remaining_by_domain = requests_by_task[task_id]
            call_index = sum(
                item.get("task_id") == task_id for item in generation_calls
            )
            while sum(remaining_by_domain.values()) > 0:
                request_domain_counts: dict[str, int] = {}
                remaining_slots = max_candidates_per_call
                for domain in sorted(remaining_by_domain):
                    requested = min(remaining_slots, remaining_by_domain[domain])
                    if requested > 0:
                        request_domain_counts[domain] = requested
                        remaining_by_domain[domain] -= requested
                        remaining_slots -= requested
                    if remaining_slots == 0:
                        break
                request_count = sum(request_domain_counts.values())
                call_index += 1
                generation_jobs.append(
                    {
                        "batch_id": (
                            f"{task_id}-refill-{round_index:02d}-call-"
                            f"{call_index:03d}"
                        ),
                        "task_id": task_id,
                        "task": task,
                        "domain_counts": request_domain_counts,
                        "count": request_count,
                    }
                )

        def run_generation_job(
            job: dict[str, Any],
        ) -> tuple[dict[str, Any], list[dict[str, Any]], Any]:
            task = job["task"]
            request_count = job["count"]
            request_domain_counts = job["domain_counts"]
            task_id = job["task_id"]
            prompt = build_generator_prompt(
                task,
                count=request_count,
                domain_counts=request_domain_counts,
                route_contract=route_contract,
            )
            output, invocation = complete_json(
                prompt=prompt,
                prompt_template=prompt_template,
                output_schema=schema,
                codex_bin=codex_bin,
                working_directory=working_directory,
                timeout_seconds=timeout_seconds,
            )
            raw_candidates = output.get("candidates")
            if (
                not isinstance(raw_candidates, list)
                or len(raw_candidates) != request_count
            ):
                raise FacetRouteBenchError(
                    f"{task_id}: requested {request_count} refill candidates, "
                    "but the generator returned another count"
                )
            if Counter(item.get("domain") for item in raw_candidates) != Counter(
                request_domain_counts
            ):
                raise FacetRouteBenchError(
                    f"{task_id}: refill domain counts differ from the fixed request"
                )
            for raw in raw_candidates:
                if not isinstance(raw, dict):
                    raise FacetRouteBenchError(
                        "generator refill candidate must be an object"
                    )
                _validate_candidate_shape(raw, task)
            return job, raw_candidates, invocation

        generation_results: list[
            tuple[dict[str, Any], list[dict[str, Any]], Any]
        ] = []
        generation_errors: list[Exception] = []
        with ThreadPoolExecutor(
            max_workers=min(generation_workers, len(generation_jobs))
        ) as executor:
            futures = {
                executor.submit(run_generation_job, job): job
                for job in generation_jobs
            }
            for future in as_completed(futures):
                try:
                    generation_results.append(future.result())
                except Exception as error:  # preserve successful independent shards
                    generation_errors.append(error)

        for job, raw_candidates, invocation in sorted(
            generation_results, key=lambda item: item[0]["batch_id"]
        ):
            task = job["task"]
            task_id = job["task_id"]
            batch_id = job["batch_id"]
            request_domain_counts = job["domain_counts"]
            request_count = job["count"]
            generation_calls.append(
                {
                    "batch_id": batch_id,
                    "phase": "refill_generation",
                    "refill_round": round_index,
                    "task_id": task_id,
                    "session_id": invocation.session_id,
                    "prompt_template_sha256": invocation.prompt_sha256,
                    "request_sha256": invocation.request_sha256,
                    "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
                    "domain_counts": request_domain_counts,
                    "elapsed_ms": invocation.elapsed_ms,
                    "codex_version": invocation.codex_version,
                    "candidate_count": request_count,
                }
            )
            for raw in raw_candidates:
                text_key = normalized_text(conversation_text(raw["messages"]))
                if not text_key or text_key in seen_texts:
                    continue
                seen_texts.add(text_key)
                candidate_id = "candidate-" + sha256_text(
                    canonical_json({"task": task_id, "messages": raw["messages"]})
                )[:20]
                candidates.append(
                    {
                        "candidate_id": candidate_id,
                        "authoring_task_id": task_id,
                        "split": task["split"],
                        "track": task["track"],
                        "gold_route_id": task["gold_route_id"],
                        "facet_id": task["facet_id"],
                        "difficulty": task["difficulty"],
                        "domain": raw["domain"],
                        "messages": raw["messages"],
                        "style_tags": raw["style_tags"],
                        "neighbor_route_id": raw.get("neighbor_route_id"),
                        "contrast_route_id": task.get("contrast_route_id"),
                        "generation_batch_id": batch_id,
                        "generator": invocation.provenance(),
                    }
                )
            write_jsonl(candidates_path, candidates, overwrite=True)
            write_jsonl(generation_calls_path, generation_calls, overwrite=True)

        if generation_errors:
            raise FacetRouteBenchError(
                f"{len(generation_errors)} parallel refill generation call(s) failed; "
                f"first error: {generation_errors[0]}"
            )

        validate_canon_candidates(
            candidates_path=candidates_path,
            accepted_path=canon_accepted_path,
            rejected_path=canon_rejected_path,
            calls_path=canon_calls_path,
            codex_bin=codex_bin,
            working_directory=working_directory,
            batch_size=validation_batch_size,
            timeout_seconds=timeout_seconds,
            candidate_start=0,
            candidate_end=None,
        )
        validate_candidates(
            candidates_path=canon_accepted_path,
            accepted_path=accepted_path,
            rejected_path=rejected_path,
            calls_path=validation_calls_path,
            codex_bin=codex_bin,
            working_directory=working_directory,
            batch_size=validation_batch_size,
            timeout_seconds=timeout_seconds,
            candidate_start=0,
            candidate_end=None,
        )
        completed_rounds = round_index

    remaining = refill_requests(plan, read_jsonl(accepted_path))
    if remaining:
        raise FacetRouteBenchError(
            f"rejection sampling exhausted after {max_rounds} rounds; "
            f"remaining shortages: {json.dumps(remaining, ensure_ascii=False)}"
        )
    return {
        "status": "complete",
        "completed_rounds": completed_rounds,
        "initial_shortage_count": sum(item["count"] for item in initial_requests),
        "remaining_shortages": [],
    }


def merge_generation_shards(
    *,
    candidate_paths: Sequence[Path],
    call_paths: Sequence[Path],
    output_path: Path,
    calls_output_path: Path,
    oversample_factor: float,
) -> tuple[Path, Path]:
    benchmark = load_benchmark_contract()
    if oversample_factor != benchmark["authoring"]["oversample_factor"]:
        raise FacetRouteBenchError(
            "oversample factor differs from the preregistered authoring contract"
        )
    candidates = [item for path in candidate_paths for item in read_jsonl(path)]
    calls = [item for path in call_paths for item in read_jsonl(path)]
    candidate_ids = [item["candidate_id"] for item in candidates]
    batch_ids = [item["batch_id"] for item in calls]
    if len(candidate_ids) != len(set(candidate_ids)):
        raise FacetRouteBenchError("generation shards contain duplicate candidate IDs")
    if len(batch_ids) != len(set(batch_ids)):
        raise FacetRouteBenchError("generation shards contain duplicate batch IDs")
    if not {item["generation_batch_id"] for item in candidates} <= set(batch_ids):
        raise FacetRouteBenchError("candidate references an unknown generation batch")
    actual = Counter(item["authoring_task_id"] for item in candidates)
    expected = {
        task["task_id"]: sum(
            _oversampled_domain_targets(task, oversample_factor).values()
        )
        for task in build_plan()["tasks"]
    }
    if actual != Counter(expected):
        raise FacetRouteBenchError("generation shards do not cover the fixed plan")
    write_jsonl(output_path, sorted(candidates, key=lambda item: item["candidate_id"]))
    write_jsonl(calls_output_path, sorted(calls, key=lambda item: item["batch_id"]))
    return output_path.resolve(), calls_output_path.resolve()


def merge_validation_shards(
    *,
    candidates_path: Path,
    accepted_paths: Sequence[Path],
    rejected_paths: Sequence[Path],
    call_paths: Sequence[Path],
    accepted_output_path: Path,
    rejected_output_path: Path,
    calls_output_path: Path,
) -> tuple[Path, Path, Path]:
    candidates = read_jsonl(candidates_path)
    accepted = [item for path in accepted_paths for item in read_jsonl(path)]
    rejected = [item for path in rejected_paths for item in read_jsonl(path)]
    calls = [item for path in call_paths for item in read_jsonl(path)]
    expected_ids = {item["candidate_id"] for item in candidates}
    processed_ids = [item["candidate_id"] for item in (*accepted, *rejected)]
    if (
        len(processed_ids) != len(set(processed_ids))
        or set(processed_ids) != expected_ids
    ):
        raise FacetRouteBenchError("validation shards do not partition all candidates")
    batch_ids = [item["batch_id"] for item in calls]
    if len(batch_ids) != len(set(batch_ids)):
        raise FacetRouteBenchError("validation shards contain duplicate batch IDs")
    write_jsonl(
        accepted_output_path, sorted(accepted, key=lambda item: item["candidate_id"])
    )
    write_jsonl(
        rejected_output_path, sorted(rejected, key=lambda item: item["candidate_id"])
    )
    write_jsonl(calls_output_path, sorted(calls, key=lambda item: item["batch_id"]))
    return (
        accepted_output_path.resolve(),
        rejected_output_path.resolve(),
        calls_output_path.resolve(),
    )


def _character_ngrams(text: str, n: int = 3) -> set[str]:
    normalized = normalized_text(text)
    if len(normalized) < n:
        return {normalized} if normalized else set()
    return {normalized[index : index + n] for index in range(len(normalized) - n + 1)}


def _jaccard(left: set[str], right: set[str]) -> float:
    union = left | right
    return len(left & right) / len(union) if union else 0.0


def shortlist_duplicate_pairs(
    *,
    accepted_path: Path,
    output_path: Path,
    top_k_cross_split: int,
    minimum_jaccard: float,
) -> Path:
    records = read_jsonl(accepted_path)
    grams = {
        item["candidate_id"]: _character_ngrams(conversation_text(item["messages"]))
        for item in records
    }
    pairs: dict[tuple[str, str], dict[str, Any]] = {}
    for left in records:
        scored: list[tuple[float, dict[str, Any]]] = []
        for right in records:
            if left["candidate_id"] == right["candidate_id"]:
                continue
            if left["split"] == right["split"]:
                continue
            score = _jaccard(grams[left["candidate_id"]], grams[right["candidate_id"]])
            if score >= minimum_jaccard:
                scored.append((score, right))
        for score, right in sorted(
            scored,
            key=lambda item: (-item[0], item[1]["candidate_id"]),
        )[:top_k_cross_split]:
            key = tuple(sorted((left["candidate_id"], right["candidate_id"])))
            pairs[key] = {
                "pair_id": "pair-" + sha256_text("|".join(key))[:20],
                "left_candidate_id": left["candidate_id"],
                "right_candidate_id": right["candidate_id"],
                "left_text": conversation_text(left["messages"]),
                "right_text": conversation_text(right["messages"]),
                "character_trigram_jaccard": round(score, 8),
            }
    write_jsonl(output_path, [pairs[key] for key in sorted(pairs)])
    return output_path.resolve()


def build_duplicate_prompt(pairs: Sequence[dict[str, Any]]) -> str:
    return _render_template(
        PROMPTS_DIR / "audit_duplicates.md",
        {
            "PAIRS_JSON": json.dumps(
                [
                    {
                        "pair_id": pair["pair_id"],
                        "left_text": pair["left_text"],
                        "right_text": pair["right_text"],
                    }
                    for pair in pairs
                ],
                ensure_ascii=False,
                indent=2,
            )
        },
    )


def audit_duplicate_pairs(
    *,
    pairs_path: Path,
    output_path: Path,
    calls_path: Path,
    codex_bin: str,
    working_directory: Path,
    batch_size: int,
    timeout_seconds: float,
) -> tuple[Path, Path]:
    pairs = read_jsonl(pairs_path)
    existing = [output_path.exists(), calls_path.exists()]
    if any(existing) and not all(existing):
        raise FacetRouteBenchError(
            "resume requires duplicate decisions and call-log files together"
        )
    decisions = read_jsonl(output_path) if all(existing) else []
    calls = read_jsonl(calls_path) if all(existing) else []
    processed_ids = {item["pair_id"] for item in decisions}
    if len(processed_ids) != len(decisions):
        raise FacetRouteBenchError("duplicate-audit checkpoint repeats pair IDs")
    pair_ids = {item["pair_id"] for item in pairs}
    if not processed_ids <= pair_ids:
        raise FacetRouteBenchError(
            "duplicate-audit checkpoint belongs to another pair file"
        )
    audit_prompt_sha = sha256_file(PROMPTS_DIR / "audit_duplicates.md")
    if any(item.get("prompt_template_sha256") != audit_prompt_sha for item in calls):
        raise FacetRouteBenchError(
            "duplicate-audit checkpoint uses another prompt version"
        )
    remaining = [item for item in pairs if item["pair_id"] not in processed_ids]
    for call_index, batch in enumerate(
        chunked(remaining, batch_size), start=len(calls) + 1
    ):
        prompt = build_duplicate_prompt(batch)
        output, invocation = complete_json(
            prompt=prompt,
            prompt_template=PROMPTS_DIR / "audit_duplicates.md",
            output_schema=SCHEMAS_DIR / "duplicate-output.schema.json",
            codex_bin=codex_bin,
            working_directory=working_directory,
            timeout_seconds=timeout_seconds,
        )
        raw = output.get("decisions")
        if not isinstance(raw, list):
            raise FacetRouteBenchError("duplicate auditor returned invalid decisions")
        by_id = {item.get("pair_id"): item for item in raw if isinstance(item, dict)}
        if set(by_id) != {pair["pair_id"] for pair in batch}:
            raise FacetRouteBenchError(
                "duplicate auditor pair IDs did not match request"
            )
        for pair in batch:
            decision = by_id[pair["pair_id"]]
            decisions.append(
                {
                    **pair,
                    "duplicate": decision["duplicate"],
                    "reason": decision["reason"],
                    "auditor": invocation.provenance(),
                }
            )
        calls.append(
            {
                "batch_id": f"duplicate-audit-call-{call_index:04d}",
                "phase": "duplicate_audit",
                "session_id": invocation.session_id,
                "prompt_template_sha256": invocation.prompt_sha256,
                "request_sha256": invocation.request_sha256,
                "elapsed_ms": invocation.elapsed_ms,
                "codex_version": invocation.codex_version,
                "pair_count": len(batch),
            }
        )
        write_jsonl(output_path, decisions, overwrite=True)
        write_jsonl(calls_path, calls, overwrite=True)
    if not all(existing) and not remaining:
        write_jsonl(output_path, decisions)
        write_jsonl(calls_path, calls)
    return output_path.resolve(), calls_path.resolve()


def _cell_key(record: dict[str, Any]) -> tuple[str, str, str]:
    return record["split"], record["gold_route_id"], record["difficulty"]


def coverage_report(accepted_path: Path) -> dict[str, Any]:
    accepted = read_jsonl(accepted_path)
    actual = Counter(
        (record["authoring_task_id"], record["domain"]) for record in accepted
    )
    cells = []
    for task in build_plan()["tasks"]:
        for domain, target in sorted(task["domain_targets"].items()):
            count = actual[(task["task_id"], domain)]
            cells.append(
                {
                    "task_id": task["task_id"],
                    "domain": domain,
                    "target": target,
                    "accepted": count,
                    "surplus": max(0, count - target),
                    "shortage": max(0, target - count),
                }
            )
    return {
        "target": sum(item["target"] for item in cells),
        "accepted": len(accepted),
        "shortage_total": sum(item["shortage"] for item in cells),
        "shortage_cells": [item for item in cells if item["shortage"]],
        "cells": cells,
    }


def freeze_dataset(
    *,
    accepted_path: Path,
    duplicate_audit_path: Path,
    output_dir: Path,
    dataset_version: str,
) -> Path:
    if output_dir.exists():
        raise FacetRouteBenchError(
            f"refusing to overwrite output directory: {output_dir}"
        )
    accepted = read_jsonl(accepted_path)
    duplicate_decisions = read_jsonl(duplicate_audit_path)
    accepted_ids = {item["candidate_id"] for item in accepted}
    if len(accepted_ids) != len(accepted):
        raise FacetRouteBenchError("accepted candidates contain duplicate IDs")
    audited_pair_ids = [item["pair_id"] for item in duplicate_decisions]
    if len(audited_pair_ids) != len(set(audited_pair_ids)):
        raise FacetRouteBenchError("duplicate audit repeats pair IDs")
    audited_candidate_ids = {
        candidate_id
        for item in duplicate_decisions
        for candidate_id in (item["left_candidate_id"], item["right_candidate_id"])
    }
    if not audited_candidate_ids <= accepted_ids:
        raise FacetRouteBenchError("duplicate audit references unknown candidates")
    duplicate_edges = {
        frozenset((item["left_candidate_id"], item["right_candidate_id"]))
        for item in duplicate_decisions
        if item.get("duplicate") is True
    }
    duplicate_degree: Counter[str] = Counter()
    for edge in duplicate_edges:
        for candidate_id in edge:
            duplicate_degree[candidate_id] += 1
    plan = build_plan()
    tasks_by_id = {task["task_id"]: task for task in plan["tasks"]}
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for item in accepted:
        if item.get("canon_validation_result", {}).get("accepted") is not True:
            raise FacetRouteBenchError(
                "accepted candidate has not passed canon validation"
            )
        if item.get("validation_result", {}).get("predicted_route_id") != item.get(
            "gold_route_id"
        ):
            raise FacetRouteBenchError(
                "accepted candidate has a mismatched blind label"
            )
        if item["generator"]["session_id"] == item["blind_validator"]["session_id"]:
            raise FacetRouteBenchError("generator and validator sessions must differ")
        session_ids = {
            item["generator"]["session_id"],
            item["canon_validator"]["session_id"],
            item["blind_validator"]["session_id"],
        }
        if len(session_ids) != 3:
            raise FacetRouteBenchError(
                "generator, canon validator, and blind validator sessions must differ"
            )
        task_id = item.get("authoring_task_id")
        if task_id not in tasks_by_id:
            raise FacetRouteBenchError(
                f"accepted candidate has an unknown authoring task: {task_id}"
            )
        domain = item.get("domain")
        if domain not in tasks_by_id[task_id]["domain_targets"]:
            raise FacetRouteBenchError(
                "accepted candidate domain differs from its preregistered task"
            )
        grouped[(task_id, domain)].append(item)

    selected: list[dict[str, Any]] = []
    selected_ids: set[str] = set()
    selected_normalized: set[str] = set()
    case_indices: Counter[tuple[str, str, str]] = Counter()
    selection_cells = [
        (task_id, domain, target)
        for task_id, task in tasks_by_id.items()
        for domain, target in task["domain_targets"].items()
    ]
    selection_cells.sort(
        key=lambda cell: (
            len(grouped[(cell[0], cell[1])]) - cell[2],
            cell[0],
            cell[1],
        )
    )
    for task_id, domain, target in selection_cells:
        task = tasks_by_id[task_id]
        cell = (task["split"], task["gold_route_id"], task["difficulty"])
        chosen = 0
        for candidate in sorted(
            grouped[(task_id, domain)],
            key=lambda item: (
                duplicate_degree[item["candidate_id"]],
                item["candidate_id"],
            ),
        ):
            candidate_id = candidate["candidate_id"]
            normalized = normalized_text(conversation_text(candidate["messages"]))
            if normalized in selected_normalized:
                continue
            if any(
                frozenset((candidate_id, existing)) in duplicate_edges
                for existing in selected_ids
            ):
                continue
            case_indices[cell] += 1
            index = case_indices[cell]
            case_id = (
                f"frb-{cell[0].replace('_', '-')}-{cell[1].lower().replace('_', '-')}"
                f"-{cell[2].replace('_', '-')}-{index:03d}"
            )
            record = {
                    "case_id": case_id,
                    "dataset_version": dataset_version,
                    "split": candidate["split"],
                    "track": candidate["track"],
                    "gold_route_id": candidate["gold_route_id"],
                    "facet_id": candidate["facet_id"],
                    "difficulty": candidate["difficulty"],
                    "domain": candidate["domain"],
                    "messages": candidate["messages"],
                    "style_tags": candidate["style_tags"],
                    "generation_batch_id": candidate["generation_batch_id"],
                    "canon_validation_batch_id": candidate[
                        "canon_validation_batch_id"
                    ],
                    "validation_batch_id": candidate["validation_batch_id"],
                    "provenance": {
                        "generator": candidate["generator"],
                        "canon_validator": candidate["canon_validator"],
                        "blind_validator": candidate["blind_validator"],
                        "canon_validation_result": candidate[
                            "canon_validation_result"
                        ],
                        "validation_result": candidate["validation_result"],
                    },
                }
            if candidate.get("neighbor_route_id") is not None:
                record["neighbor_route_id"] = candidate["neighbor_route_id"]
            if candidate.get("contrast_route_id") is not None:
                record["contrast_route_id"] = candidate["contrast_route_id"]
            validate_record_schema(record)
            selected.append(record)
            selected_ids.add(candidate_id)
            selected_normalized.add(normalized)
            chosen += 1
            if chosen == target:
                break
        if chosen != target:
            raise FacetRouteBenchError(
                f"task {task_id}/{domain} has only {chosen} usable candidates; "
                f"expected {target}"
            )

    benchmark = load_benchmark_contract()
    validate_dataset_counts(selected, benchmark)
    output_dir.mkdir(parents=True)
    outputs: dict[str, dict[str, Any]] = {}
    dataset_major = dataset_version.split(".", 1)[0]
    for split in ("authoring", "dev", "frozen", "context_challenge"):
        path = output_dir / f"{split}.v{dataset_major}.jsonl"
        rows = sorted(
            (record for record in selected if record["split"] == split),
            key=lambda record: record["case_id"],
        )
        write_jsonl(path, rows)
        outputs[split] = {
            "path": path.name,
            "records": len(rows),
            "sha256": sha256_file(path),
        }
    manifest = {
        "schema_version": "facetroutebench-dataset-manifest-v3",
        "status": "valid",
        "dataset_version": dataset_version,
        "created_at": utc_now(),
        "source": {
            "accepted_path": str(accepted_path.resolve()),
            "accepted_sha256": sha256_file(accepted_path),
            "duplicate_audit_path": str(duplicate_audit_path.resolve()),
            "duplicate_audit_sha256": sha256_file(duplicate_audit_path),
        },
        "contracts": {
            "benchmark_sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
            "routes_sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
            "dataset_schema_sha256": sha256_file(CONTRACTS_DIR / "dataset.schema.json"),
            "persona_core_path": str(PERSONA_CORE_PATH.relative_to(REPO_ROOT)),
            "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
        },
        "total_records": len(selected),
        "splits": outputs,
    }
    write_json(output_dir / "dataset_manifest.json", manifest)
    return (output_dir / "dataset_manifest.json").resolve()
