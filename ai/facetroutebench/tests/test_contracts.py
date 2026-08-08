from __future__ import annotations

import json
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest.mock import patch

from facetroutebench.authoring import (
    PERSONA_CORE_PATH,
    build_canon_validator_prompt,
    build_generator_prompt,
    build_plan,
    build_validator_prompt,
    refill_requests,
    refill_shortages,
    validate_canon_candidates,
    validate_candidates,
)
from facetroutebench.codex_adapter import CodexInvocation
from facetroutebench.common import (
    FacetRouteBenchError,
    parse_unique_route,
    read_jsonl,
    render_router_input,
    write_jsonl,
)
from facetroutebench.contracts import load_route_contract
from facetroutebench.evaluation import classification_metrics, cosine
from facetroutebench.evaluation import (
    GENERAL_COMPETITION_CANDIDATE,
    _references,
)
from facetroutebench.latency import summarize_latency
from facetroutebench.manifests import validate_run_manifest
from facetroutebench.thresholds import (
    _shrink_thresholds,
    _stratified_fold_ids,
    predict_per_route_thresholds,
    tune_per_route_thresholds,
)


class ContractTests(unittest.TestCase):
    def test_per_route_thresholds_reject_when_no_gate_passes(self) -> None:
        rows = [
            {
                "case_id": "case-1",
                "route_scores": {"ROUTE_A": 0.59, "ROUTE_B": 0.69},
            }
        ]
        predictions = predict_per_route_thresholds(
            rows,
            {"ROUTE_A": 0.60, "ROUTE_B": 0.70},
            ["ROUTE_A", "ROUTE_B"],
        )
        self.assertEqual(predictions[0]["predicted_route_id"], "GENERAL")

    def test_per_route_thresholds_choose_largest_threshold_margin(self) -> None:
        rows = [
            {
                "case_id": "case-1",
                "route_scores": {"ROUTE_A": 0.72, "ROUTE_B": 0.79},
            }
        ]
        predictions = predict_per_route_thresholds(
            rows,
            {"ROUTE_A": 0.60, "ROUTE_B": 0.75},
            ["ROUTE_A", "ROUTE_B"],
        )
        self.assertEqual(predictions[0]["predicted_route_id"], "ROUTE_A")

    def test_per_route_thresholds_can_choose_largest_raw_score(self) -> None:
        rows = [
            {
                "case_id": "case-1",
                "route_scores": {"ROUTE_A": 0.72, "ROUTE_B": 0.79},
            }
        ]
        predictions = predict_per_route_thresholds(
            rows,
            {"ROUTE_A": 0.60, "ROUTE_B": 0.75},
            ["ROUTE_A", "ROUTE_B"],
            arbitration="raw_score",
        )
        self.assertEqual(predictions[0]["predicted_route_id"], "ROUTE_B")

    def test_threshold_shrinkage_zero_recovers_global_threshold(self) -> None:
        self.assertEqual(
            _shrink_thresholds({"A": 0.60, "B": 0.80}, 0.70, 0.0),
            {"A": 0.70, "B": 0.70},
        )

    def test_stratified_folds_are_disjoint_and_complete(self) -> None:
        records = [
            {
                "case_id": f"case-{index}",
                "gold_route_id": "A" if index % 2 else "GENERAL",
                "difficulty": "direct" if index % 3 else "general",
            }
            for index in range(30)
        ]
        folds = _stratified_fold_ids(records)
        self.assertEqual(set().union(*folds), {item["case_id"] for item in records})
        self.assertEqual(sum(len(fold) for fold in folds), len(records))

    def test_tune_per_route_thresholds_uses_each_routes_score_distribution(self) -> None:
        records = [
            {"case_id": "a-positive", "gold_route_id": "ROUTE_A"},
            {"case_id": "b-positive", "gold_route_id": "ROUTE_B"},
            {"case_id": "negative", "gold_route_id": "GENERAL"},
        ]
        rows = [
            {
                "case_id": "a-positive",
                "route_scores": {"ROUTE_A": 0.61, "ROUTE_B": 0.20},
            },
            {
                "case_id": "b-positive",
                "route_scores": {"ROUTE_A": 0.30, "ROUTE_B": 0.81},
            },
            {
                "case_id": "negative",
                "route_scores": {"ROUTE_A": 0.60, "ROUTE_B": 0.80},
            },
        ]
        thresholds, diagnostics = tune_per_route_thresholds(
            records, rows, ["ROUTE_A", "ROUTE_B"]
        )
        self.assertGreater(thresholds["ROUTE_A"], 0.60)
        self.assertLessEqual(thresholds["ROUTE_A"], 0.61)
        self.assertGreater(thresholds["ROUTE_B"], 0.80)
        self.assertLessEqual(thresholds["ROUTE_B"], 0.81)
        self.assertEqual(diagnostics["ROUTE_A"]["f1"], 1.0)
        self.assertEqual(diagnostics["ROUTE_B"]["f1"], 1.0)

    def test_authoring_plan_matches_locked_distribution(self) -> None:
        plan = build_plan()
        totals = Counter()
        cells = Counter()
        for task in plan["tasks"]:
            totals[task["split"]] += task["target_count"]
            cells[(task["split"], task["gold_route_id"], task["difficulty"])] += task[
                "target_count"
            ]
        self.assertEqual(
            totals,
            Counter(authoring=468, dev=696, frozen=696, context_challenge=60),
        )
        self.assertEqual(cells[("authoring", "GENERAL", "general")], 120)
        self.assertEqual(cells[("authoring", "GENERAL", "hard_negative")], 120)
        self.assertEqual(cells[("dev", "GENERAL", "general")], 120)
        self.assertEqual(cells[("frozen", "GENERAL", "hard_negative")], 120)
        hard_negative_tasks = [
            task
            for task in plan["tasks"]
            if task["split"] == "authoring"
            and task["difficulty"] == "hard_negative"
        ]
        self.assertEqual(len(hard_negative_tasks), 19)
        self.assertEqual(
            {task["contrast_route_id"] for task in hard_negative_tasks},
            set(load_route_contract()["route_order"][:-1]),
        )
        self.assertEqual(
            sum((Counter(task["domain_targets"]) for task in hard_negative_tasks), Counter()),
            Counter(shared_daily=40, narrative=40, mixed=40),
        )
        self.assertTrue(
            all(
                set(task["domain_targets"])
                == {"shared_daily", "narrative", "mixed"}
                for task in plan["tasks"]
            )
        )
        self.assertEqual(
            plan["persona_core_sha256"],
            __import__("hashlib").sha256(PERSONA_CORE_PATH.read_bytes()).hexdigest(),
        )

    def test_generator_prompt_uses_core_and_preregistered_domain(self) -> None:
        task = next(
            task
            for task in build_plan()["tasks"]
            if task["task_id"] == "dev-general-general"
        )
        prompt = build_generator_prompt(
            task,
            count=12,
            domain_counts={"shared_daily": 4, "narrative": 4, "mixed": 4},
            route_contract=load_route_contract(),
        )
        self.assertIn(PERSONA_CORE_PATH.read_text(encoding="utf-8").strip(), prompt)
        self.assertIn('"domain_counts"', prompt)
        self.assertIn('"shared_daily": 4', prompt)
        self.assertNotIn("scene_cards.json", prompt)
        self.assertIn("실제로 보낼 법한 대화", prompt)
        self.assertIn("판별 기준을 문장 안에 노출하지 않는다", prompt)

    def test_general_hard_negative_prompt_locks_contrast_route(self) -> None:
        task = next(
            task
            for task in build_plan()["tasks"]
            if task["task_id"]
            == "authoring-general-hard-negative-support-listen"
        )
        prompt = build_generator_prompt(
            task,
            count=6,
            domain_counts=task["domain_targets"],
            route_contract=load_route_contract(),
        )
        self.assertIn('"target_route_id": "GENERAL"', prompt)
        self.assertIn('"contrast_route_id": "SUPPORT_LISTEN"', prompt)
        self.assertIn('"조언 없이 들어달라고 요청"', prompt)

    def test_refill_requests_only_missing_task_domains(self) -> None:
        plan = {
            "tasks": [
                {
                    "task_id": "task-a",
                    "domain_targets": {
                        "shared_daily": 2,
                        "narrative": 1,
                        "mixed": 1,
                    },
                }
            ]
        }
        accepted = [
            {"authoring_task_id": "task-a", "domain": "shared_daily"},
            {"authoring_task_id": "task-a", "domain": "mixed"},
        ]
        self.assertEqual(
            refill_requests(plan, accepted),
            [
                {"task_id": "task-a", "domain": "narrative", "count": 1},
                {"task_id": "task-a", "domain": "shared_daily", "count": 1},
            ],
        )

    def test_refill_runs_generation_canon_and_blind_validation(self) -> None:
        full_plan = build_plan()
        task = dict(full_plan["tasks"][0])
        task["target_count"] = 1
        task["domain_targets"] = {
            "shared_daily": 1,
            "narrative": 0,
            "mixed": 0,
        }
        full_plan["tasks"] = [task]
        invocations = [
            CodexInvocation(
                session_id=f"session-{index}",
                prompt_sha256=character * 64,
                request_sha256=character * 64,
                elapsed_ms=1.0,
                codex_version="test",
            )
            for index, character in enumerate(("a", "b", "c"), start=1)
        ]
        outputs = [
            (
                {
                    "candidates": [
                        {
                            "domain": "shared_daily",
                            "messages": [
                                {"role": "user", "content": "처음 답이 들렸을 때 어땠어?"}
                            ],
                            "style_tags": ["daily_natural"],
                            "neighbor_route_id": None,
                        }
                    ]
                },
                invocations[0],
            ),
            (
                {
                    "decisions": [
                        {
                            "candidate_id": "candidate-placeholder",
                            "accepted": True,
                            "reason_code": "NONE",
                        }
                    ]
                },
                invocations[1],
            ),
            (
                {
                    "predictions": [
                        {
                            "candidate_id": "candidate-placeholder",
                            "predicted_route_id": task["gold_route_id"],
                        }
                    ]
                },
                invocations[2],
            ),
        ]

        def completion_side_effect(**_: object):
            output, invocation = outputs.pop(0)
            if "decisions" in output or "predictions" in output:
                candidate_id = read_jsonl(candidates)[0]["candidate_id"]
                key = "decisions" if "decisions" in output else "predictions"
                output[key][0]["candidate_id"] = candidate_id
            return output, invocation

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan_path = root / "plan.json"
            plan_path.write_text(
                json.dumps(full_plan, ensure_ascii=False), encoding="utf-8"
            )
            paths = {
                name: root / f"{name}.jsonl"
                for name in (
                    "candidates",
                    "generation_calls",
                    "canon_accepted",
                    "canon_rejected",
                    "canon_calls",
                    "accepted",
                    "rejected",
                    "validation_calls",
                )
            }
            for path in paths.values():
                path.write_text("", encoding="utf-8")
            candidates = paths["candidates"]
            with patch(
                "facetroutebench.authoring.complete_json",
                side_effect=completion_side_effect,
            ):
                result = refill_shortages(
                    plan_path=plan_path,
                    candidates_path=candidates,
                    generation_calls_path=paths["generation_calls"],
                    canon_accepted_path=paths["canon_accepted"],
                    canon_rejected_path=paths["canon_rejected"],
                    canon_calls_path=paths["canon_calls"],
                    accepted_path=paths["accepted"],
                    rejected_path=paths["rejected"],
                    validation_calls_path=paths["validation_calls"],
                    codex_bin="codex",
                    working_directory=root,
                    max_candidates_per_call=12,
                    generation_workers=2,
                    validation_batch_size=12,
                    timeout_seconds=10,
                )
            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["completed_rounds"], 1)
            self.assertEqual(len(read_jsonl(paths["accepted"])), 1)
            self.assertFalse(outputs)

    def test_canon_prompt_contains_no_candidate_gold_metadata(self) -> None:
        candidate = {
            "candidate_id": "candidate-1",
            "messages": [{"role": "user", "content": "오늘 같이 산책할래?"}],
            "gold_route_id": "GENERAL",
            "difficulty": "general",
        }
        prompt = build_canon_validator_prompt([candidate])
        candidate_json = prompt.split("## 평가할 후보", 1)[1]
        self.assertIn("candidate-1", candidate_json)
        self.assertNotIn('"gold_route_id"', candidate_json)
        self.assertNotIn('"difficulty"', candidate_json)

    def test_canon_validation_is_required_before_blind_validation(self) -> None:
        candidate = {
            "candidate_id": "candidate-1",
            "authoring_task_id": "dev-general-general",
            "split": "dev",
            "track": "single_turn",
            "gold_route_id": "GENERAL",
            "facet_id": None,
            "difficulty": "general",
            "domain": "shared_daily",
            "messages": [{"role": "user", "content": "오늘 같이 산책할래?"}],
            "style_tags": ["daily_natural"],
            "neighbor_route_id": None,
            "generation_batch_id": "generation-1",
            "generator": {
                "interface": "codex_cli",
                "model": "gpt-5.6-sol",
                "reasoning_effort": "medium",
                "prompt_template_sha256": "a" * 64,
                "request_sha256": "b" * 64,
                "session_id": "generator-session",
            },
        }
        invocation = CodexInvocation(
            session_id="canon-session",
            prompt_sha256="c" * 64,
            request_sha256="d" * 64,
            elapsed_ms=1.0,
            codex_version="test",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidates = root / "candidates.jsonl"
            write_jsonl(candidates, [candidate])
            with patch(
                "facetroutebench.authoring.complete_json",
                return_value=(
                    {
                        "decisions": [
                            {
                                "candidate_id": "candidate-1",
                                "accepted": True,
                                "reason_code": "NONE",
                            }
                        ]
                    },
                    invocation,
                ),
            ):
                validate_canon_candidates(
                    candidates_path=candidates,
                    accepted_path=root / "canon-accepted.jsonl",
                    rejected_path=root / "canon-rejected.jsonl",
                    calls_path=root / "canon-calls.jsonl",
                    codex_bin="codex",
                    working_directory=root,
                    batch_size=12,
                    timeout_seconds=10,
                    candidate_start=0,
                    candidate_end=None,
                )
            accepted = read_jsonl(root / "canon-accepted.jsonl")
            self.assertTrue(accepted[0]["canon_validation_result"]["accepted"])
            with self.assertRaises(FacetRouteBenchError):
                validate_candidates(
                    candidates_path=candidates,
                    accepted_path=root / "accepted.jsonl",
                    rejected_path=root / "rejected.jsonl",
                    calls_path=root / "calls.jsonl",
                    codex_bin="codex",
                    working_directory=root,
                    batch_size=12,
                    timeout_seconds=10,
                    candidate_start=0,
                    candidate_end=None,
                )

    def test_blind_prompt_contains_no_candidate_gold_metadata(self) -> None:
        candidate = {
            "candidate_id": "candidate-1",
            "messages": [{"role": "user", "content": "오늘은 그냥 같이 있어줘"}],
            "gold_route_id": "COMPANION_SILENT_PRESENCE",
            "facet_id": "COMPANION",
            "difficulty": "natural",
        }
        prompt = build_validator_prompt([candidate], load_route_contract())
        candidate_json = prompt.split("## 평가할 후보", 1)[1]
        self.assertIn("candidate-1", candidate_json)
        self.assertNotIn('"gold_route_id"', candidate_json)
        self.assertNotIn('"facet_id"', candidate_json)
        self.assertNotIn('"difficulty"', candidate_json)

    def test_router_input_matches_product_wrapper(self) -> None:
        messages = [
            {"role": "user", "content": "아까 말한 거 기억나?"},
            {"role": "assistant", "content": "응, 두 가지였지."},
            {"role": "user", "content": "그럼 첫 번째로 해줘"},
        ]
        self.assertEqual(
            render_router_input(messages, include_history=True),
            "## 최근 대화\n사용자: 아까 말한 거 기억나?\n캐릭터: 응, 두 가지였지."
            "\n\n## 마지막 사용자 요청\n그럼 첫 번째로 해줘",
        )
        self.assertEqual(
            render_router_input(messages, include_history=False),
            "## 마지막 사용자 요청\n그럼 첫 번째로 해줘",
        )

    def test_invalidated_artifacts_cannot_be_loaded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "INVALIDATED.json").write_text("{}\n", encoding="utf-8")
            dataset = root / "dataset" / "dev.v1.jsonl"
            dataset.parent.mkdir()
            dataset.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(FacetRouteBenchError):
                read_jsonl(dataset)

    def test_route_parser_requires_exactly_one_label(self) -> None:
        routes = load_route_contract()["route_order"]
        self.assertEqual(parse_unique_route("EARTH_FOOD", routes), "EARTH_FOOD")
        self.assertIsNone(parse_unique_route("EARTH_FOOD or GENERAL", routes))
        self.assertIsNone(parse_unique_route("unknown", routes))

    def test_metrics_and_cosine(self) -> None:
        routes = load_route_contract()["route_order"]
        records = [
            {
                "case_id": f"case-{index}",
                "gold_route_id": route,
                "difficulty": "direct",
            }
            for index, route in enumerate(routes)
        ]
        predictions = [
            {"case_id": item["case_id"], "predicted_route_id": item["gold_route_id"]}
            for item in records
        ]
        metrics = classification_metrics(records, predictions)
        self.assertEqual(metrics["macro_f1_20_route"], 1.0)
        self.assertEqual(metrics["accuracy"], 1.0)
        self.assertAlmostEqual(cosine([1.0, 0.0], [1.0, 0.0]), 1.0)

    def test_general_competition_requires_locked_prototype_counts(self) -> None:
        vector = [0.0] * 768
        embeddings = []
        for route in load_route_contract()["route_order"][:-1]:
            embeddings.extend(
                {"kind": "prototype", "route_id": route, "embedding": vector}
                for _ in range(12)
            )
        embeddings.extend(
            {"kind": "prototype", "route_id": "GENERAL", "embedding": vector}
            for _ in range(240)
        )
        references = _references(embeddings, GENERAL_COMPETITION_CANDIDATE)
        self.assertEqual(len(references["GENERAL"]), 240)
        self.assertTrue(
            all(len(references[route]) == 12 for route in references if route != "GENERAL")
        )

    def test_latency_summary_has_linear_interpolated_percentiles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            predictions = root / "predictions.jsonl"
            predictions.write_text(
                "\n".join(
                    json.dumps(
                        {
                            "case_id": f"case-{index}",
                            "route_elapsed_ms": value,
                            "model_load_elapsed_ms": 100.0,
                            "error": None,
                        }
                    )
                    for index, value in enumerate((10.0, 20.0, 30.0))
                )
                + "\n",
                encoding="utf-8",
            )
            output = root / "latency.json"
            summarize_latency(
                predictions_path=predictions,
                router_family="gemma_generative",
                runtime_mode="warm",
                output_path=output,
            )
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["p50_ms"], 20.0)
            self.assertEqual(result["p95_ms"], 29.0)

    def test_run_manifest_contract_accepts_complete_evidence(self) -> None:
        digest = "a" * 64
        validate_run_manifest(
            {
                "benchmark_id": "facetroutebench",
                "benchmark_version": "0.3.0",
                "run_id": "dry-contract-test",
                "status": "completed",
                "git_commit": "abcdef1",
                "started_at": "2026-08-06T00:00:00+00:00",
                "ended_at": "2026-08-06T00:01:00+00:00",
                "track": "controlled_single_turn",
                "candidate": {
                    "candidate_id": "candidate",
                    "router_family": "embedding_similarity",
                    "config_path": "/tmp/config.json",
                    "config_sha256": digest,
                },
                "dataset": {
                    "path": "/tmp/dev.jsonl",
                    "version": "1.0.0",
                    "record_count": 696,
                    "sha256": digest,
                },
                "contracts": [{"path": "/tmp/routes.json", "sha256": digest}],
                "models": [
                    {
                        "role": "embedder",
                        "model_id": "model",
                        "artifact_sha256": digest,
                        "checkpoint_lineage": "revision",
                        "quantization": "mixed",
                    }
                ],
                "runtime": {
                    "name": "LiteRT",
                    "version": "2.1.3",
                    "backend": "cpu",
                },
                "hardware": {
                    "platform": "macos",
                    "device_model": "arm64",
                    "os_version": "test",
                },
                "result": {"path": "/tmp/result.json", "sha256": digest},
            }
        )


if __name__ == "__main__":
    unittest.main()
