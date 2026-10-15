#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zone_test_dir=$(mktemp -d)
trap 'rm -r "$zone_test_dir"' EXIT
clang -Iandroid/PlatformJNI/include -c android/PlatformJNI/TimeZoneEnvironment.c -o "$zone_test_dir/environment.o"
swiftc -Iandroid/tests/OwnedAlarms/TimeZone android/PlatformSwift/AndroidTimeZone.swift \
  android/tests/OwnedAlarms/TimeZone/main.swift "$zone_test_dir/environment.o" -o "$zone_test_dir/test"
"$zone_test_dir/test"
