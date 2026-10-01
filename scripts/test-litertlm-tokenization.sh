#!/usr/bin/env bash
set -euo pipefail

# Tests ownership, UTF-8 and failure behavior against a deliberately small C stub.
# This does not replace real XCFramework linking or model token-count validation.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT
TEST_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/TokenizationBoundary"
SOURCE_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Sources/LiteRTLM"

xcrun clang -c "$TEST_ROOT/stub.c" -I "$TEST_ROOT" -o "$TASK_BUILD_DIR/stub.o"
xcrun swiftc -I "$TEST_ROOT" \
  "$SOURCE_ROOT/LiteRTLMError.swift" "$SOURCE_ROOT/NativeTokenization.swift" \
  "$TEST_ROOT/main.swift" "$TASK_BUILD_DIR/stub.o" -o "$TASK_BUILD_DIR/tokenization-test"
"$TASK_BUILD_DIR/tokenization-test"
