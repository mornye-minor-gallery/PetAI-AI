#!/usr/bin/env python3
"""Run model-free checks, with per-suite progress and durable local logs."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "memory-classifier", "edgemembench", "profile-memory-kv",
    "mrbench-custom", "facetroutebench", "toolroutebench",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", action="store_true", help="Also run the Swift package tests")
    args = parser.parse_args()
    output = ROOT / ".artifacts" / "checks"
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["PYTHONPATH"] = os.pathsep.join(
        str(ROOT / "ai" / name) for name in SUITES
    )
    commands = [
        (name, [sys.executable, "-m", "pytest", "-q", "--import-mode=importlib", "tests"], ROOT / "ai" / name)
        for name in SUITES
    ]
    commands += [
        ("facet-contracts", [sys.executable, "-m", "facetroutebench.cli", "validate-contracts"], ROOT),
        ("tool-contracts", [sys.executable, "-m", "toolroutebench.cli", "validate-contracts"], ROOT),
        ("model-registry", ["bash", "scripts/prepare-runtime-models.sh", "--validate-registry-only"], ROOT),
    ]
    if args.swift:
        commands.append(("swift", ["swift", "test", "--package-path", "ios/EdgeLLM"], ROOT))
    results = []
    for index, (name, command, directory) in enumerate(commands, start=1):
        print(f"[{index}/{len(commands)}] {name}: running", flush=True)
        started = time.monotonic()
        log_path = output / f"{name}.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(command, cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT)
            while True:
                try:
                    code = process.wait(timeout=15)
                    break
                except subprocess.TimeoutExpired:
                    print(f"  {name}: still running ({time.monotonic() - started:.0f}s)", flush=True)
        result = {"suite": name, "exit_code": code, "seconds": round(time.monotonic() - started, 2)}
        results.append(result)
        # Checkpoints report completed suites; reruns execute all checks so stale
        # successes cannot mask changes made after an earlier run.
        (output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"[{index}/{len(commands)}] {name}: {'PASS' if code == 0 else 'FAIL'} ({result['seconds']}s)", flush=True)
        if code:
            print(log_path.read_text()[-12000:], flush=True)
    return int(any(result["exit_code"] for result in results))


if __name__ == "__main__":
    raise SystemExit(main())
