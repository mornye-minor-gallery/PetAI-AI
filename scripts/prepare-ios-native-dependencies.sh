#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
REVISION=939b09f5ac92974bb4a7df430d440c2b8780941e
SOURCE_SHA=7efcec573b837a882b313ae115b12cac4b6ed6a9d20673d1a91d44ddbaeede1a
FRAMEWORK="${ARTIFACT_ROOT}/CLiteRTLM.xcframework"
PROVENANCE="${ARTIFACT_ROOT}/CLiteRTLM.provenance"
PREFILL_PATCH_SHA=e3e058b0e74936d854bb8b4ec8cbc1c60c419fe8a932992e799e45cf6c3522b9
PREFILL_PATCH="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Patches/cpu-prefill-chunk.patch"
SOURCE_ROOT="${PETAI_LITERTLM_SOURCE_DIR:-${ARTIFACT_ROOT}/sources/${REVISION}-prefill-${PREFILL_PATCH_SHA:0:12}}"
BAZEL="${PETAI_LITERTLM_BAZEL:-${ARTIFACT_ROOT}/tools/bazel-7.6.1}"
SOURCE_CONFIG="source_repository=https://github.com/mornye-minor-gallery/LiteRT-LM.git
source_revision=${REVISION}
source_sha256=${SOURCE_SHA}
bazel_target=//swift:CLiteRTLM
bazel_define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1"
XNNPACK_REVISION=8388bd78690515166d59f1b28e593a455a41d580
XNNPACK_SOURCE_SHA=6ebde53e2dc0af6d16e3e2f46f6e9428a76f4356c2e177c5f558c0b4c5cf9e83
XNNPACK_PATCH_SHA=83c89a3289688a478d7ab2ac594e39f82d7ad355436aec03274c7b718e88833c
XNNPACK_UNARY_SHA=0bb58da3c47f2f3ecae5e605d2cdbae1c7cdac24732edf4af9f75104f96369e9
XNNPACK_PATCH="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Patches/xnnpack-channelwise-scale.patch"
XNNPACK_ROOT="${ARTIFACT_ROOT}/sources/XNNPACK-${XNNPACK_REVISION}-${XNNPACK_PATCH_SHA:0:12}"
XNNPACK_CONFIG="xnnpack_revision=${XNNPACK_REVISION}
xnnpack_source_sha256=${XNNPACK_SOURCE_SHA}
xnnpack_backport=c72e2a4ae0efb7c648f73835e9a0133e7bf21a23
xnnpack_patch_sha256=${XNNPACK_PATCH_SHA}
xnnpack_unary_sha256=${XNNPACK_UNARY_SHA}"
# The archive identity stays fixed; the framework also depends on the XNNPACK
# backport. An older framework must never satisfy this build's reuse check.
CONFIG="${SOURCE_CONFIG}
${XNNPACK_CONFIG}
cpu_prefill_patch_sha256=${PREFILL_PATCH_SHA}"
[[ -f "$PREFILL_PATCH" ]] &&
  [[ "$(shasum -a 256 "$PREFILL_PATCH" | awk '{print $1}')" == "$PREFILL_PATCH_SHA" ]] || {
  echo "CPU prefill patch checksum mismatch" >&2; exit 1;
}
[[ -f "$XNNPACK_PATCH" ]] &&
  [[ "$(shasum -a 256 "$XNNPACK_PATCH" | awk '{print $1}')" == "$XNNPACK_PATCH_SHA" ]] || {
  echo "XNNPACK patch checksum mismatch" >&2; exit 1;
}
CURSOR_CONFIG="$(python3 "$REPO_ROOT/scripts/litertlm_prefix_cursor.py" --identity)"
CONFIG="${CONFIG}
${CURSOR_CONFIG}"
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
    nm -gU "$binary" | grep -F _litert_lm_engine_settings_set_prefill_chunk_size >/dev/null || return 1
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
mkdir -p "$ARTIFACT_ROOT" "$(dirname "$SOURCE_ROOT")" "$(dirname "$XNNPACK_ROOT")" "$(dirname "$BAZEL")"
if [[ ! -d "$SOURCE_ROOT" ]]; then
  stage="$(mktemp -d "${ARTIFACT_ROOT}/litert-source.XXXXXX")"
  curl --fail --location --retry 2 \
    "https://api.github.com/repos/mornye-minor-gallery/LiteRT-LM/tarball/${REVISION}" -o "$stage/source.tar.gz"
  [[ "$(shasum -a 256 "$stage/source.tar.gz" | awk '{print $1}')" == "$SOURCE_SHA" ]] || { echo "Source checksum mismatch" >&2; exit 1; }
  mkdir "$SOURCE_ROOT"
  tar -xzf "$stage/source.tar.gz" -C "$SOURCE_ROOT" --strip-components=1
  printf '%s\n' "$SOURCE_CONFIG" > "$SOURCE_ROOT/.petai-checkpoint-source"
fi
# Explicit local reuse is permitted only for a source tree prepared from this pin.
[[ -f "$SOURCE_ROOT/.petai-checkpoint-source" ]] &&
  [[ "$(cat "$SOURCE_ROOT/.petai-checkpoint-source")" == "$SOURCE_CONFIG" ]] || {
  echo "Source provenance does not match; use a new build directory." >&2; exit 1;
}
if [[ ! -d "$XNNPACK_ROOT" ]]; then
  stage="$(mktemp -d "${ARTIFACT_ROOT}/xnnpack-source.XXXXXX")"
  curl --fail --location --retry 2 \
    "https://storage.googleapis.com/mirror.tensorflow.org/github.com/google/XNNPACK/archive/${XNNPACK_REVISION}.zip" \
    -o "$stage/source.zip"
  [[ "$(shasum -a 256 "$stage/source.zip" | awk '{print $1}')" == "$XNNPACK_SOURCE_SHA" ]] || {
    echo "XNNPACK source checksum mismatch" >&2; exit 1;
  }
  ditto -x -k "$stage/source.zip" "$stage"
  patched="$stage/XNNPACK-${XNNPACK_REVISION}"
  (cd "$patched" && patch -p1 --batch --forward --fuzz=0 -i "$XNNPACK_PATCH")
  [[ "$(shasum -a 256 "$patched/src/subgraph/unary.c" | awk '{print $1}')" == "$XNNPACK_UNARY_SHA" ]] || {
    echo "Patched XNNPACK source checksum mismatch" >&2; exit 1;
  }
  printf '%s\n' "$XNNPACK_CONFIG" > "$patched/.petai-xnnpack-source"
  mv "$patched" "$XNNPACK_ROOT"
fi
[[ -f "$XNNPACK_ROOT/.petai-xnnpack-source" ]] &&
  [[ "$(cat "$XNNPACK_ROOT/.petai-xnnpack-source")" == "$XNNPACK_CONFIG" ]] &&
  [[ "$(shasum -a 256 "$XNNPACK_ROOT/src/subgraph/unary.c" | awk '{print $1}')" == "$XNNPACK_UNARY_SHA" ]] || {
  echo "XNNPACK source provenance does not match; use a new build directory." >&2; exit 1;
}
if [[ ! -f "$SOURCE_ROOT/.petai-prefill-source" ]]; then
  (cd "$SOURCE_ROOT" && patch -p1 --batch --forward --fuzz=0 -i "$PREFILL_PATCH")
  printf '%s\n' "$PREFILL_PATCH_SHA" > "$SOURCE_ROOT/.petai-prefill-source"
fi
[[ "$(cat "$SOURCE_ROOT/.petai-prefill-source")" == "$PREFILL_PATCH_SHA" ]] || {
  echo "CPU prefill source provenance mismatch" >&2; exit 1;
}
# These are the executable selection policy and its Bazel declaration. Checking
# the compiled inputs also rejects a source tree changed by another experiment.
(cd "$SOURCE_ROOT" && shasum -a 256 -c - <<'CPU_PREFILL_SOURCES'
39cda641048d73496a30c519c848cfe860031e02e20ba69e62f54920fdf197a2  runtime/executor/llm_litert_compiled_model_executor.cc
ee6b4f8710d7d1fa574b054ac0b209cad4119483f789f6095fc9d09bc1335d21  runtime/executor/BUILD
c329df678ca84fe12bc8139a0ee7dc3013a3d5efeaec3d95fd37f468ffd81649  runtime/executor/cpu_prefill_chunk.h
CPU_PREFILL_SOURCES
) || { echo "CPU prefill compiled source checksum mismatch" >&2; exit 1; }
python3 "$REPO_ROOT/scripts/litertlm_prefix_cursor.py" --prepare "$SOURCE_ROOT"
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
  --define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1 \
  --override_repository="XNNPACK=${XNNPACK_ROOT}" \
  --jobs="${PETAI_LITERTLM_BUILD_JOBS:-10}" --progress_report_interval=15)
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
