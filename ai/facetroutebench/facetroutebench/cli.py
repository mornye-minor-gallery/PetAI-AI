from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .authoring import (
    PERSONA_CORE_PATH,
    audit_duplicate_pairs,
    coverage_report,
    freeze_dataset,
    generate_candidates,
    merge_generation_shards,
    merge_validation_shards,
    refill_shortages,
    shortlist_duplicate_pairs,
    validate_canon_candidates,
    validate_candidates,
    write_plan,
)
from .common import (
    CONTRACTS_DIR,
    REPO_ROOT,
    ROOT,
    SCHEMAS_DIR,
    FacetRouteBenchError,
    read_json,
    read_jsonl,
    sha256_file,
)
from .contracts import (
    load_benchmark_contract,
    load_route_contract,
    validate_dataset_counts,
    validate_record_schema,
    validate_record_semantics,
)
from .embedding import extract_embeddings, prepare_embedding_inputs
from .evaluation import (
    run_embedding_context,
    run_embedding_dev,
    run_embedding_frozen,
    score_prediction_file,
    select_embedding_candidate,
)
from .thresholds import compare_threshold_strategies
from .gemma_runner import run_gemma_router
from .latency import summarize_latency
from .manifests import validate_run_manifest


def _validate_schema(value: dict[str, Any], schema_path: Path) -> None:
    try:
        import jsonschema
    except ImportError as error:
        raise FacetRouteBenchError(
            "jsonschema is required; run through `uv run`"
        ) from error
    schema = read_json(schema_path)
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(value)
    except jsonschema.SchemaError as error:
        raise FacetRouteBenchError(
            f"invalid JSON Schema {schema_path}: {error}"
        ) from error
    except jsonschema.ValidationError as error:
        raise FacetRouteBenchError(
            f"schema validation failed: {error.message}"
        ) from error


def validate_contracts() -> dict[str, Any]:
    benchmark = load_benchmark_contract()
    routes = load_route_contract()
    for schema_path in (
        CONTRACTS_DIR / "dataset.schema.json",
        CONTRACTS_DIR / "run-manifest.schema.json",
        SCHEMAS_DIR / "generator-output.schema.json",
        SCHEMAS_DIR / "canon-validator-output.schema.json",
        SCHEMAS_DIR / "validator-output.schema.json",
        SCHEMAS_DIR / "duplicate-output.schema.json",
    ):
        schema = read_json(schema_path)
        try:
            import jsonschema
        except ImportError as error:
            raise FacetRouteBenchError(
                "jsonschema is required; run through `uv run`"
            ) from error
        jsonschema.Draft202012Validator.check_schema(schema)
    dataset_schema = read_json(CONTRACTS_DIR / "dataset.schema.json")
    if dataset_schema["$defs"]["routeId"]["enum"] != routes["route_order"]:
        raise FacetRouteBenchError(
            "dataset schema Route IDs diverge from route contract"
        )
    if set(dataset_schema["$defs"]["facetId"]["enum"]) != set(routes["facet_order"]):
        raise FacetRouteBenchError("dataset schema facets diverge from route contract")
    validator_schema = read_json(SCHEMAS_DIR / "validator-output.schema.json")
    validator_labels = validator_schema["properties"]["predictions"]["items"][
        "properties"
    ]["predicted_route_id"]["enum"]
    if validator_labels != [*routes["route_order"], "AMBIGUOUS"]:
        raise FacetRouteBenchError("blind validator labels diverge from route contract")
    dataset_domains = dataset_schema["properties"]["domain"]["enum"]
    if dataset_domains != ["narrative", "shared_daily", "mixed"]:
        raise FacetRouteBenchError("dataset domains diverge from authoring contract")
    if not PERSONA_CORE_PATH.is_file():
        raise FacetRouteBenchError("runtime persona core is missing")
    source_router = REPO_ROOT / routes["source"]["router_path"]
    source_cards = REPO_ROOT / routes["source"]["cards_path"]
    if sha256_file(source_router) != routes["source"]["router_sha256"]:
        raise FacetRouteBenchError("runtime scene router changed from route contract")
    if sha256_file(source_cards) != routes["source"]["cards_sha256"]:
        raise FacetRouteBenchError("runtime scene cards changed from route contract")
    return {
        "benchmark_id": benchmark["benchmark_id"],
        "benchmark_version": benchmark["benchmark_version"],
        "fixed_record_total": benchmark["counts"]["fixed_record_total"],
        "route_count": len(routes["route_order"]),
        "facet_count": len(routes["facet_order"]),
        "runtime_source_hashes_match": True,
        "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
    }


def validate_dataset_dir(dataset_dir: Path) -> dict[str, Any]:
    manifest = read_json(dataset_dir / "dataset_manifest.json")
    if manifest.get("status") != "valid":
        raise FacetRouteBenchError("dataset manifest is not marked valid")
    expected_contracts = {
        "benchmark_sha256": sha256_file(CONTRACTS_DIR / "benchmark.v1.json"),
        "routes_sha256": sha256_file(CONTRACTS_DIR / "routes.v1.json"),
        "dataset_schema_sha256": sha256_file(
            CONTRACTS_DIR / "dataset.schema.json"
        ),
        "persona_core_sha256": sha256_file(PERSONA_CORE_PATH),
    }
    if any(
        manifest.get("contracts", {}).get(key) != value
        for key, value in expected_contracts.items()
    ):
        raise FacetRouteBenchError("dataset manifest contracts are stale")
    records: list[dict[str, Any]] = []
    split_counts: dict[str, int] = {}
    for split in ("authoring", "dev", "frozen", "context_challenge"):
        split_manifest = manifest.get("splits", {}).get(split)
        if not isinstance(split_manifest, dict) or not isinstance(
            split_manifest.get("path"), str
        ):
            raise FacetRouteBenchError(f"dataset manifest is missing split {split}")
        path = dataset_dir / split_manifest["path"]
        if sha256_file(path) != split_manifest.get("sha256"):
            raise FacetRouteBenchError(f"dataset split SHA mismatch: {split}")
        rows = read_jsonl(path)
        for row in rows:
            validate_record_schema(row)
            validate_record_semantics(row)
        split_counts[split] = len(rows)
        records.extend(rows)
    validate_dataset_counts(records, load_benchmark_contract())
    return {"total": len(records), "splits": split_counts}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="frbench",
        description="FacetRouteBench authoring and evaluation harness",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("validate-contracts")

    validate_dataset = commands.add_parser("validate-dataset")
    validate_dataset.add_argument("--dataset-dir", required=True, type=Path)

    plan = commands.add_parser("create-plan")
    plan.add_argument("--output", required=True, type=Path)

    generate = commands.add_parser("generate-candidates")
    generate.add_argument("--plan", required=True, type=Path)
    generate.add_argument("--output", required=True, type=Path)
    generate.add_argument("--calls", required=True, type=Path)
    generate.add_argument("--codex-bin", default="codex")
    generate.add_argument("--oversample-factor", type=float, default=1.5)
    generate.add_argument("--max-candidates-per-call", type=int, default=12)
    generate.add_argument("--timeout-seconds", type=float, default=600)
    generate.add_argument("--task-start", type=int, default=0)
    generate.add_argument("--task-end", type=int)

    canon_validate = commands.add_parser("canon-validate")
    canon_validate.add_argument("--candidates", required=True, type=Path)
    canon_validate.add_argument("--accepted", required=True, type=Path)
    canon_validate.add_argument("--rejected", required=True, type=Path)
    canon_validate.add_argument("--calls", required=True, type=Path)
    canon_validate.add_argument("--codex-bin", default="codex")
    canon_validate.add_argument("--batch-size", type=int, default=12)
    canon_validate.add_argument("--timeout-seconds", type=float, default=600)
    canon_validate.add_argument("--candidate-start", type=int, default=0)
    canon_validate.add_argument("--candidate-end", type=int)

    validate = commands.add_parser("blind-validate")
    validate.add_argument("--candidates", required=True, type=Path)
    validate.add_argument("--accepted", required=True, type=Path)
    validate.add_argument("--rejected", required=True, type=Path)
    validate.add_argument("--calls", required=True, type=Path)
    validate.add_argument("--codex-bin", default="codex")
    validate.add_argument("--batch-size", type=int, default=12)
    validate.add_argument("--timeout-seconds", type=float, default=600)
    validate.add_argument("--candidate-start", type=int, default=0)
    validate.add_argument("--candidate-end", type=int)

    refill = commands.add_parser("refill-shortages")
    refill.add_argument("--plan", required=True, type=Path)
    refill.add_argument("--candidates", required=True, type=Path)
    refill.add_argument("--generation-calls", required=True, type=Path)
    refill.add_argument("--canon-accepted", required=True, type=Path)
    refill.add_argument("--canon-rejected", required=True, type=Path)
    refill.add_argument("--canon-calls", required=True, type=Path)
    refill.add_argument("--accepted", required=True, type=Path)
    refill.add_argument("--rejected", required=True, type=Path)
    refill.add_argument("--validation-calls", required=True, type=Path)
    refill.add_argument("--codex-bin", default="codex")
    refill.add_argument("--max-candidates-per-call", type=int, default=12)
    refill.add_argument("--generation-workers", type=int, default=1)
    refill.add_argument("--validation-batch-size", type=int, default=12)
    refill.add_argument("--timeout-seconds", type=float, default=600)

    merge_generation = commands.add_parser("merge-generation-shards")
    merge_generation.add_argument("--candidates", required=True, nargs="+", type=Path)
    merge_generation.add_argument("--calls", required=True, nargs="+", type=Path)
    merge_generation.add_argument("--output", required=True, type=Path)
    merge_generation.add_argument("--calls-output", required=True, type=Path)
    merge_generation.add_argument("--oversample-factor", type=float, default=1.5)

    merge_validation = commands.add_parser("merge-validation-shards")
    merge_validation.add_argument("--candidates", required=True, type=Path)
    merge_validation.add_argument("--accepted", required=True, nargs="+", type=Path)
    merge_validation.add_argument("--rejected", required=True, nargs="+", type=Path)
    merge_validation.add_argument("--calls", required=True, nargs="+", type=Path)
    merge_validation.add_argument("--accepted-output", required=True, type=Path)
    merge_validation.add_argument("--rejected-output", required=True, type=Path)
    merge_validation.add_argument("--calls-output", required=True, type=Path)

    coverage = commands.add_parser("coverage-report")
    coverage.add_argument("--accepted", required=True, type=Path)

    shortlist = commands.add_parser("shortlist-duplicates")
    shortlist.add_argument("--accepted", required=True, type=Path)
    shortlist.add_argument("--output", required=True, type=Path)
    shortlist.add_argument("--top-k-cross-split", type=int, default=5)
    shortlist.add_argument("--minimum-jaccard", type=float, default=0.35)

    audit = commands.add_parser("audit-duplicates")
    audit.add_argument("--pairs", required=True, type=Path)
    audit.add_argument("--output", required=True, type=Path)
    audit.add_argument("--calls", required=True, type=Path)
    audit.add_argument("--codex-bin", default="codex")
    audit.add_argument("--batch-size", type=int, default=20)
    audit.add_argument("--timeout-seconds", type=float, default=600)

    freeze = commands.add_parser("freeze-dataset")
    freeze.add_argument("--accepted", required=True, type=Path)
    freeze.add_argument("--duplicate-audit", required=True, type=Path)
    freeze.add_argument("--output-dir", required=True, type=Path)
    freeze.add_argument("--dataset-version", default="3.0.0")

    prepare_embeddings = commands.add_parser("prepare-embedding-inputs")
    prepare_embeddings.add_argument("--dataset-dir", required=True, type=Path)
    prepare_embeddings.add_argument("--output", required=True, type=Path)

    extract = commands.add_parser("extract-embeddings")
    extract.add_argument("--inputs", required=True, type=Path)
    extract.add_argument("--model", required=True, type=Path)
    extract.add_argument("--tokenizer", required=True, type=Path)
    extract.add_argument("--output-dir", required=True, type=Path)
    extract.add_argument("--runtime-mode", choices=("warm", "cold"), default="warm")

    embedding_dev = commands.add_parser("run-embedding-dev")
    embedding_dev.add_argument("--dev", required=True, type=Path)
    embedding_dev.add_argument("--embeddings", required=True, type=Path)
    embedding_dev.add_argument("--output-dir", required=True, type=Path)

    threshold_comparison = commands.add_parser("compare-route-thresholds")
    threshold_comparison.add_argument("--dev", required=True, type=Path)
    threshold_comparison.add_argument("--frozen", required=True, type=Path)
    threshold_comparison.add_argument("--embeddings", required=True, type=Path)
    threshold_comparison.add_argument("--output-dir", required=True, type=Path)

    select = commands.add_parser("select-embedding-candidate")
    select.add_argument("--dev-summary", required=True, type=Path)
    select.add_argument("--frozen", required=True, type=Path)
    select.add_argument(
        "--route-contract",
        type=Path,
        default=CONTRACTS_DIR / "routes.v1.json",
    )
    select.add_argument("--output", required=True, type=Path)

    frozen = commands.add_parser("run-embedding-frozen")
    frozen.add_argument("--selection", required=True, type=Path)
    frozen.add_argument("--frozen", required=True, type=Path)
    frozen.add_argument("--embeddings", required=True, type=Path)
    frozen.add_argument("--output-dir", required=True, type=Path)

    context = commands.add_parser("run-embedding-context")
    context.add_argument("--selection", required=True, type=Path)
    context.add_argument("--context", required=True, type=Path)
    context.add_argument("--embeddings", required=True, type=Path)
    context.add_argument("--output-dir", required=True, type=Path)

    gemma = commands.add_parser("run-gemma")
    gemma.add_argument("--dataset", required=True, type=Path)
    gemma.add_argument("--model", required=True, type=Path)
    gemma.add_argument(
        "--prompt",
        type=Path,
        default=REPO_ROOT
        / "ios/EdgeLLM/Sources/EdgeLLM/Resources/Prompts/RoutedPersona/scene_router.md",
    )
    gemma.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs/gemma-router.v1.json",
    )
    gemma.add_argument("--output-dir", required=True, type=Path)
    gemma.add_argument("--backend", choices=("cpu", "gpu"), default="gpu")
    gemma.add_argument("--max-num-tokens", type=int, default=4096)
    gemma.add_argument("--runtime-version", default="0.13.1")
    gemma.add_argument(
        "--include-history",
        action=argparse.BooleanOptionalAction,
        default=False,
    )
    gemma.add_argument("--runtime-mode", choices=("warm", "cold"), default="warm")
    gemma.add_argument("--repeats", type=int, default=1)
    gemma.add_argument("--run-kind", choices=("quality", "latency"), default="quality")
    gemma.add_argument("--workers", type=int, default=1)
    gemma.add_argument("--runtime-python", type=Path)

    score = commands.add_parser("score-predictions")
    score.add_argument("--dataset", required=True, type=Path)
    score.add_argument("--predictions", required=True, type=Path)
    score.add_argument("--output", required=True, type=Path)

    latency = commands.add_parser("summarize-latency")
    latency.add_argument("--predictions", required=True, type=Path)
    latency.add_argument(
        "--router-family",
        required=True,
        choices=("gemma_generative", "embedding_similarity"),
    )
    latency.add_argument("--runtime-mode", required=True, choices=("warm", "cold"))
    latency.add_argument("--output", required=True, type=Path)

    manifest = commands.add_parser("validate-run-manifest")
    manifest.add_argument("--manifest", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "validate-contracts":
            result: Any = validate_contracts()
        elif args.command == "validate-dataset":
            result = validate_dataset_dir(args.dataset_dir)
        elif args.command == "create-plan":
            result = write_plan(args.output)
        elif args.command == "generate-candidates":
            result = generate_candidates(
                plan_path=args.plan,
                output_path=args.output,
                calls_path=args.calls,
                codex_bin=args.codex_bin,
                working_directory=REPO_ROOT,
                oversample_factor=args.oversample_factor,
                max_candidates_per_call=args.max_candidates_per_call,
                timeout_seconds=args.timeout_seconds,
                task_start=args.task_start,
                task_end=args.task_end,
            )
        elif args.command == "canon-validate":
            result = validate_canon_candidates(
                candidates_path=args.candidates,
                accepted_path=args.accepted,
                rejected_path=args.rejected,
                calls_path=args.calls,
                codex_bin=args.codex_bin,
                working_directory=REPO_ROOT,
                batch_size=args.batch_size,
                timeout_seconds=args.timeout_seconds,
                candidate_start=args.candidate_start,
                candidate_end=args.candidate_end,
            )
        elif args.command == "blind-validate":
            result = validate_candidates(
                candidates_path=args.candidates,
                accepted_path=args.accepted,
                rejected_path=args.rejected,
                calls_path=args.calls,
                codex_bin=args.codex_bin,
                working_directory=REPO_ROOT,
                batch_size=args.batch_size,
                timeout_seconds=args.timeout_seconds,
                candidate_start=args.candidate_start,
                candidate_end=args.candidate_end,
            )
        elif args.command == "refill-shortages":
            result = refill_shortages(
                plan_path=args.plan,
                candidates_path=args.candidates,
                generation_calls_path=args.generation_calls,
                canon_accepted_path=args.canon_accepted,
                canon_rejected_path=args.canon_rejected,
                canon_calls_path=args.canon_calls,
                accepted_path=args.accepted,
                rejected_path=args.rejected,
                validation_calls_path=args.validation_calls,
                codex_bin=args.codex_bin,
                working_directory=REPO_ROOT,
                max_candidates_per_call=args.max_candidates_per_call,
                generation_workers=args.generation_workers,
                validation_batch_size=args.validation_batch_size,
                timeout_seconds=args.timeout_seconds,
            )
        elif args.command == "merge-generation-shards":
            result = merge_generation_shards(
                candidate_paths=args.candidates,
                call_paths=args.calls,
                output_path=args.output,
                calls_output_path=args.calls_output,
                oversample_factor=args.oversample_factor,
            )
        elif args.command == "merge-validation-shards":
            result = merge_validation_shards(
                candidates_path=args.candidates,
                accepted_paths=args.accepted,
                rejected_paths=args.rejected,
                call_paths=args.calls,
                accepted_output_path=args.accepted_output,
                rejected_output_path=args.rejected_output,
                calls_output_path=args.calls_output,
            )
        elif args.command == "coverage-report":
            result = coverage_report(args.accepted)
        elif args.command == "shortlist-duplicates":
            result = shortlist_duplicate_pairs(
                accepted_path=args.accepted,
                output_path=args.output,
                top_k_cross_split=args.top_k_cross_split,
                minimum_jaccard=args.minimum_jaccard,
            )
        elif args.command == "audit-duplicates":
            result = audit_duplicate_pairs(
                pairs_path=args.pairs,
                output_path=args.output,
                calls_path=args.calls,
                codex_bin=args.codex_bin,
                working_directory=REPO_ROOT,
                batch_size=args.batch_size,
                timeout_seconds=args.timeout_seconds,
            )
        elif args.command == "freeze-dataset":
            result = freeze_dataset(
                accepted_path=args.accepted,
                duplicate_audit_path=args.duplicate_audit,
                output_dir=args.output_dir,
                dataset_version=args.dataset_version,
            )
        elif args.command == "prepare-embedding-inputs":
            result = prepare_embedding_inputs(args.dataset_dir, args.output)
        elif args.command == "extract-embeddings":
            result = extract_embeddings(
                inputs_path=args.inputs,
                model_path=args.model,
                tokenizer_path=args.tokenizer,
                output_dir=args.output_dir,
                runtime_mode=args.runtime_mode,
            )
        elif args.command == "run-embedding-dev":
            result = run_embedding_dev(
                dev_path=args.dev,
                embeddings_path=args.embeddings,
                output_dir=args.output_dir,
            )
        elif args.command == "compare-route-thresholds":
            result = compare_threshold_strategies(
                dev_path=args.dev,
                frozen_path=args.frozen,
                embeddings_path=args.embeddings,
                output_dir=args.output_dir,
            )
        elif args.command == "select-embedding-candidate":
            result = select_embedding_candidate(
                dev_summary_path=args.dev_summary,
                frozen_path=args.frozen,
                route_contract_path=args.route_contract,
                output_path=args.output,
            )
        elif args.command == "run-embedding-frozen":
            result = run_embedding_frozen(
                selection_path=args.selection,
                frozen_path=args.frozen,
                embeddings_path=args.embeddings,
                output_dir=args.output_dir,
            )
        elif args.command == "run-embedding-context":
            result = run_embedding_context(
                selection_path=args.selection,
                context_path=args.context,
                embeddings_path=args.embeddings,
                output_dir=args.output_dir,
            )
        elif args.command == "run-gemma":
            result = run_gemma_router(
                dataset_path=args.dataset,
                model_path=args.model,
                prompt_path=args.prompt,
                config_path=args.config,
                output_dir=args.output_dir,
                backend=args.backend,
                max_num_tokens=args.max_num_tokens,
                runtime_version=args.runtime_version,
                include_history=args.include_history,
                runtime_mode=args.runtime_mode,
                repeats=args.repeats,
                run_kind=args.run_kind,
                workers=args.workers,
                runtime_python=args.runtime_python,
            )
        elif args.command == "score-predictions":
            result = score_prediction_file(
                dataset_path=args.dataset,
                predictions_path=args.predictions,
                output_path=args.output,
            )
        elif args.command == "summarize-latency":
            result = summarize_latency(
                predictions_path=args.predictions,
                router_family=args.router_family,
                runtime_mode=args.runtime_mode,
                output_path=args.output,
            )
        elif args.command == "validate-run-manifest":
            validate_run_manifest(read_json(args.manifest))
            result = {"valid": True, "path": str(args.manifest.resolve())}
        else:
            raise AssertionError(args.command)
    except (FacetRouteBenchError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if isinstance(result, Path):
        print(result)
    elif isinstance(result, tuple):
        print("\n".join(str(item) for item in result))
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
