from __future__ import annotations

import argparse
import json
from pathlib import Path

from .common import ToolRouteBenchError, read_jsonl
from .authoring import (
    freeze_dataset,
    freeze_development_dataset,
    freeze_holdout_dataset,
    generate_candidates,
    validate_candidates,
    write_plan,
)
from .contracts import (
    validate_contracts,
    validate_dataset,
    validate_development_dataset,
    validate_holdout_dataset,
    validate_run_manifest,
)
from .embedding import extract_embeddings, prepare_embedding_inputs
from .runner import (
    create_holdout_lock,
    run_dev_grid,
    run_locked_track,
    score_regex_track,
)
from .regex_baseline import export_regex_predictions


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ToolRouteBench Pilot harness")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate-contracts", help="validate frozen Pilot contracts")

    plan = commands.add_parser("create-plan", help="write the frozen 615-record plan")
    plan.add_argument("--output", type=Path, required=True)

    generate = commands.add_parser("generate-candidates", help="run isolated Codex generation")
    generate.add_argument("--plan", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.add_argument("--calls", type=Path, required=True)
    generate.add_argument(
        "--splits",
        nargs="+",
        choices=("authoring", "dev", "holdout", "multilabel_challenge"),
        required=True,
    )
    generate.add_argument("--codex-bin", default="codex")
    generate.add_argument("--oversample-factor", type=float, default=1.5)
    generate.add_argument("--timeout-seconds", type=float, default=600)

    for command, stage in (
        ("contract-validate", "contract"),
        ("blind-validate", "blind"),
    ):
        validate = commands.add_parser(command, help=f"run isolated {stage} validation")
        validate.set_defaults(validation_stage=stage)
        validate.add_argument("--candidates", type=Path, required=True)
        validate.add_argument("--accepted", type=Path, required=True)
        validate.add_argument("--rejected", type=Path, required=True)
        validate.add_argument("--calls", type=Path, required=True)
        validate.add_argument("--codex-bin", default="codex")
        validate.add_argument("--batch-size", type=int, default=12)
        validate.add_argument("--timeout-seconds", type=float, default=600)

    freeze = commands.add_parser("freeze-dataset", help="freeze exact accepted cells")
    freeze.add_argument("--plan", type=Path, required=True)
    freeze.add_argument("--accepted", type=Path, required=True)
    freeze.add_argument("--output-dir", type=Path, required=True)
    freeze.add_argument("--dataset-version", default="0.1.0")

    freeze_development = commands.add_parser(
        "freeze-development-dataset",
        help="freeze only Authoring and Dev while Holdout stays sealed",
    )
    freeze_development.add_argument("--plan", type=Path, required=True)
    freeze_development.add_argument("--accepted", type=Path, required=True)
    freeze_development.add_argument("--output-dir", type=Path, required=True)
    freeze_development.add_argument("--dataset-version", default="0.1.0")

    freeze_holdout = commands.add_parser(
        "freeze-holdout-dataset",
        help="freeze the sealed Holdout split without Multi-label data",
    )
    freeze_holdout.add_argument("--plan", type=Path, required=True)
    freeze_holdout.add_argument("--accepted", type=Path, required=True)
    freeze_holdout.add_argument("--output-dir", type=Path, required=True)
    freeze_holdout.add_argument("--dataset-version", default="0.1.0")

    prepare = commands.add_parser("prepare-embedding-inputs")
    prepare.add_argument("--dataset-dir", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument(
        "--prototype-dataset-dir",
        type=Path,
        help="optional frozen dataset that supplies Authoring prototypes",
    )
    prepare.add_argument(
        "--query-splits",
        nargs="+",
        choices=("dev", "holdout", "multilabel_challenge"),
        required=True,
    )

    extract = commands.add_parser("extract-embeddings")
    extract.add_argument("--inputs", type=Path, required=True)
    extract.add_argument("--model", type=Path, required=True)
    extract.add_argument("--tokenizer", type=Path, required=True)
    extract.add_argument("--output-dir", type=Path, required=True)

    dev = commands.add_parser("run-dev-grid")
    dev.add_argument("--dataset-dir", type=Path, required=True)
    dev.add_argument("--embeddings", type=Path, required=True)
    dev.add_argument("--regex-predictions", type=Path, required=True)
    dev.add_argument("--output-dir", type=Path, required=True)

    regex = commands.add_parser("run-regex-baseline")
    regex.add_argument("--dataset", type=Path, required=True)
    regex.add_argument("--output", type=Path, required=True)

    regex_score = commands.add_parser("score-regex-track")
    regex_score.add_argument("--track", choices=("dev", "holdout"), required=True)
    regex_score.add_argument("--dataset-dir", type=Path, required=True)
    regex_score.add_argument("--predictions", type=Path, required=True)
    regex_score.add_argument("--output", type=Path, required=True)

    lock = commands.add_parser("create-holdout-lock")
    lock.add_argument("--selected-candidate", type=Path, required=True)
    lock.add_argument("--dataset-dir", type=Path, required=True)
    lock.add_argument("--output", type=Path, required=True)

    locked = commands.add_parser("run-locked-track")
    locked.add_argument(
        "--track", choices=("holdout", "multilabel_challenge"), required=True
    )
    locked.add_argument("--dataset-dir", type=Path, required=True)
    locked.add_argument("--embeddings", type=Path, required=True)
    locked.add_argument("--lock", type=Path, required=True)
    locked.add_argument("--output", type=Path, required=True)

    dataset = commands.add_parser("validate-dataset", help="validate a frozen JSONL dataset")
    dataset.add_argument("--dataset", type=Path, required=True)

    development_dataset = commands.add_parser(
        "validate-development-dataset",
        help="validate an Authoring and Dev-only frozen dataset",
    )
    development_dataset.add_argument("--dataset", type=Path, required=True)

    holdout_dataset = commands.add_parser(
        "validate-holdout-dataset",
        help="validate a Holdout-only frozen dataset",
    )
    holdout_dataset.add_argument("--dataset", type=Path, required=True)

    manifest = commands.add_parser("validate-run-manifest", help="validate a run manifest")
    manifest.add_argument("--manifest", type=Path, required=True)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    try:
        if args.command == "validate-contracts":
            validate_contracts()
            print(json.dumps({"status": "PASS", "benchmark": "toolroutebench"}))
        elif args.command == "create-plan":
            print(write_plan(args.output))
        elif args.command == "generate-candidates":
            print(
                generate_candidates(
                    plan_path=args.plan,
                    output_path=args.output,
                    calls_path=args.calls,
                    splits=set(args.splits),
                    codex_bin=args.codex_bin,
                    oversample_factor=args.oversample_factor,
                    timeout_seconds=args.timeout_seconds,
                )
            )
        elif args.command in {"contract-validate", "blind-validate"}:
            accepted, rejected = validate_candidates(
                candidates_path=args.candidates,
                accepted_path=args.accepted,
                rejected_path=args.rejected,
                calls_path=args.calls,
                stage=args.validation_stage,
                codex_bin=args.codex_bin,
                batch_size=args.batch_size,
                timeout_seconds=args.timeout_seconds,
            )
            print(json.dumps({"accepted": str(accepted), "rejected": str(rejected)}))
        elif args.command == "freeze-dataset":
            print(
                freeze_dataset(
                    plan_path=args.plan,
                    accepted_path=args.accepted,
                    output_dir=args.output_dir,
                    dataset_version=args.dataset_version,
                )
            )
        elif args.command == "freeze-development-dataset":
            print(
                freeze_development_dataset(
                    plan_path=args.plan,
                    accepted_path=args.accepted,
                    output_dir=args.output_dir,
                    dataset_version=args.dataset_version,
                )
            )
        elif args.command == "freeze-holdout-dataset":
            print(
                freeze_holdout_dataset(
                    plan_path=args.plan,
                    accepted_path=args.accepted,
                    output_dir=args.output_dir,
                    dataset_version=args.dataset_version,
                )
            )
        elif args.command == "prepare-embedding-inputs":
            print(
                prepare_embedding_inputs(
                    args.dataset_dir,
                    args.output,
                    tuple(args.query_splits),
                    args.prototype_dataset_dir,
                )
            )
        elif args.command == "extract-embeddings":
            print(
                extract_embeddings(
                    inputs_path=args.inputs,
                    model_path=args.model,
                    tokenizer_path=args.tokenizer,
                    output_dir=args.output_dir,
                )
            )
        elif args.command == "run-dev-grid":
            print(
                run_dev_grid(
                    dataset_dir=args.dataset_dir,
                    embeddings_path=args.embeddings,
                    regex_predictions_path=args.regex_predictions,
                    output_dir=args.output_dir,
                )
            )
        elif args.command == "run-regex-baseline":
            print(export_regex_predictions(args.dataset, args.output))
        elif args.command == "score-regex-track":
            print(
                score_regex_track(
                    track=args.track,
                    dataset_dir=args.dataset_dir,
                    predictions_path=args.predictions,
                    output_path=args.output,
                )
            )
        elif args.command == "create-holdout-lock":
            print(
                create_holdout_lock(
                    selected_candidate_path=args.selected_candidate,
                    dataset_dir=args.dataset_dir,
                    output_path=args.output,
                )
            )
        elif args.command == "run-locked-track":
            print(
                run_locked_track(
                    track=args.track,
                    dataset_dir=args.dataset_dir,
                    embeddings_path=args.embeddings,
                    lock_path=args.lock,
                    output_path=args.output,
                )
            )
        elif args.command == "validate-dataset":
            records = read_jsonl(args.dataset)
            validate_dataset(records)
            print(json.dumps({"status": "PASS", "records": len(records)}))
        elif args.command == "validate-development-dataset":
            records = read_jsonl(args.dataset)
            validate_development_dataset(records)
            print(json.dumps({"status": "PASS", "records": len(records)}))
        elif args.command == "validate-holdout-dataset":
            records = read_jsonl(args.dataset)
            validate_holdout_dataset(records)
            print(json.dumps({"status": "PASS", "records": len(records)}))
        elif args.command == "validate-run-manifest":
            validate_run_manifest(args.manifest)
            print(json.dumps({"status": "PASS", "manifest": str(args.manifest)}))
    except ToolRouteBenchError as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
