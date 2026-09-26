from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from .common import GuardrailError
from .config import default_config_path, load_config
from .doctor import run_doctor
from .report import latest_baseline_run_dir, latest_run_dir, render_report
from .runner import run_baseline, run_comparison
from .sources import fetch_datasets, fetch_input_guard, fetch_qwen3guard


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="guardrail")
    subparsers = parser.add_subparsers(dest="command", required=True)
    doctor = subparsers.add_parser("doctor")
    doctor.add_argument("--profile", choices=["smoke", "baseline"], default="smoke")
    subparsers.add_parser("fetch")
    for name in ("smoke", "baseline"):
        run = subparsers.add_parser(name)
        run.add_argument("--run-id")
    compare = subparsers.add_parser("compare")
    compare.add_argument("--profile", choices=["smoke", "baseline"], default="smoke")
    compare.add_argument("--run-id")
    compare.add_argument("--baseline-run", type=Path)
    report = subparsers.add_parser("report")
    report.add_argument("--run-dir", type=Path)
    report.add_argument("--latest", action="store_true")
    return parser


def _run_id(profile: str) -> str:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    return f"{profile}-{stamp}"


def main() -> None:
    args = _parser().parse_args()
    try:
        if args.command == "doctor":
            result = run_doctor(load_config(default_config_path(args.profile)))
            print(json.dumps(result, ensure_ascii=False, indent=2))
            if not result["ok"]:
                raise SystemExit(1)
        elif args.command == "fetch":
            datasets = fetch_datasets()
            qwen = fetch_qwen3guard()
            input_guard = fetch_input_guard()
            print(
                json.dumps(
                    {
                        "datasets": {k: str(v) for k, v in datasets.items()},
                        "qwen3guard": str(qwen),
                        "input_guard": str(input_guard),
                    },
                    indent=2,
                )
            )
        elif args.command in {"smoke", "baseline"}:
            config = load_config(default_config_path(args.command))
            run_dir = run_baseline(config, args.run_id or _run_id(args.command))
            print(run_dir)
        elif args.command == "compare":
            config = load_config(default_config_path(args.profile))
            baseline_run = args.baseline_run or latest_baseline_run_dir(args.profile)
            run_id = args.run_id or _run_id(f"compare-{args.profile}")
            print(run_comparison(config, run_id, baseline_run))
        elif args.command == "report":
            run_dir = args.run_dir or latest_run_dir()
            print(render_report(run_dir))
    except GuardrailError as error:
        print(f"guardrail: {error}", file=sys.stderr)
        raise SystemExit(2) from error


if __name__ == "__main__":
    main()
