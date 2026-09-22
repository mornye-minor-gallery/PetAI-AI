#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT
SOURCE_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Sources/LiteRTLM"
xcrun swiftc "$SOURCE_ROOT/GemmaChannelFilter.swift" "$SOURCE_ROOT/InputPrefixTrace.swift" \
  "$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CachedSession/main.swift" -o "$TASK_BUILD_DIR/tests"
"$TASK_BUILD_DIR/tests"
TEST_ROOT="$REPO_ROOT/ios/ThirdParty/LiteRTLM/Tests/CachedSession"
HEADER_ROOT="$REPO_ROOT/ios/.artifacts/CLiteRTLM.xcframework/ios-arm64/CLiteRTLM.framework/Headers"
xcrun clang -c "$TEST_ROOT/stub.c" -I "$TEST_ROOT" -I "$HEADER_ROOT" -o "$TASK_BUILD_DIR/stub.o"
xcrun swiftc -I "$TEST_ROOT" -Xcc -I -Xcc "$HEADER_ROOT" \
  "$SOURCE_ROOT/CachedSession.swift" "$SOURCE_ROOT/NativeStreamLifetime.swift" \
  "$SOURCE_ROOT/GemmaChannelFilter.swift" "$SOURCE_ROOT/InputPrefixTrace.swift" \
  "$TEST_ROOT/RuntimeStubs.swift" "$TEST_ROOT/LifecycleTests.swift" "$TASK_BUILD_DIR/stub.o" -o "$TASK_BUILD_DIR/lifecycle"
"$TASK_BUILD_DIR/lifecycle"
