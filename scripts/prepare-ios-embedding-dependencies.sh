#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
LITERT_REVISION="1921f3defc8413a3a6bd23ad6a4d5fe35520a2c0"
SENTENCEPIECE_REVISION="31646a467d2051eb904e0b45de3a73e91fe1c1e3"
RELEASE_TAG="petai-ios-embedding-native-v1"
RELEASE_ARCHIVE_SHA256="680231b9a3a40362d284bb0c4a732d6f5111eabcae5a93edfa4f7d9b9c7ff11d"
RELEASE_BASE_URL="https://github.com/mornye-minor-gallery/LiteRT-LM/releases/download/${RELEASE_TAG}"
RELEASE_PROVENANCE_PATH="${ARTIFACT_ROOT}/EmbeddingNative.provenance"
BAZELISK_VERSION="1.29.0"
BAZELISK_SHA256="cee851f726789227d5561004e9904a52be45c3efb56f8b38b6993d6adbaa0409"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command is missing: $1" >&2
    exit 1
  fi
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "Neither shasum nor sha256sum is available." >&2
    exit 1
  fi
}

provenance_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    "${path}"
}

validate_framework() {
  local framework_path="$1"
  [[ -f "${framework_path}/Info.plist" ]] &&
    [[ -d "${framework_path}/ios-arm64" ]] &&
    [[ -d "${framework_path}/ios-arm64-simulator" ]]
}

validate_pinned_release() {
  [[ -f "${RELEASE_PROVENANCE_PATH}" ]] &&
    [[ "$(provenance_value LITERT_REVISION "${RELEASE_PROVENANCE_PATH}")" == "${LITERT_REVISION}" ]] &&
    [[ "$(provenance_value SENTENCEPIECE_REVISION "${RELEASE_PROVENANCE_PATH}")" == "${SENTENCEPIECE_REVISION}" ]] &&
    [[ "$(provenance_value ARCHIVE_SHA256 "${RELEASE_PROVENANCE_PATH}")" == "${RELEASE_ARCHIVE_SHA256}" ]] &&
    validate_framework "${ARTIFACT_ROOT}/CLiteRT.xcframework" &&
    validate_framework "${ARTIFACT_ROOT}/CSentencePiece.xcframework"
}

download_pinned_release() (
  set -euo pipefail

  local stage_root
  local archive_path
  local provenance_path
  local extract_root
  local actual_sha256

  require_command curl
  require_command unzip

  mkdir -p "${ARTIFACT_ROOT}"
  stage_root="$(mktemp -d "${ARTIFACT_ROOT}/.embedding-native-release.XXXXXX")"
  trap 'rm -rf "${stage_root}"' EXIT
  archive_path="${stage_root}/EmbeddingNative.xcframeworks.zip"
  provenance_path="${stage_root}/EmbeddingNative.provenance"
  extract_root="${stage_root}/extracted"

  echo "Downloading pinned iOS embedding native release ${RELEASE_TAG}..."
  curl --fail --location --retry 3 \
    --output "${archive_path}" \
    "${RELEASE_BASE_URL}/EmbeddingNative.xcframeworks.zip"
  curl --fail --location --retry 3 \
    --output "${provenance_path}" \
    "${RELEASE_BASE_URL}/EmbeddingNative.provenance"

  actual_sha256="$(sha256 "${archive_path}")"
  if [[ "${actual_sha256}" != "${RELEASE_ARCHIVE_SHA256}" ]]; then
    echo "Pinned iOS embedding native release checksum mismatch." >&2
    echo "Expected: ${RELEASE_ARCHIVE_SHA256}" >&2
    echo "Actual:   ${actual_sha256}" >&2
    exit 1
  fi

  for expected_line in \
    "LITERT_REVISION=${LITERT_REVISION}" \
    "SENTENCEPIECE_REVISION=${SENTENCEPIECE_REVISION}" \
    "ARCHIVE_SHA256=${RELEASE_ARCHIVE_SHA256}"; do
    if ! grep -Fqx "${expected_line}" "${provenance_path}"; then
      echo "Pinned iOS embedding native provenance is invalid: ${expected_line}" >&2
      exit 1
    fi
  done

  mkdir -p "${extract_root}"
  unzip -q "${archive_path}" -d "${extract_root}"
  for framework_name in CLiteRT.xcframework CSentencePiece.xcframework; do
    if ! validate_framework "${extract_root}/${framework_name}"; then
      echo "Pinned release is missing a valid ${framework_name}." >&2
      exit 1
    fi
  done

  rm -rf \
    "${ARTIFACT_ROOT}/CLiteRT.xcframework" \
    "${ARTIFACT_ROOT}/CSentencePiece.xcframework"
  mv "${extract_root}/CLiteRT.xcframework" "${ARTIFACT_ROOT}/"
  mv "${extract_root}/CSentencePiece.xcframework" "${ARTIFACT_ROOT}/"
  mv "${provenance_path}" "${RELEASE_PROVENANCE_PATH}"
)

clone_revision() {
  local repository_url="$1"
  local revision="$2"
  local destination="$3"

  git init -q "${destination}"
  git -C "${destination}" remote add origin "${repository_url}"
  git -C "${destination}" fetch -q --depth 1 origin "${revision}"
  git -C "${destination}" checkout -q --detach FETCH_HEAD

  local actual_revision
  actual_revision="$(git -C "${destination}" rev-parse HEAD)"
  if [[ "${actual_revision}" != "${revision}" ]]; then
    echo "Revision mismatch for ${repository_url}" >&2
    echo "Expected: ${revision}" >&2
    echo "Actual:   ${actual_revision}" >&2
    exit 1
  fi
}

resolve_bazel() {
  if command -v bazelisk >/dev/null 2>&1; then
    command -v bazelisk
    return
  fi
  if command -v bazel >/dev/null 2>&1; then
    command -v bazel
    return
  fi

  local bazelisk_path="${TEMP_ROOT}/bazelisk"
  local bazelisk_url
  bazelisk_url="https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-darwin-arm64"

  echo "Downloading Bazelisk ${BAZELISK_VERSION}..." >&2
  curl --fail --location --retry 3 \
    --output "${bazelisk_path}" \
    "${bazelisk_url}"

  local actual_sha256
  actual_sha256="$(sha256 "${bazelisk_path}")"
  if [[ "${actual_sha256}" != "${BAZELISK_SHA256}" ]]; then
    echo "Checksum mismatch for Bazelisk." >&2
    echo "Expected: ${BAZELISK_SHA256}" >&2
    echo "Actual:   ${actual_sha256}" >&2
    exit 1
  fi

  chmod +x "${bazelisk_path}"
  echo "${bazelisk_path}"
}

build_sentencepiece_slice() {
  local source_root="$1"
  local platform="$2"
  local build_root="$3"
  local install_root="$4"

  cmake \
    -S "${source_root}" \
    -B "${build_root}" \
    -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="${source_root}/cmake/ios.toolchain.cmake" \
    -DPLATFORM="${platform}" \
    -DDEPLOYMENT_TARGET=15.0 \
    -DCMAKE_INSTALL_PREFIX="${install_root}" \
    -DSPM_ENABLE_SHARED=OFF \
    -DSPM_ENABLE_TCMALLOC=OFF \
    -DSPM_BUILD_TEST=OFF

  cmake --build "${build_root}" \
    --config Release \
    --target install \
    --parallel
}

mkdir -p "${ARTIFACT_ROOT}"

if [[ "${1:-}" != "--build-from-source" ]]; then
  if ! validate_pinned_release; then
    download_pinned_release
  fi
  if ! validate_pinned_release; then
    echo "Pinned iOS embedding native release validation failed." >&2
    exit 1
  fi

  echo "Using pinned iOS embedding native release ${RELEASE_TAG}:"
  echo "  ${ARTIFACT_ROOT}/CLiteRT.xcframework"
  echo "  ${ARTIFACT_ROOT}/CSentencePiece.xcframework"
  exit 0
fi

# A local source build is not the pinned release, even when it uses the same
# revisions. Remove the release proof so a later default invocation cannot
# mistake unverified local output for the published archive.
rm -f "${RELEASE_PROVENANCE_PATH}"

require_command cmake
require_command curl
require_command git
require_command xcodebuild

LITERT_ROOT="${TEMP_ROOT}/LiteRT"
echo "Fetching LiteRT ${LITERT_REVISION}..."
clone_revision \
  "https://github.com/google-ai-edge/LiteRT.git" \
  "${LITERT_REVISION}" \
  "${LITERT_ROOT}"

BAZEL_BIN="$(resolve_bazel)"
echo "Building the official CPU-capable CLiteRT XCFramework..."
(
  cd "${LITERT_ROOT}"
  "${BAZEL_BIN}" build -c opt //litert/swift:CLiteRT
)

cp \
  "${LITERT_ROOT}/bazel-bin/litert/swift/CLiteRT.xcframework.zip" \
  "${ARTIFACT_ROOT}/CLiteRT.xcframework.zip"

rm -rf "${ARTIFACT_ROOT}/CLiteRT.xcframework"
if command -v ditto >/dev/null 2>&1; then
  ditto -x -k \
    "${ARTIFACT_ROOT}/CLiteRT.xcframework.zip" \
    "${ARTIFACT_ROOT}"
else
  unzip -q \
    "${ARTIFACT_ROOT}/CLiteRT.xcframework.zip" \
    -d "${ARTIFACT_ROOT}"
fi

SENTENCEPIECE_ROOT="${TEMP_ROOT}/sentencepiece"
echo "Fetching SentencePiece ${SENTENCEPIECE_REVISION}..."
clone_revision \
  "https://github.com/google/sentencepiece.git" \
  "${SENTENCEPIECE_REVISION}" \
  "${SENTENCEPIECE_ROOT}"

build_sentencepiece_slice \
  "${SENTENCEPIECE_ROOT}" \
  "OS64" \
  "${TEMP_ROOT}/sentencepiece-device" \
  "${TEMP_ROOT}/sentencepiece-install-device"
build_sentencepiece_slice \
  "${SENTENCEPIECE_ROOT}" \
  "SIMULATORARM64" \
  "${TEMP_ROOT}/sentencepiece-simulator" \
  "${TEMP_ROOT}/sentencepiece-install-simulator"

HEADER_ROOT="${TEMP_ROOT}/sentencepiece-headers"
mkdir -p "${HEADER_ROOT}"
cp \
  "${TEMP_ROOT}/sentencepiece-install-device/include/sentencepiece_processor.h" \
  "${HEADER_ROOT}/sentencepiece_processor.h"

cat > "${HEADER_ROOT}/CSentencePiece.h" <<'EOF'
#include "sentencepiece_processor.h"
EOF

cat > "${HEADER_ROOT}/module.modulemap" <<'EOF'
module CSentencePiece {
  umbrella header "CSentencePiece.h"
  export *
  module * { export * }
}
EOF

rm -rf "${ARTIFACT_ROOT}/CSentencePiece.xcframework"
xcodebuild -create-xcframework \
  -library \
  "${TEMP_ROOT}/sentencepiece-install-device/lib/libsentencepiece.a" \
  -headers "${HEADER_ROOT}" \
  -library \
  "${TEMP_ROOT}/sentencepiece-install-simulator/lib/libsentencepiece.a" \
  -headers "${HEADER_ROOT}" \
  -output "${ARTIFACT_ROOT}/CSentencePiece.xcframework"

echo "Prepared:"
echo "  ${ARTIFACT_ROOT}/CLiteRT.xcframework.zip"
echo "  ${ARTIFACT_ROOT}/CLiteRT.xcframework"
echo "  ${ARTIFACT_ROOT}/CSentencePiece.xcframework"
