from __future__ import annotations

import argparse
import json
from pathlib import Path

from .common import CONFIGS_DIR, PROMPTS_DIR, ToolRouteBenchError, read_jsonl
from .authoring import (
    freeze_dataset,
    freeze_development_dataset,
    freeze_holdout_dataset,
    generate_candidates,
    validate_candidates,
    write_plan,
)
from .actionability import ACTIONABILITY_CONFIG, prepare_3i4k_actionability_dataset
from .actionability_labeled import prepare_labeled_3i4k_actionability_dataset
from .actionability_mlp import train_actionability_mlp
from .hnoos import HNOOS_CONFIG, prepare_hnoos_actionability_auxiliary
from .hnoos_translation import (
    HNOOS_TRANSLATION_CONFIG,
    HNOOS_TRANSLATION_PROMPT,
    run_hnoos_korean_translation,
)
from .petai_candidate_mining import (
    PETAI_MINING_CONFIG,
    mine_3i4k_petai_candidates,
    prepare_3i4k_petai_mining_pool,
)
from .petai_candidate_labeling import (
    prepare_balanced_3i4k_actionability_pool,
    prepare_3i4k_petai_labeling_queue,
    reconcile_3i4k_petai_labels,
    run_3i4k_petai_labeling_stage,
)
from .contracts import (
    validate_contracts,
    validate_dataset,
    validate_development_dataset,
    validate_holdout_dataset,
    validate_run_manifest,
)
from .embedding import extract_embeddings, prepare_embedding_inputs
from .gemma_runner import run_gemma_prompt_router
from .runner import (
    create_holdout_lock,
    run_dev_grid,
    run_locked_track,
    score_regex_track,
)
from .regex_baseline import export_regex_predictions


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ToolRouteBench comparison harness")
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

    gemma = commands.add_parser(
        "run-gemma-router",
        help="run the prompt-only Gemma 4 E2B IT retrospective router",
    )
    gemma.add_argument("--dataset", type=Path, required=True)
    gemma.add_argument("--model-artifact", type=Path, required=True)
    gemma.add_argument(
        "--prompt",
        type=Path,
        default=PROMPTS_DIR / "gemma-e2b-router-retrospective-v1.md",
    )
    gemma.add_argument(
        "--config",
        type=Path,
        default=CONFIGS_DIR / "gemma-router.retrospective.v1.json",
    )
    gemma.add_argument("--output-dir", type=Path, required=True)
    gemma.add_argument("--base-url", default="http://127.0.0.1:9379")
    gemma.add_argument("--runtime-version", required=True)
    gemma.add_argument("--backend", choices=("cpu", "gpu"), default="cpu")
    gemma.add_argument("--timeout-seconds", type=float, default=120.0)

    actionability_data = commands.add_parser(
        "prepare-3i4k-actionability",
        help="prepare the deterministic binary 3i4K CALL/NO_CALL smoke dataset",
    )
    actionability_data.add_argument("--source-cache-dir", type=Path, required=True)
    actionability_data.add_argument("--output-dir", type=Path, required=True)
    actionability_data.add_argument(
        "--config",
        type=Path,
        default=ACTIONABILITY_CONFIG,
    )

    actionability_mlp = commands.add_parser(
        "train-actionability-mlp",
        help="train and evaluate a binary MLP head over fixed EmbeddingGemma vectors",
    )
    actionability_mlp.add_argument("--public-embeddings", type=Path, required=True)
    actionability_mlp.add_argument(
        "--public-embedding-manifest", type=Path, required=True
    )
    actionability_mlp.add_argument("--output-dir", type=Path, required=True)
    actionability_mlp.add_argument("--auxiliary-train-embeddings", type=Path)
    actionability_mlp.add_argument(
        "--auxiliary-train-embedding-manifest", type=Path
    )
    actionability_mlp.add_argument("--petai-train-dataset", type=Path)
    actionability_mlp.add_argument("--petai-train-embeddings", type=Path)
    actionability_mlp.add_argument("--petai-train-embedding-manifest", type=Path)
    actionability_mlp.add_argument(
        "--petai-train-mode",
        choices=("call-only", "all"),
        default="all",
    )
    actionability_mlp.add_argument("--petai-dev-dataset", type=Path)
    actionability_mlp.add_argument("--petai-dev-embeddings", type=Path)
    actionability_mlp.add_argument("--petai-holdout-dataset", type=Path)
    actionability_mlp.add_argument("--petai-holdout-embeddings", type=Path)
    actionability_mlp.add_argument(
        "--config",
        type=Path,
        default=ACTIONABILITY_CONFIG,
    )

    labeled_actionability = commands.add_parser(
        "prepare-labeled-3i4k-actionability",
        help="split agreed PetAI contract labels and reuse their fixed embeddings",
    )
    labeled_actionability.add_argument(
        "--balanced-pool-manifest", type=Path, required=True
    )
    labeled_actionability.add_argument("--source-embeddings", type=Path, required=True)
    labeled_actionability.add_argument(
        "--source-embedding-manifest", type=Path, required=True
    )
    labeled_actionability.add_argument("--output-dir", type=Path, required=True)
    labeled_actionability.add_argument("--seed", type=int, default=20260811)

    hnoos_data = commands.add_parser(
        "prepare-hnoos-actionability-aux",
        help="prepare the PetAI-relevant English hard-negative OOS train auxiliary",
    )
    hnoos_data.add_argument("--source-cache-dir", type=Path, required=True)
    hnoos_data.add_argument("--output-dir", type=Path, required=True)
    hnoos_data.add_argument("--config", type=Path, default=HNOOS_CONFIG)

    hnoos_translation = commands.add_parser(
        "translate-hnoos-actionability-aux",
        help="translate the English HN-OOS auxiliary to Korean with local Gemma",
    )
    hnoos_translation.add_argument("--dataset", type=Path, required=True)
    hnoos_translation.add_argument(
        "--dataset-manifest", type=Path, required=True
    )
    hnoos_translation.add_argument("--model-artifact", type=Path, required=True)
    hnoos_translation.add_argument(
        "--prompt", type=Path, default=HNOOS_TRANSLATION_PROMPT
    )
    hnoos_translation.add_argument(
        "--config", type=Path, default=HNOOS_TRANSLATION_CONFIG
    )
    hnoos_translation.add_argument("--output-dir", type=Path, required=True)
    hnoos_translation.add_argument("--base-url", default="http://127.0.0.1:9379")
    hnoos_translation.add_argument("--runtime-version", required=True)
    hnoos_translation.add_argument(
        "--backend", choices=("cpu", "gpu"), default="cpu"
    )
    hnoos_translation.add_argument("--timeout-seconds", type=float, default=120.0)

    mining_pool = commands.add_parser(
        "prepare-3i4k-petai-mining-pool",
        help="prepare the full unlabeled 3i4K train pool for PetAI candidate search",
    )
    mining_pool.add_argument("--source-cache-dir", type=Path, required=True)
    mining_pool.add_argument("--output-dir", type=Path, required=True)
    mining_pool.add_argument(
        "--source-config",
        type=Path,
        default=ACTIONABILITY_CONFIG,
    )

    mine_candidates = commands.add_parser(
        "mine-3i4k-petai-candidates",
        help="rank the full 3i4K train pool for PetAI contract labeling",
    )
    mine_candidates.add_argument("--pool", type=Path, required=True)
    mine_candidates.add_argument("--pool-manifest", type=Path, required=True)
    mine_candidates.add_argument("--query-embeddings", type=Path, required=True)
    mine_candidates.add_argument(
        "--query-embedding-manifest", type=Path, required=True
    )
    mine_candidates.add_argument("--prototype-embeddings", type=Path, required=True)
    mine_candidates.add_argument(
        "--prototype-embedding-manifest", type=Path, required=True
    )
    mine_candidates.add_argument("--selected-candidate", type=Path, required=True)
    mine_candidates.add_argument("--output-dir", type=Path, required=True)
    mine_candidates.add_argument(
        "--config", type=Path, default=PETAI_MINING_CONFIG
    )
    mine_candidates.add_argument("--gemma-predictions", type=Path)

    labeling_queue = commands.add_parser(
        "prepare-3i4k-petai-labeling-queue",
        help="combine mined candidates and rejected audit rows for blind labeling",
    )
    labeling_queue.add_argument("--mining-manifest", type=Path, required=True)
    labeling_queue.add_argument("--output-dir", type=Path, required=True)

    labeling_stage = commands.add_parser(
        "run-3i4k-petai-labeling-stage",
        help="run one independent PetAI contract labeling stage",
    )
    labeling_stage.add_argument("--queue", type=Path, required=True)
    labeling_stage.add_argument("--queue-manifest", type=Path, required=True)
    labeling_stage.add_argument("--output-dir", type=Path, required=True)
    labeling_stage.add_argument(
        "--stage", choices=("contract", "blind"), required=True
    )
    labeling_stage.add_argument("--codex-bin", default="codex")
    labeling_stage.add_argument("--batch-size", type=int, default=100)
    labeling_stage.add_argument("--timeout-seconds", type=float, default=600)

    reconcile_labels = commands.add_parser(
        "reconcile-3i4k-petai-labels",
        help="keep only exact non-ambiguous agreement from both labeling stages",
    )
    reconcile_labels.add_argument("--queue", type=Path, required=True)
    reconcile_labels.add_argument("--queue-manifest", type=Path, required=True)
    reconcile_labels.add_argument("--contract-manifest", type=Path, required=True)
    reconcile_labels.add_argument("--blind-manifest", type=Path, required=True)
    reconcile_labels.add_argument("--output-dir", type=Path, required=True)
    reconcile_labels.add_argument(
        "--audit-per-partition-label", type=int, default=50
    )
    reconcile_labels.add_argument("--seed", type=int, default=20260811)

    balanced_pool = commands.add_parser(
        "prepare-balanced-3i4k-actionability-pool",
        help="balance provisional agreed 3i4K CALL and NO_CALL rows",
    )
    balanced_pool.add_argument(
        "--reconciliation-manifest", type=Path, required=True
    )
    balanced_pool.add_argument("--output-dir", type=Path, required=True)
    balanced_pool.add_argument(
        "--candidate-no-call-fraction", type=float, default=0.8
    )
    balanced_pool.add_argument("--seed", type=int, default=20260811)

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
        elif args.command == "run-gemma-router":
            print(
                run_gemma_prompt_router(
                    dataset_path=args.dataset,
                    model_artifact_path=args.model_artifact,
                    prompt_path=args.prompt,
                    config_path=args.config,
                    output_dir=args.output_dir,
                    base_url=args.base_url,
                    runtime_version=args.runtime_version,
                    backend=args.backend,
                    timeout_seconds=args.timeout_seconds,
                )
            )
        elif args.command == "prepare-3i4k-actionability":
            print(
                prepare_3i4k_actionability_dataset(
                    source_cache_dir=args.source_cache_dir,
                    output_dir=args.output_dir,
                    config_path=args.config,
                )
            )
        elif args.command == "train-actionability-mlp":
            print(
                train_actionability_mlp(
                    public_embeddings_path=args.public_embeddings,
                    public_embedding_manifest_path=args.public_embedding_manifest,
                    output_dir=args.output_dir,
                    auxiliary_train_embeddings_path=args.auxiliary_train_embeddings,
                    auxiliary_train_embedding_manifest_path=(
                        args.auxiliary_train_embedding_manifest
                    ),
                    petai_train_dataset_path=args.petai_train_dataset,
                    petai_train_embeddings_path=args.petai_train_embeddings,
                    petai_train_embedding_manifest_path=(
                        args.petai_train_embedding_manifest
                    ),
                    petai_train_mode=args.petai_train_mode,
                    petai_dev_dataset_path=args.petai_dev_dataset,
                    petai_dev_embeddings_path=args.petai_dev_embeddings,
                    petai_holdout_dataset_path=args.petai_holdout_dataset,
                    petai_holdout_embeddings_path=args.petai_holdout_embeddings,
                    config_path=args.config,
                )
            )
        elif args.command == "prepare-labeled-3i4k-actionability":
            print(
                prepare_labeled_3i4k_actionability_dataset(
                    balanced_pool_manifest_path=args.balanced_pool_manifest,
                    source_embeddings_path=args.source_embeddings,
                    source_embedding_manifest_path=args.source_embedding_manifest,
                    output_dir=args.output_dir,
                    seed=args.seed,
                )
            )
        elif args.command == "prepare-hnoos-actionability-aux":
            print(
                prepare_hnoos_actionability_auxiliary(
                    source_cache_dir=args.source_cache_dir,
                    output_dir=args.output_dir,
                    config_path=args.config,
                )
            )
        elif args.command == "translate-hnoos-actionability-aux":
            print(
                run_hnoos_korean_translation(
                    dataset_path=args.dataset,
                    dataset_manifest_path=args.dataset_manifest,
                    model_artifact_path=args.model_artifact,
                    prompt_path=args.prompt,
                    config_path=args.config,
                    output_dir=args.output_dir,
                    base_url=args.base_url,
                    runtime_version=args.runtime_version,
                    backend=args.backend,
                    timeout_seconds=args.timeout_seconds,
                )
            )
        elif args.command == "prepare-3i4k-petai-mining-pool":
            print(
                prepare_3i4k_petai_mining_pool(
                    source_cache_dir=args.source_cache_dir,
                    output_dir=args.output_dir,
                    source_config_path=args.source_config,
                )
            )
        elif args.command == "mine-3i4k-petai-candidates":
            print(
                mine_3i4k_petai_candidates(
                    pool_path=args.pool,
                    pool_manifest_path=args.pool_manifest,
                    query_embeddings_path=args.query_embeddings,
                    query_embedding_manifest_path=(
                        args.query_embedding_manifest
                    ),
                    prototype_embeddings_path=args.prototype_embeddings,
                    prototype_embedding_manifest_path=(
                        args.prototype_embedding_manifest
                    ),
                    selected_candidate_path=args.selected_candidate,
                    output_dir=args.output_dir,
                    config_path=args.config,
                    gemma_predictions_path=args.gemma_predictions,
                )
            )
        elif args.command == "prepare-3i4k-petai-labeling-queue":
            print(
                prepare_3i4k_petai_labeling_queue(
                    mining_manifest_path=args.mining_manifest,
                    output_dir=args.output_dir,
                )
            )
        elif args.command == "run-3i4k-petai-labeling-stage":
            print(
                run_3i4k_petai_labeling_stage(
                    queue_path=args.queue,
                    queue_manifest_path=args.queue_manifest,
                    output_dir=args.output_dir,
                    stage=args.stage,
                    codex_bin=args.codex_bin,
                    batch_size=args.batch_size,
                    timeout_seconds=args.timeout_seconds,
                )
            )
        elif args.command == "reconcile-3i4k-petai-labels":
            print(
                reconcile_3i4k_petai_labels(
                    queue_path=args.queue,
                    queue_manifest_path=args.queue_manifest,
                    contract_manifest_path=args.contract_manifest,
                    blind_manifest_path=args.blind_manifest,
                    output_dir=args.output_dir,
                    audit_per_partition_label=args.audit_per_partition_label,
                    seed=args.seed,
                )
            )
        elif args.command == "prepare-balanced-3i4k-actionability-pool":
            print(
                prepare_balanced_3i4k_actionability_pool(
                    reconciliation_manifest_path=args.reconciliation_manifest,
                    output_dir=args.output_dir,
                    candidate_no_call_fraction=args.candidate_no_call_fraction,
                    seed=args.seed,
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
