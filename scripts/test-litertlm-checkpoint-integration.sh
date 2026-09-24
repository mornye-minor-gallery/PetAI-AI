#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 PATCHED_NATIVE_SOURCE MODEL_FILE NEW_RESULT_DIRECTORY" >&2; exit 2; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$(cd "$1" && pwd)"
MODEL="$2"
mkdir "$3"
RUN="$(cd "$3" && pwd)"
BAZEL="${PETAI_LITERTLM_BAZEL:-bazel}"
(cd "$NATIVE" && "$BAZEL" build //c:libkvcheckpoint.dylib --define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1 --jobs=10 --progress_report_interval=15)
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
export DYLD_LIBRARY_PATH="$NATIVE/bazel-bin/c:$NATIVE/prebuilt/macos_arm64"
export LLVM_PROFILE_FILE="$RUN/native-%p.profraw"
swift build --package-path "$RUN/package" -c release -Xlinker -L -Xlinker "$NATIVE/bazel-bin/c"
python3 "$REPO_ROOT/scripts/tests/run_checkpoint_integration.py" "$RUN/package/.build/release/Worker" "$MODEL" "$RUN/results"
