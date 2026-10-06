#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
check_root="$repo_root/ios/EdgeLLM/.build/native-tool-factory-check"
mkdir -p "$check_root"

# Compile the real vendor schema types; native inference binaries are not used by this contract.
xcrun swiftc -swift-version 5 -parse-as-library -emit-module -emit-library \
  -module-name LiteRTLM \
  ios/ThirdParty/LiteRTLM/Sources/LiteRTLM/Tool.swift \
  ios/ThirdParty/LiteRTLM/Sources/LiteRTLM/ExperimentalFlags.swift \
  -o "$check_root/libLiteRTLM.dylib"

# Importing the real schema module enables the production factory's canImport branch.
xcrun swiftc -swift-version 5 -parse-as-library -I "$check_root" \
  -L "$check_root" -lLiteRTLM -Xlinker -rpath -Xlinker "$check_root" \
  ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolContracts.swift \
  ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolArgumentGeneration.swift \
  ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolProposalParser.swift \
  ios/EdgeLLMLab/EdgeLLMLab/Runtime/LiteRTLMNativeToolProposalGenerator.swift \
  scripts/tests/native-tool-factory-check.swift \
  -o "$check_root/native-tool-factory-check"

"$check_root/native-tool-factory-check"
