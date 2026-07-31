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

echo "No verified telemetry-enabled organization-fork build is staged." >&2
echo "Run scripts/build-ios-litertlm-from-source.sh first." >&2
echo "The official v0.14.0 binary is intentionally not used because its C ABI" >&2
echo "does not contain PetAI's Top-K telemetry entry point." >&2
exit 1
