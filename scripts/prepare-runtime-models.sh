#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_PATH="${REPO_ROOT}/ai/models/runtime-models.json"
ARTIFACT_ROOT="${REPO_ROOT}/ai/.artifacts/runtime-models"
VERIFY_ONLY=false
VALIDATE_REGISTRY_ONLY=false

usage() {
  cat <<'EOF'
Usage: scripts/prepare-runtime-models.sh [--verify-only|--validate-registry-only]

Downloads missing runtime artifacts from their pinned Hugging Face revisions
and verifies every file against ai/models/runtime-models.json.

Options:
  --verify-only  Do not download; verify files already present.
  --validate-registry-only
                 Validate the model registry without downloading files, then exit.
  -h, --help     Show this help.
EOF
}

fail() {
  echo "Runtime model preparation failed: $*" >&2
  exit 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi

  fail "shasum or sha256sum is required"
}

file_bytes() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then
    stat -f '%z' "$1"
    return
  fi

  if stat -c '%s' "$1" >/dev/null 2>&1; then
    stat -c '%s' "$1"
    return
  fi

  fail "unable to determine byte length for $1"
}

verify_artifact() {
  local target_path="$1"
  local expected_bytes="$2"
  local expected_sha="$3"
  local artifact_id="$4"

  [[ -f "${target_path}" ]] \
    || fail "missing ${artifact_id}: ${target_path}"

  local actual_bytes
  actual_bytes="$(file_bytes "${target_path}")"
  [[ "${actual_bytes}" == "${expected_bytes}" ]] \
    || fail "${artifact_id} byte length mismatch: expected ${expected_bytes}, got ${actual_bytes}"

  local actual_sha
  actual_sha="$(sha256_file "${target_path}")"
  [[ "${actual_sha}" == "${expected_sha}" ]] \
    || fail "${artifact_id} SHA-256 mismatch: expected ${expected_sha}, got ${actual_sha}"
}

resolve_hf_command() {
  if command -v hf >/dev/null 2>&1; then
    HF_COMMAND=(hf)
    return
  fi

  if command -v uvx >/dev/null 2>&1; then
    HF_COMMAND=(uvx --from huggingface_hub hf)
    return
  fi

  fail "install Hugging Face CLI or uv before downloading models"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    --validate-registry-only)
      VALIDATE_REGISTRY_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "${REGISTRY_PATH}" ]] || fail "registry not found: ${REGISTRY_PATH}"

jq -e '
  .schemaVersion == 1
  and (.artifacts | type == "array" and length > 0)
  and ([.artifacts[].id] | length == (unique | length))
  and all(.artifacts[];
    (.id | type == "string" and length > 0)
    and (.repository | type == "string" and length > 0)
    and (.revision | test("^[0-9a-f]{40}$"))
    and (.sha256 | test("^[0-9a-f]{64}$"))
    and (.bytes | type == "number" and . > 0)
    and (.relativePath | type == "string" and length > 0
      and (startswith("/") | not) and (split("/") | index("..") == null))
    and (.requiresAuthentication | type == "boolean")
  )
' "${REGISTRY_PATH}" >/dev/null \
  || fail "registry schema is invalid"

if [[ "${VALIDATE_REGISTRY_ONLY}" == true ]]; then
  echo "Runtime model registry is valid."
  exit 0
fi

if [[ "${VERIFY_ONLY}" == false ]]; then
  resolve_hf_command
fi

mkdir -p "${ARTIFACT_ROOT}"

while IFS= read -r artifact; do
  artifact_id="$(jq -r '.id' <<<"${artifact}")"
  repository="$(jq -r '.repository' <<<"${artifact}")"
  revision="$(jq -r '.revision' <<<"${artifact}")"
  filename="$(jq -r '.filename' <<<"${artifact}")"
  relative_path="$(jq -r '.relativePath' <<<"${artifact}")"
  expected_bytes="$(jq -r '.bytes' <<<"${artifact}")"
  expected_sha="$(jq -r '.sha256' <<<"${artifact}")"
  requires_auth="$(jq -r '.requiresAuthentication' <<<"${artifact}")"
  target_path="${ARTIFACT_ROOT}/${relative_path}"

  if [[ -f "${target_path}" ]]; then
    verify_artifact \
      "${target_path}" \
      "${expected_bytes}" \
      "${expected_sha}" \
      "${artifact_id}"
    echo "Verified ${artifact_id}"
    continue
  fi

  if [[ "${VERIFY_ONLY}" == true ]]; then
    fail "missing ${artifact_id}: ${target_path}"
  fi

  destination_dir="$(dirname "${target_path}")"
  mkdir -p "${destination_dir}"
  echo "Downloading ${artifact_id} from ${repository}@${revision}..."

  if ! "${HF_COMMAND[@]}" download \
    "${repository}" \
    "${filename}" \
    --revision "${revision}" \
    --local-dir "${destination_dir}"; then
    if [[ "${requires_auth}" == true ]]; then
      fail "${artifact_id} requires repository access; accept the model terms and run: uvx --from huggingface_hub hf auth login"
    fi
    fail "download failed for ${artifact_id}"
  fi

  verify_artifact \
    "${target_path}" \
    "${expected_bytes}" \
    "${expected_sha}" \
    "${artifact_id}"
  echo "Downloaded and verified ${artifact_id}"
done < <(jq -c '.artifacts[]' "${REGISTRY_PATH}")

echo "Runtime models are ready at ${ARTIFACT_ROOT}"
