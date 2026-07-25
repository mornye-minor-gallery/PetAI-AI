#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
LITERT_REVISION="1921f3defc8413a3a6bd23ad6a4d5fe35520a2c0"
SENTENCEPIECE_REVISION="31646a467d2051eb904e0b45de3a73e91fe1c1e3"
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

require_command cmake
require_command curl
require_command git
require_command xcodebuild

mkdir -p "${ARTIFACT_ROOT}"

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
echo "  ${ARTIFACT_ROOT}/CSentencePiece.xcframework"
