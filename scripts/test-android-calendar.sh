#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
calendar_test_dir=$(mktemp -d)
trap 'rm -r "$calendar_test_dir"' EXIT
calendar_javac="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
calendar_java="${JAVA_HOME:+$JAVA_HOME/bin/}java"
"$calendar_javac" -encoding UTF-8 -d "$calendar_test_dir" \
  android/Platform/src/com/byeolmuri/petai/platform/CalendarFailure.java \
  android/Platform/src/com/byeolmuri/petai/platform/CalendarQuery.java \
  android/Platform/src/com/byeolmuri/petai/platform/CalendarEventDraft.java \
  android/Platform/src/com/byeolmuri/petai/platform/CalendarEngine.java \
  android/tests/Calendar/CalendarEngineTest.java
"$calendar_java" -cp "$calendar_test_dir" com.byeolmuri.petai.platform.CalendarEngineTest
