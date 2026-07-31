#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="$REPO_ROOT/ios/.artifacts"
DESTINATION="$ARTIFACT_ROOT/CLiteRTLM.xcframework"
PROVENANCE_PATH="$ARTIFACT_ROOT/CLiteRTLM.provenance"
ARCHIVE_URL="https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM.xcframework.zip"
EXPECTED_SHA256="dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
SOURCE_BUILD_REPOSITORY="https://github.com/mornye-minor-gallery/LiteRT-LM.git"
SOURCE_BUILD_REVISION="80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6"
SOURCE_BUILD_BAZEL_DEFINE="LITERT_LM_FST_CONSTRAINTS_DISABLED=1"
TEMP_ROOT=$(mktemp -d)
ARCHIVE_PATH="$TEMP_ROOT/CLiteRTLM.xcframework.zip"
EXTRACT_ROOT="$TEMP_ROOT/extracted"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

provenance_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    "${PROVENANCE_PATH}"
}

validate_framework() {
  local framework_path="$1"
  [[ -f "${framework_path}/Info.plist" ]] &&
    [[ -d "${framework_path}/ios-arm64" ]] &&
    [[ -d "${framework_path}/ios-arm64-simulator" ]]
}

validate_source_build_runtime_dependencies() {
  local framework_path="$1"
  local binary_path

  if ! command -v otool >/dev/null 2>&1; then
    echo "otool is required to validate the staged LiteRT-LM source build." >&2
    return 1
  fi

  for binary_path in \
    "${framework_path}/ios-arm64/CLiteRTLM.framework/CLiteRTLM" \
    "${framework_path}/ios-arm64-simulator/CLiteRTLM.framework/CLiteRTLM"; do
    if [[ ! -f "${binary_path}" ]] ||
       otool -L "${binary_path}" |
         grep -Fq "@rpath/libGemmaModelConstraintProvider.dylib"; then
      return 1
    fi
  done
}

if [[ -f "${PROVENANCE_PATH}" ]] &&
   [[ "$(provenance_value DISTRIBUTION)" == "source-build" ]]; then
  actual_repository="$(provenance_value SOURCE_REPOSITORY)"
  actual_revision="$(provenance_value SOURCE_REVISION)"
  actual_bazel_define="$(provenance_value BAZEL_DEFINE)"

  if [[ "${actual_repository}" != "${SOURCE_BUILD_REPOSITORY}" ]] ||
     [[ "${actual_revision}" != "${SOURCE_BUILD_REVISION}" ]] ||
     [[ "${actual_bazel_define}" != "${SOURCE_BUILD_BAZEL_DEFINE}" ]]; then
    echo "The staged LiteRT-LM source build has unexpected provenance." >&2
    echo "Run scripts/build-ios-litertlm-from-source.sh again." >&2
    exit 1
  fi

  if ! validate_framework "${DESTINATION}"; then
    echo "The verified LiteRT-LM source build is incomplete: ${DESTINATION}" >&2
    echo "Run scripts/build-ios-litertlm-from-source.sh again." >&2
    exit 1
  fi
  if ! validate_source_build_runtime_dependencies "${DESTINATION}"; then
    echo "The staged LiteRT-LM source build has an unsafe runtime dependency." >&2
    echo "Run scripts/build-ios-litertlm-from-source.sh again." >&2
    exit 1
  fi

  echo "Using the staged unmodified LiteRT-LM organization-fork build:"
  echo "  ${DESTINATION}"
  echo "  Revision: ${actual_revision}"
  echo "  Bazel define: ${actual_bazel_define}"
  exit 0
fi

mkdir -p "$EXTRACT_ROOT" "$ARTIFACT_ROOT"

echo "No verified organization-fork source build is staged."
echo "Downloading the official LiteRT-LM v0.14.0 iOS XCFramework..."
curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$ARCHIVE_URL"

if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')
else
  echo "Neither shasum nor sha256sum is available." >&2
  exit 1
fi

if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Checksum mismatch for CLiteRTLM.xcframework.zip" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

if command -v ditto >/dev/null 2>&1; then
  ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_ROOT"
elif command -v unzip >/dev/null 2>&1; then
  unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_ROOT"
else
  echo "Neither ditto nor unzip is available." >&2
  exit 1
fi

EXTRACTED_FRAMEWORK=$(find "$EXTRACT_ROOT" -type d -name 'CLiteRTLM.xcframework' -print -quit)
if [[ -z "$EXTRACTED_FRAMEWORK" ]] ||
   ! validate_framework "$EXTRACTED_FRAMEWORK"; then
  echo "The verified archive did not contain CLiteRTLM.xcframework." >&2
  exit 1
fi

if [[ -e "$DESTINATION" ]]; then
  rm -rf "$DESTINATION"
fi

if command -v ditto >/dev/null 2>&1; then
  ditto "$EXTRACTED_FRAMEWORK" "$DESTINATION"
else
  cp -R "$EXTRACTED_FRAMEWORK" "$DESTINATION"
fi

cat > "${PROVENANCE_PATH}" <<EOF
DISTRIBUTION=official-release
SOURCE_REPOSITORY=https://github.com/google-ai-edge/LiteRT-LM.git
SOURCE_REF=refs/tags/v0.14.0
ARCHIVE_URL=${ARCHIVE_URL}
ARCHIVE_SHA256=${EXPECTED_SHA256}
EOF

echo "Prepared: $DESTINATION"
