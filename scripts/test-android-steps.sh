#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
step_test_dir=$(mktemp -d)
trap 'rm -r "$step_test_dir"' EXIT
"${JAVA_HOME:+$JAVA_HOME/bin/}javac" -encoding UTF-8 -d "$step_test_dir" \
  android/Platform/src/com/byeolmuri/petai/platform/StepFailure.java \
  android/Platform/src/com/byeolmuri/petai/platform/StepQuery.java \
  android/Platform/src/com/byeolmuri/petai/platform/StepReader.java \
  android/tests/Steps/StepQueryTest.java android/tests/Steps/StepReaderTest.java
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$step_test_dir" com.byeolmuri.petai.platform.StepQueryTest
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp "$step_test_dir" com.byeolmuri.petai.platform.StepReaderTest
