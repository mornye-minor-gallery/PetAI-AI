#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
PATCH="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/native/kv-checkpoint.patch"
PREFILL_PATCH="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/native/pending-prefill.patch"
REVISION=a327b494f874a319605e6fd7e3439678daa4d07d
SOURCE_SHA=6f3b0f8a82f594cb14f30ac485ba5c1bfc4255f7422c83fccf7128cf9d5bd70b
PATCH_SHA="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
PREFILL_SHA="$(shasum -a 256 "$PREFILL_PATCH" | awk '{print $1}')"
FRAMEWORK="${ARTIFACT_ROOT}/CLiteRTLM.xcframework"
PROVENANCE="${ARTIFACT_ROOT}/CLiteRTLM.provenance"
SOURCE_ROOT="${PETAI_LITERTLM_SOURCE_DIR:-${ARTIFACT_ROOT}/sources/${REVISION}-${PATCH_SHA}-${PREFILL_SHA}}"
BAZEL="${PETAI_LITERTLM_BAZEL:-${ARTIFACT_ROOT}/tools/bazel-7.6.1}"
CONFIG="source_repository=https://github.com/google-ai-edge/LiteRT-LM.git
source_revision=${REVISION}
source_sha256=${SOURCE_SHA}
patch_sha256=${PATCH_SHA}
prefill_patch_sha256=${PREFILL_SHA}
bazel_target=//swift:CLiteRTLM
bazel_define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1"
if [[ "${1:-}" == --print-config ]]; then echo "$CONFIG"; exit 0; fi
if [[ $# -ne 0 ]]; then echo "Usage: $0 [--print-config]" >&2; exit 2; fi

link_package() {
  mkdir -p "${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Artifacts"
  ln -sfn ../../../.artifacts/CLiteRTLM.xcframework \
    "${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Artifacts/CLiteRTLM.xcframework"
}
validate_framework() {
  local candidate="$1"
  [[ -f "$candidate/Info.plist" ]] || return 1
  for slice in ios-arm64 ios-arm64-simulator; do
    local binary="$candidate/$slice/CLiteRTLM.framework/CLiteRTLM"
    [[ -f "$binary" ]] || return 1
    nm -gU "$binary" | grep -F _litert_lm_session_transfer_state >/dev/null || return 1
    if otool -L "$binary" | grep -F libGemmaModelConstraintProvider >/dev/null; then return 1; fi
  done
}
if [[ -f "$PROVENANCE" ]] && [[ "$(cat "$PROVENANCE")" == "$CONFIG" ]] && validate_framework "$FRAMEWORK"; then
  (cd "$ARTIFACT_ROOT" && shasum -a 256 -c CLiteRTLM.binary-sha256) || exit 1
  link_package
  echo "Using verified KV-checkpoint LiteRT-LM framework."
  exit 0
fi

[[ "$(uname -s)" == Darwin ]] || { echo "Native framework build requires macOS." >&2; exit 1; }
mkdir -p "$ARTIFACT_ROOT" "$(dirname "$SOURCE_ROOT")" "$(dirname "$BAZEL")"
if [[ ! -d "$SOURCE_ROOT" ]]; then
  stage="$(mktemp -d "${ARTIFACT_ROOT}/litert-source.XXXXXX")"
  curl --fail --location --retry 2 \
    "https://api.github.com/repos/google-ai-edge/LiteRT-LM/tarball/${REVISION}" -o "$stage/source.tar.gz"
  [[ "$(shasum -a 256 "$stage/source.tar.gz" | awk '{print $1}')" == "$SOURCE_SHA" ]] || { echo "Source checksum mismatch" >&2; exit 1; }
  mkdir "$SOURCE_ROOT"
  tar -xzf "$stage/source.tar.gz" -C "$SOURCE_ROOT" --strip-components=1
  (cd "$SOURCE_ROOT" && git apply --check "$PATCH" && git apply "$PATCH")
  (cd "$SOURCE_ROOT" && git apply --check "$PREFILL_PATCH" && git apply "$PREFILL_PATCH")
  printf '%s\n' "$CONFIG" > "$SOURCE_ROOT/.petai-checkpoint-source"
fi
# Explicit local reuse is permitted only for a source tree prepared from this pin.
[[ -f "$SOURCE_ROOT/.petai-checkpoint-source" ]] &&
  [[ "$(cat "$SOURCE_ROOT/.petai-checkpoint-source")" == "$CONFIG" ]] || {
  echo "Source provenance does not match; use a new build directory." >&2; exit 1;
}
(cd "$SOURCE_ROOT" && git apply --reverse --check "$PREFILL_PATCH" "$PATCH")
if [[ ! -x "$BAZEL" ]]; then
  curl --fail --location --retry 2 \
    https://github.com/bazelbuild/bazel/releases/download/7.6.1/bazel-7.6.1-darwin-arm64 -o "$BAZEL"
  chmod +x "$BAZEL"
fi
[[ "$(shasum -a 256 "$BAZEL" | awk '{print $1}')" == 45cca81a839d7495258b19ee8371c7b891f350586ef37b9940f7b531eb654cc8 ]] || {
  echo "Bazel checksum mismatch" >&2; exit 1;
}
echo "Building native KV checkpoint API (Bazel reports progress; incremental results are retained)..."
(cd "$SOURCE_ROOT" && "$BAZEL" build //swift:CLiteRTLM \
  --define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1 --jobs=10 --progress_report_interval=15)
stage="$(mktemp -d "${ARTIFACT_ROOT}/litert-framework.XXXXXX")"
ditto -x -k "$SOURCE_ROOT/bazel-bin/swift/CLiteRTLM.xcframework.zip" "$stage"
validate_framework "$stage/CLiteRTLM.xcframework" || {
  echo "Built framework failed ABI/dependency validation" >&2; exit 1;
}
# Retain a prior artifact in this staging directory instead of deleting it.
if [[ -e "$FRAMEWORK" ]]; then mv "$FRAMEWORK" "$stage/previous.xcframework"; fi
mv "$stage/CLiteRTLM.xcframework" "$FRAMEWORK"
printf '%s\n' "$CONFIG" > "$PROVENANCE"
(cd "$ARTIFACT_ROOT" && shasum -a 256 \
  CLiteRTLM.xcframework/ios-arm64/CLiteRTLM.framework/CLiteRTLM \
  CLiteRTLM.xcframework/ios-arm64-simulator/CLiteRTLM.framework/CLiteRTLM > CLiteRTLM.binary-sha256)
link_package
echo "Prepared native KV checkpoint framework."
