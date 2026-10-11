#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT
SOURCE_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Sources/LiteRTLM"
TEST_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/EnginePrefillSettings"
xcrun clang -c "$TEST_ROOT/stub.c" -o "$TASK_BUILD_DIR/stub.o"
xcrun swiftc -I "$TEST_ROOT" "$SOURCE_ROOT/LiteRTLMError.swift" \
  "$SOURCE_ROOT/EnginePrefillSettings.swift" "$TEST_ROOT/main.swift" \
  "$TASK_BUILD_DIR/stub.o" -o "$TASK_BUILD_DIR/swift-test"
"$TASK_BUILD_DIR/swift-test"
if [[ $# -eq 1 ]]; then
  xcrun clang++ -std=c++17 -I "$1" "$TEST_ROOT/native.cc" -o "$TASK_BUILD_DIR/native-test"
  "$TASK_BUILD_DIR/native-test"
  echo "Static CPU prefill runner selection passed."
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [PREPARED_LITERTLM_SOURCE]" >&2
  exit 2
fi
