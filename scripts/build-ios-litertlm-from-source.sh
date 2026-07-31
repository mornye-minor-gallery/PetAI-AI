#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="${REPO_ROOT}/ios/.artifacts"
SOURCE_ROOT="${PETAI_LITERTLM_SOURCE_DIR:-${ARTIFACT_ROOT}/sources/LiteRT-LM}"
SOURCE_REPOSITORY="https://github.com/mornye-minor-gallery/LiteRT-LM.git"
SOURCE_REF="refs/heads/feature/topk-telemetry-poc"
SOURCE_REVISION="7285e1fa7b2428c5de3b2af7d51fe8342080657d"
BAZEL_TARGET="//swift:CLiteRTLM"
BAZEL_DEFINE="LITERT_LM_FST_CONSTRAINTS_DISABLED=1"
BAZELISK_VERSION="1.29.0"
BAZELISK_SHA256="cee851f726789227d5561004e9904a52be45c3efb56f8b38b6993d6adbaa0409"
ARCHIVE_PATH="${ARTIFACT_ROOT}/CLiteRTLM.xcframework.zip"
FRAMEWORK_PATH="${ARTIFACT_ROOT}/CLiteRTLM.xcframework"
PROVENANCE_PATH="${ARTIFACT_ROOT}/CLiteRTLM.provenance"
PACKAGE_ARTIFACT_ROOT="${REPO_ROOT}/ios/ThirdParty/LiteRTLM/Artifacts"
PACKAGE_FRAMEWORK_PATH="${PACKAGE_ARTIFACT_ROOT}/CLiteRTLM.xcframework"

print_config() {
  cat <<EOF
source_repository=${SOURCE_REPOSITORY}
source_ref=${SOURCE_REF}
source_revision=${SOURCE_REVISION}
bazel_target=${BAZEL_TARGET}
bazel_define=${BAZEL_DEFINE}
source_dir=${SOURCE_ROOT}
archive=${ARCHIVE_PATH}
framework=${FRAMEWORK_PATH}
provenance=${PROVENANCE_PATH}
EOF
}

if [[ "${1:-}" == "--print-config" ]]; then
  print_config
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--print-config]" >&2
  exit 2
fi

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

resolve_bazel() {
  if [[ -n "${PETAI_LITERTLM_BAZEL:-}" ]]; then
    if [[ ! -x "${PETAI_LITERTLM_BAZEL}" ]]; then
      echo "PETAI_LITERTLM_BAZEL is not executable: ${PETAI_LITERTLM_BAZEL}" >&2
      exit 1
    fi
    echo "${PETAI_LITERTLM_BAZEL}"
    return
  fi

  if command -v bazelisk >/dev/null 2>&1; then
    command -v bazelisk
    return
  fi
  if command -v bazel >/dev/null 2>&1; then
    command -v bazel
    return
  fi

  local bazelisk_path="${ARTIFACT_ROOT}/tools/bazelisk-${BAZELISK_VERSION}"
  local bazelisk_url
  bazelisk_url="https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-darwin-arm64"

  mkdir -p "$(dirname "${bazelisk_path}")"
  if [[ ! -f "${bazelisk_path}" ]]; then
    echo "Downloading Bazelisk ${BAZELISK_VERSION}..." >&2
    curl --fail --location --retry 3 \
      --output "${bazelisk_path}" \
      "${bazelisk_url}"
  fi

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

prepare_source_checkout() {
  mkdir -p "$(dirname "${SOURCE_ROOT}")"

  if [[ ! -d "${SOURCE_ROOT}/.git" ]]; then
    if [[ -e "${SOURCE_ROOT}" ]] &&
       [[ -n "$(find "${SOURCE_ROOT}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      echo "Source directory exists but is not a Git checkout: ${SOURCE_ROOT}" >&2
      exit 1
    fi

    mkdir -p "${SOURCE_ROOT}"
    git -C "${SOURCE_ROOT}" init -q
    git -C "${SOURCE_ROOT}" remote add origin "${SOURCE_REPOSITORY}"
  fi

  local actual_remote
  actual_remote="$(git -C "${SOURCE_ROOT}" remote get-url origin)"
  if [[ "${actual_remote}" != "${SOURCE_REPOSITORY}" ]]; then
    echo "Unexpected LiteRT-LM origin." >&2
    echo "Expected: ${SOURCE_REPOSITORY}" >&2
    echo "Actual:   ${actual_remote}" >&2
    exit 1
  fi

  if ! git -C "${SOURCE_ROOT}" diff --quiet ||
     ! git -C "${SOURCE_ROOT}" diff --cached --quiet; then
    echo "LiteRT-LM source checkout has tracked changes: ${SOURCE_ROOT}" >&2
    echo "Commit or discard them before rebuilding the pinned fork." >&2
    exit 1
  fi

  echo "Fetching the pinned LiteRT-LM organization-fork revision..."
  GIT_LFS_SKIP_SMUDGE=1 \
    git -C "${SOURCE_ROOT}" fetch --force --depth 1 origin "${SOURCE_REF}"
  GIT_LFS_SKIP_SMUDGE=1 \
    git -C "${SOURCE_ROOT}" checkout -q --detach FETCH_HEAD

  local actual_revision
  actual_revision="$(git -C "${SOURCE_ROOT}" rev-parse HEAD)"
  if [[ "${actual_revision}" != "${SOURCE_REVISION}" ]]; then
    echo "LiteRT-LM revision mismatch." >&2
    echo "Expected: ${SOURCE_REVISION}" >&2
    echo "Actual:   ${actual_revision}" >&2
    exit 1
  fi

  git -C "${SOURCE_ROOT}" lfs install --local >/dev/null
  git -C "${SOURCE_ROOT}" lfs pull origin \
    --include="prebuilt/ios_arm64/*,prebuilt/ios_sim_arm64/*" \
    --exclude=""

  local pointer_file
  pointer_file="$(
    grep -IlR \
      '^version https://git-lfs.github.com/spec/v1$' \
      "${SOURCE_ROOT}/prebuilt/ios_arm64" \
      "${SOURCE_ROOT}/prebuilt/ios_sim_arm64" |
      head -n 1 ||
      true
  )"
  if [[ -n "${pointer_file}" ]]; then
    echo "Required iOS Git LFS object was not downloaded: ${pointer_file}" >&2
    exit 1
  fi
}

extract_and_validate_archive() {
  local built_archive="$1"
  local stage_root="$2"
  local extract_root="${stage_root}/extracted"
  local extracted_framework

  mkdir -p "${extract_root}"
  if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "${built_archive}" "${extract_root}"
  else
    unzip -q "${built_archive}" -d "${extract_root}"
  fi

  extracted_framework="$(
    find "${extract_root}" \
      -type d \
      -name 'CLiteRTLM.xcframework' \
      -print \
      -quit
  )"
  if [[ -z "${extracted_framework}" ]] ||
     [[ ! -f "${extracted_framework}/Info.plist" ]] ||
     [[ ! -d "${extracted_framework}/ios-arm64" ]] ||
     [[ ! -d "${extracted_framework}/ios-arm64-simulator" ]]; then
    echo "Built archive does not contain the expected iOS device and simulator XCFramework slices." >&2
    exit 1
  fi

  mv "${extracted_framework}" "${stage_root}/CLiteRTLM.xcframework"
}

validate_runtime_dependencies() {
  local framework_path="$1"
  local binary_path

  for binary_path in \
    "${framework_path}/ios-arm64/CLiteRTLM.framework/CLiteRTLM" \
    "${framework_path}/ios-arm64-simulator/CLiteRTLM.framework/CLiteRTLM"; do
    if [[ ! -f "${binary_path}" ]]; then
      echo "Built XCFramework is missing its expected binary: ${binary_path}" >&2
      exit 1
    fi
    if otool -L "${binary_path}" |
       grep -Fq "@rpath/libGemmaModelConstraintProvider.dylib"; then
      echo "Built XCFramework retains an unbundled runtime dependency:" >&2
      echo "  @rpath/libGemmaModelConstraintProvider.dylib" >&2
      echo "The PetAI source-build profile must disable FST constraints." >&2
      exit 1
    fi
    if ! nm -gU "${binary_path}" |
       grep -F "_litert_lm_session_config_set_top_k_telemetry" >/dev/null; then
      echo "Built XCFramework is missing the PetAI Top-K telemetry ABI:" >&2
      echo "  _litert_lm_session_config_set_top_k_telemetry" >&2
      echo "Pin and build the compatible organization-fork revision." >&2
      exit 1
    fi
  done
}

link_package_framework() {
  mkdir -p "${PACKAGE_ARTIFACT_ROOT}"
  ln -sfn "../../../.artifacts/CLiteRTLM.xcframework" \
    "${PACKAGE_FRAMEWORK_PATH}"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The LiteRT-LM iOS XCFramework must be built on macOS." >&2
  exit 1
fi

require_command curl
require_command git
require_command grep
require_command nm
require_command otool
require_command xcodebuild
git lfs version >/dev/null

mkdir -p "${ARTIFACT_ROOT}"
prepare_source_checkout
BAZEL_BIN="$(resolve_bazel)"

echo "Building ${BAZEL_TARGET} from the pinned PetAI organization fork..."
(
  cd "${SOURCE_ROOT}"
  "${BAZEL_BIN}" build \
    --disk_cache="${ARTIFACT_ROOT}/bazel-disk-cache" \
    --define="${BAZEL_DEFINE}" \
    "${BAZEL_TARGET}"
)

BUILT_ARCHIVE="${SOURCE_ROOT}/bazel-bin/swift/CLiteRTLM.xcframework.zip"
if [[ ! -f "${BUILT_ARCHIVE}" ]]; then
  echo "Bazel completed without the expected archive: ${BUILT_ARCHIVE}" >&2
  exit 1
fi

STAGE_ROOT="$(mktemp -d "${ARTIFACT_ROOT}/.litertlm-stage.XXXXXX")"
cleanup() {
  rm -rf "${STAGE_ROOT}"
}
trap cleanup EXIT

cp "${BUILT_ARCHIVE}" "${STAGE_ROOT}/CLiteRTLM.xcframework.zip"
extract_and_validate_archive \
  "${STAGE_ROOT}/CLiteRTLM.xcframework.zip" \
  "${STAGE_ROOT}"
validate_runtime_dependencies \
  "${STAGE_ROOT}/CLiteRTLM.xcframework"

ARCHIVE_SHA256="$(sha256 "${STAGE_ROOT}/CLiteRTLM.xcframework.zip")"
cat > "${STAGE_ROOT}/CLiteRTLM.provenance" <<EOF
DISTRIBUTION=source-build
SOURCE_REPOSITORY=${SOURCE_REPOSITORY}
SOURCE_REF=${SOURCE_REF}
SOURCE_REVISION=${SOURCE_REVISION}
BAZEL_TARGET=${BAZEL_TARGET}
BAZEL_DEFINE=${BAZEL_DEFINE}
ARCHIVE_SHA256=${ARCHIVE_SHA256}
EOF

rm -rf "${FRAMEWORK_PATH}"
mv "${STAGE_ROOT}/CLiteRTLM.xcframework" "${FRAMEWORK_PATH}"
if [[ -e "${ARCHIVE_PATH}" ]]; then
  chmod u+w "${ARCHIVE_PATH}"
fi
mv -f "${STAGE_ROOT}/CLiteRTLM.xcframework.zip" "${ARCHIVE_PATH}"
mv -f "${STAGE_ROOT}/CLiteRTLM.provenance" "${PROVENANCE_PATH}"
link_package_framework

echo "Prepared PetAI organization-fork build:"
echo "  ${FRAMEWORK_PATH}"
echo "  SHA-256: ${ARCHIVE_SHA256}"
echo "  Provenance: ${PROVENANCE_PATH}"
echo "Unity iOS export will use this framework without changing its existing post-processor."
