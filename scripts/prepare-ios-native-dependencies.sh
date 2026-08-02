#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="$REPO_ROOT/ios/.artifacts"
DESTINATION="$ARTIFACT_ROOT/CLiteRTLM.xcframework"
PROVENANCE_PATH="$ARTIFACT_ROOT/CLiteRTLM.provenance"
SOURCE_BUILD_REPOSITORY="https://github.com/mornye-minor-gallery/LiteRT-LM.git"
SOURCE_BUILD_REVISION="7285e1fa7b2428c5de3b2af7d51fe8342080657d"
SOURCE_BUILD_BAZEL_DEFINE="LITERT_LM_FST_CONSTRAINTS_DISABLED=1"
RELEASE_TAG="petai-v0.14.0-topk-poc.1"
RELEASE_ARCHIVE_SHA256="9859bd609b22bea30abd6c3596e9e22cfb0f4a0e8697351955aa5169e3331678"
RELEASE_BASE_URL="https://github.com/mornye-minor-gallery/LiteRT-LM/releases/download/${RELEASE_TAG}"
PACKAGE_ARTIFACT_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Artifacts"
PACKAGE_FRAMEWORK_PATH="$PACKAGE_ARTIFACT_ROOT/CLiteRTLM.xcframework"

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
  if ! command -v nm >/dev/null 2>&1; then
    echo "nm is required to validate the staged LiteRT-LM source build." >&2
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
    if ! nm -gU "${binary_path}" |
       grep -F "_litert_lm_session_config_set_top_k_telemetry" >/dev/null; then
      return 1
    fi
  done
}

link_package_framework() {
  mkdir -p "$PACKAGE_ARTIFACT_ROOT"
  ln -sfn "../../../.artifacts/CLiteRTLM.xcframework" \
    "$PACKAGE_FRAMEWORK_PATH"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

download_pinned_release() (
  set -euo pipefail

  local stage_root
  local archive_path
  local downloaded_provenance
  local extract_root
  local extracted_framework
  local actual_sha256

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to download the pinned LiteRT-LM release." >&2
    exit 1
  }
  command -v unzip >/dev/null 2>&1 || {
    echo "unzip is required to extract the pinned LiteRT-LM release." >&2
    exit 1
  }

  mkdir -p "${ARTIFACT_ROOT}"
  stage_root="$(mktemp -d "${ARTIFACT_ROOT}/.litertlm-release.XXXXXX")"
  trap 'rm -rf "${stage_root}"' EXIT
  archive_path="${stage_root}/CLiteRTLM.xcframework.zip"
  downloaded_provenance="${stage_root}/CLiteRTLM.provenance"
  extract_root="${stage_root}/extracted"

  echo "Downloading pinned LiteRT-LM release ${RELEASE_TAG}..."
  curl --fail --location --retry 3 \
    --output "${archive_path}" \
    "${RELEASE_BASE_URL}/CLiteRTLM.xcframework.zip"
  curl --fail --location --retry 3 \
    --output "${downloaded_provenance}" \
    "${RELEASE_BASE_URL}/CLiteRTLM.provenance"

  actual_sha256="$(sha256 "${archive_path}")"
  if [[ "${actual_sha256}" != "${RELEASE_ARCHIVE_SHA256}" ]]; then
    echo "Pinned LiteRT-LM release checksum mismatch." >&2
    echo "Expected: ${RELEASE_ARCHIVE_SHA256}" >&2
    echo "Actual:   ${actual_sha256}" >&2
    exit 1
  fi
  if ! grep -Fqx \
      "SOURCE_REVISION=${SOURCE_BUILD_REVISION}" \
      "${downloaded_provenance}" ||
     ! grep -Fqx \
      "ARCHIVE_SHA256=${RELEASE_ARCHIVE_SHA256}" \
      "${downloaded_provenance}"; then
    echo "Pinned LiteRT-LM release provenance is invalid." >&2
    exit 1
  fi

  mkdir -p "${extract_root}"
  unzip -q "${archive_path}" -d "${extract_root}"
  extracted_framework="$(
    find "${extract_root}" \
      -type d \
      -name CLiteRTLM.xcframework \
      -print \
      -quit
  )"
  if [[ -z "${extracted_framework}" ]] ||
     ! validate_framework "${extracted_framework}"; then
    echo "Pinned LiteRT-LM release does not contain the expected XCFramework." >&2
    exit 1
  fi

  rm -rf "${DESTINATION}"
  mv "${extracted_framework}" "${DESTINATION}"
  mv "${downloaded_provenance}" "${PROVENANCE_PATH}"
)

if [[ ! -f "${PROVENANCE_PATH}" ]] ||
   [[ "$(provenance_value DISTRIBUTION)" != "source-build" ]] ||
   [[ "$(provenance_value SOURCE_REVISION)" != "${SOURCE_BUILD_REVISION}" ]] ||
   [[ "$(provenance_value ARCHIVE_SHA256)" != "${RELEASE_ARCHIVE_SHA256}" ]] ||
   ! validate_framework "${DESTINATION}"; then
  download_pinned_release
fi

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

  echo "Using the staged PetAI LiteRT-LM organization-fork build:"
  echo "  ${DESTINATION}"
  echo "  Revision: ${actual_revision}"
  echo "  Bazel define: ${actual_bazel_define}"
  link_package_framework
  exit 0
fi

echo "No verified telemetry-enabled organization-fork release is staged." >&2
echo "Check the pinned release tag and SHA-256 in this script." >&2
echo "The official v0.14.0 binary is intentionally not used because its C ABI" >&2
echo "does not contain PetAI's Top-K telemetry entry point." >&2
exit 1
