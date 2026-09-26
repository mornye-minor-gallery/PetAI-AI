#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
REVISION=939b09f5ac92974bb4a7df430d440c2b8780941e
SOURCE_SHA=7efcec573b837a882b313ae115b12cac4b6ed6a9d20673d1a91d44ddbaeede1a
FRAMEWORK="${ARTIFACT_ROOT}/CLiteRTLM.xcframework"
PROVENANCE="${ARTIFACT_ROOT}/CLiteRTLM.provenance"
SOURCE_ROOT="${PETAI_LITERTLM_SOURCE_DIR:-${ARTIFACT_ROOT}/sources/${REVISION}}"
BAZEL="${PETAI_LITERTLM_BAZEL:-${ARTIFACT_ROOT}/tools/bazel-7.6.1}"
CONFIG="source_repository=https://github.com/mornye-minor-gallery/LiteRT-LM.git
source_revision=${REVISION}
source_sha256=${SOURCE_SHA}
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
    "https://api.github.com/repos/mornye-minor-gallery/LiteRT-LM/tarball/${REVISION}" -o "$stage/source.tar.gz"
  [[ "$(shasum -a 256 "$stage/source.tar.gz" | awk '{print $1}')" == "$SOURCE_SHA" ]] || { echo "Source checksum mismatch" >&2; exit 1; }
  mkdir "$SOURCE_ROOT"
  tar -xzf "$stage/source.tar.gz" -C "$SOURCE_ROOT" --strip-components=1
  printf '%s\n' "$CONFIG" > "$SOURCE_ROOT/.petai-checkpoint-source"
fi
# Explicit local reuse is permitted only for a source tree prepared from this pin.
[[ -f "$SOURCE_ROOT/.petai-checkpoint-source" ]] &&
  [[ "$(cat "$SOURCE_ROOT/.petai-checkpoint-source")" == "$CONFIG" ]] || {
  echo "Source provenance does not match; use a new build directory." >&2; exit 1;
}
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
