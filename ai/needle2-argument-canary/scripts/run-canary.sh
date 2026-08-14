#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
canary_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$canary_root/../.." && pwd)"
artifact_root="$canary_root/.artifacts"
gemma_model="$repo_root/ai/.artifacts/runtime-models/chat/gemma-e2b-it/gemma-4-E2B-it.litertlm"

mkdir -p "$artifact_root"

if [[ ! -f "$gemma_model" ]]; then
  echo "missing deployment Gemma artifact: $gemma_model" >&2
  exit 1
fi
cd "$repo_root"

uv run --python 3.12 --with litert-lm==0.14.0 \
  python "$script_dir/run_gemma.py" \
  --model "$gemma_model" \
  --output "$artifact_root/gemma.predictions.jsonl" \
  >"$artifact_root/gemma.stdout.log" \
  2>"$artifact_root/gemma.stderr.log"

uv run --python 3.12 --with cactus-needle==2.0.2 \
  python "$script_dir/run_needle.py" \
  --output "$artifact_root/needle.predictions.jsonl" \
  >"$artifact_root/needle.stdout.log" \
  2>"$artifact_root/needle.stderr.log"

python3 - "$artifact_root" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
target = root / "all.predictions.jsonl"
with target.open("wb") as out:
    for name in ("gemma.predictions.jsonl", "needle.predictions.jsonl"):
        out.write((root / name).read_bytes())
PY

swiftc \
  "$repo_root/ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolContracts.swift" \
  "$repo_root/ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolProposalParser.swift" \
  "$repo_root/ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolProposalValidator.swift" \
  "$script_dir/validate_predictions.swift" \
  -o "$artifact_root/validate-predictions"

"$artifact_root/validate-predictions" \
  "$artifact_root/all.predictions.jsonl" \
  "$artifact_root/validations.jsonl"

python3 "$script_dir/score.py" \
  --predictions "$artifact_root/all.predictions.jsonl" \
  --validations "$artifact_root/validations.jsonl" \
  --output "$artifact_root/summary.json"
