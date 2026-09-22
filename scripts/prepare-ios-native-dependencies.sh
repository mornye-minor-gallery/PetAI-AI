#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
DESTINATION="${ARTIFACT_ROOT}/CLiteRTLM.xcframework"
PROVENANCE_PATH="${ARTIFACT_ROOT}/CLiteRTLM.provenance"
PACKAGE_ARTIFACT_ROOT="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Artifacts"
PACKAGE_FRAMEWORK_PATH="${PACKAGE_ARTIFACT_ROOT}/CLiteRTLM.xcframework"

SOURCE_REPOSITORY="https://github.com/google-ai-edge/LiteRT-LM.git"
RELEASE_TAG="v0.17.1"
RELEASE_ARCHIVE_SHA256="c94fc12aa0403cb47208e419cc3bfe258214ea17035f7a63c16de536869f2186"
RELEASE_URL="https://github.com/google-ai-edge/LiteRT-LM/releases/download/${RELEASE_TAG}/CLiteRTLM.xcframework.zip"

if [[ "${1:-}" == "--print-config" ]]; then
  cat <<CONFIG
source_repository=${SOURCE_REPOSITORY}
release_tag=${RELEASE_TAG}
release_url=${RELEASE_URL}
archive_sha256=${RELEASE_ARCHIVE_SHA256}
framework=${DESTINATION}
CONFIG
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--print-config]" >&2
  exit 2
fi

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

provenance_value() {
  local key="$1"
  [[ -f "${PROVENANCE_PATH}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    "${PROVENANCE_PATH}"
}

validate_framework() {
  local framework_path="$1"
  local slice
  local binary

  [[ -f "${framework_path}/Info.plist" ]] || return 1
  for slice in ios-arm64 ios-arm64-simulator; do
    binary="${framework_path}/${slice}/CLiteRTLM.framework/CLiteRTLM"
    [[ -f "${binary}" ]] || return 1
    [[ -f "${framework_path}/${slice}/CLiteRTLM.framework/Headers/engine.h" ]] || return 1
    [[ -f "${framework_path}/${slice}/CLiteRTLM.framework/Headers/conversation.h" ]] || return 1
  done
}

link_package_framework() {
  mkdir -p "${PACKAGE_ARTIFACT_ROOT}"
  ln -sfn "../../../.artifacts/CLiteRTLM.xcframework" \
    "${PACKAGE_FRAMEWORK_PATH}"
}

install_official_release() (
  set -euo pipefail

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to download LiteRT-LM." >&2
    exit 1
  }
  command -v unzip >/dev/null 2>&1 || {
    echo "unzip is required to extract LiteRT-LM." >&2
    exit 1
  }

  local stage_root
  local archive_path
  local extract_root
  local extracted_framework
  local actual_sha256

  mkdir -p "${ARTIFACT_ROOT}"
  stage_root="$(mktemp -d "${ARTIFACT_ROOT}/.litertlm-release.XXXXXX")"
  trap 'rm -rf "${stage_root}"' EXIT
  archive_path="${stage_root}/CLiteRTLM.xcframework.zip"
  extract_root="${stage_root}/extracted"

  echo "Downloading official LiteRT-LM ${RELEASE_TAG}..."
  curl --fail --location --retry 3 \
    --output "${archive_path}" \
    "${RELEASE_URL}"

  actual_sha256="$(sha256 "${archive_path}")"
  if [[ "${actual_sha256}" != "${RELEASE_ARCHIVE_SHA256}" ]]; then
    echo "LiteRT-LM release checksum mismatch." >&2
    echo "Expected: ${RELEASE_ARCHIVE_SHA256}" >&2
    echo "Actual:   ${actual_sha256}" >&2
    exit 1
  fi

  mkdir -p "${extract_root}"
  unzip -q "${archive_path}" -d "${extract_root}"
  extracted_framework="${extract_root}/CLiteRTLM.xcframework"
  if ! validate_framework "${extracted_framework}"; then
    echo "The LiteRT-LM archive does not contain the expected iOS framework." >&2
    exit 1
  fi

  rm -rf "${DESTINATION}"
  mv "${extracted_framework}" "${DESTINATION}"
  cat >"${PROVENANCE_PATH}" <<PROVENANCE
DISTRIBUTION=official-release
SOURCE_REPOSITORY=${SOURCE_REPOSITORY}
RELEASE_TAG=${RELEASE_TAG}
ARCHIVE_SHA256=${RELEASE_ARCHIVE_SHA256}
PROVENANCE
)

if [[ "$(provenance_value DISTRIBUTION || true)" != "official-release" ]] ||
   [[ "$(provenance_value SOURCE_REPOSITORY || true)" != "${SOURCE_REPOSITORY}" ]] ||
   [[ "$(provenance_value RELEASE_TAG || true)" != "${RELEASE_TAG}" ]] ||
   [[ "$(provenance_value ARCHIVE_SHA256 || true)" != "${RELEASE_ARCHIVE_SHA256}" ]] ||
   ! validate_framework "${DESTINATION}"; then
  install_official_release
fi

link_package_framework
echo "Using official LiteRT-LM ${RELEASE_TAG}:"
echo "  ${DESTINATION}"
