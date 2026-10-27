#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
alarm_test_dir=$(mktemp -d)
trap 'rm -r "$alarm_test_dir"' EXIT
alarm_javac="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
alarm_java="${JAVA_HOME:+$JAVA_HOME/bin/}java"
"$alarm_javac" -encoding UTF-8 -d "$alarm_test_dir" \
  android/Platform/src/com/byeolmuri/petai/platform/AlarmCommand.java \
  android/Platform/src/com/byeolmuri/petai/platform/AlarmRecord.java \
  android/Platform/src/com/byeolmuri/petai/platform/AlarmFailure.java \
  android/Platform/src/com/byeolmuri/petai/platform/AlarmEngine.java \
  android/tests/OwnedAlarms/AlarmEngineTest.java
"$alarm_java" -cp "$alarm_test_dir" com.byeolmuri.petai.platform.AlarmEngineTest
