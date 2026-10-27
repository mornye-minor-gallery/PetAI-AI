#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -r "$test_dir"' EXIT
swiftc android/Runtime/AndroidEngineProfile.swift android/tests/BackendSelection/main.swift -o "$test_dir/backend-test"
"$test_dir/backend-test"
