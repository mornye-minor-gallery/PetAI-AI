#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
: "${JAVA_HOME:?Set JAVA_HOME to the Android JDK}"
serial="${1:?Pass one explicit ADB device serial}"
build_tools="${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"
sdk_api="${ANDROID_COMPILE_API:-36}"
test_dir=$(mktemp -d)
adb="$ANDROID_HOME/platform-tools/adb"
remote_dir=$($adb -s "$serial" shell mktemp -d /data/local/tmp/petai-calendar-json.XXXXXX | tr -d '\r')
[[ "$remote_dir" == /data/local/tmp/petai-calendar-json.* ]] || exit 1
cleanup() {
  "$adb" -s "$serial" shell rm -r "$remote_dir"
  rm -r "$test_dir"
}
trap cleanup EXIT
mkdir "$test_dir/classes" "$test_dir/dex"
"$JAVA_HOME/bin/javac" -encoding UTF-8 --release 8 \
  -cp "$ANDROID_HOME/platforms/android-$sdk_api/android.jar" -d "$test_dir/classes" \
  android/Platform/src/com/byeolmuri/petai/platform/CalendarArguments.java \
  android/tests/Calendar/CalendarArgumentsTest.java
"$JAVA_HOME/bin/jar" cf "$test_dir/tests.jar" -C "$test_dir/classes" .
"$ANDROID_HOME/build-tools/$build_tools/d8" --min-api 28 \
  --lib "$ANDROID_HOME/platforms/android-$sdk_api/android.jar" \
  --output "$test_dir/dex" "$test_dir/tests.jar"
"$adb" -s "$serial" push "$test_dir/dex/classes.dex" "$remote_dir/classes.dex" >/dev/null
"$adb" -s "$serial" shell dalvikvm -cp "$remote_dir/classes.dex" com.byeolmuri.petai.platform.CalendarArgumentsTest
