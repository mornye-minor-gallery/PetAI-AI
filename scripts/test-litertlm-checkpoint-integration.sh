#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 3 && $# -le 5 ]] || { echo "usage: $0 NATIVE_SOURCE MODEL_FILE NEW_RESULT_DIRECTORY [cpu|gpu] [CONTEXT_TOKENS]" >&2; exit 2; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$1"
MODEL="$2"
BACKEND="${4:-cpu}"
CONTEXT="${5:-8192}"
[[ "$BACKEND" == cpu || "$BACKEND" == gpu ]] || { echo "backend must be cpu or gpu" >&2; exit 2; }
mkdir "$3"
RUN="$(cd "$3" && pwd)"
BAZEL="${PETAI_LITERTLM_BAZEL:-bazel}"
python3 "$REPO_ROOT/scripts/build-mac-checkpoint.py" --source "$NATIVE" \
  --output-base "${PETAI_BAZEL_OUTPUT_BASE:-$RUN/bazel}" --output "$RUN/native" --bazel "$BAZEL"
NATIVE="$(cd "$NATIVE" && pwd)"
mkdir -p "$RUN/package/CLiteRTLM" "$RUN/package/LiteRTLM" "$RUN/package/Worker"
for file in "$REPO_ROOT"/ios/ThirdParty/LiteRTLM/Sources/LiteRTLM/*.swift; do
  ln -s "$file" "$RUN/package/LiteRTLM/"
done
ln -s "$NATIVE/c" "$RUN/package/CLiteRTLM/include"
ln -s "$REPO_ROOT/ios/EdgeLLM" "$RUN/package/EdgeLLM"
ln -s "$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CheckpointIntegration/Fixtures" "$RUN/package/Fixtures"
ln -s "$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CheckpointIntegration/Worker.swift" "$RUN/package/Worker/Worker.swift"
cp "$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CheckpointIntegration/Package.swift" "$RUN/package/"
cp "$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CheckpointIntegration/module.modulemap" "$RUN/package/CLiteRTLM/"
export DYLD_LIBRARY_PATH="$RUN/native"
export LLVM_PROFILE_FILE="$RUN/native-%p.profraw"
swift build --package-path "$RUN/package" -c release --jobs 2 \
  -Xlinker -L -Xlinker "$RUN/native" -Xlinker -rpath -Xlinker "$RUN/native"
python3 "$REPO_ROOT/scripts/tests/run_checkpoint_integration.py" "$RUN/package/.build/release/Worker" "$MODEL" "$RUN/results" \
  --backend "$BACKEND" --context "$CONTEXT"
