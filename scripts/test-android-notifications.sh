#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
notification_test_dir=$(mktemp -d)
trap 'rm -r "$notification_test_dir"' EXIT
"${JAVA_HOME:+$JAVA_HOME/bin/}javac" -encoding UTF-8 -d "$notification_test_dir" \
  android/Platform/src/com/byeolmuri/petai/platform/Notification{Failure,Record,Engine}.java \
  android/tests/Notifications/NotificationEngineTest.java
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$notification_test_dir" com.byeolmuri.petai.platform.NotificationEngineTest
