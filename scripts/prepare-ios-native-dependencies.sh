#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_ROOT="$REPO_ROOT/ios/.artifacts"
DESTINATION="$ARTIFACT_ROOT/CLiteRTLM.xcframework"
ARCHIVE_URL="https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM.xcframework.zip"
EXPECTED_SHA256="dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
TEMP_ROOT=$(mktemp -d)
ARCHIVE_PATH="$TEMP_ROOT/CLiteRTLM.xcframework.zip"
EXTRACT_ROOT="$TEMP_ROOT/extracted"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$EXTRACT_ROOT" "$ARTIFACT_ROOT"

echo "Downloading LiteRT-LM v0.14.0 iOS XCFramework..."
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
if [[ -z "$EXTRACTED_FRAMEWORK" || ! -f "$EXTRACTED_FRAMEWORK/Info.plist" ]]; then
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

echo "Prepared: $DESTINATION"
