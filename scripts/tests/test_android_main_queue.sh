#!/usr/bin/env bash
set -euo pipefail

# Runs the production dispatch adapter against a real Android Looper/eventfd.
# The dispatch stub lets the test enqueue a wakeup during callback execution.
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME}"
: "${ANDROID_HOME:?Set ANDROID_HOME}"
: "${PETAI_ANDROID_SERIAL:?Select an Android test device}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d)"
remote="/data/local/tmp/petai-main-queue-test-$$"
adb="$ANDROID_HOME/platform-tools/adb"
cleanup() {
    "$adb" -s "$PETAI_ANDROID_SERIAL" shell rm -f "$remote" >/dev/null 2>&1 || true
    rm -f "$scratch/test"
    rmdir "$scratch"
}
trap cleanup EXIT
case "$(uname -s)" in
    Darwin) host=darwin-x86_64 ;;
    Linux) host=linux-x86_64 ;;
    *) echo 'Unsupported NDK host' >&2; exit 1 ;;
esac
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android28-clang" \
    -Wall -Wextra -Werror -I"$root/android/Dispatch/include" \
    "$root/android/Dispatch/AndroidDispatch.c" \
    "$root/android/tests/main_queue_wakeup_test.c" \
    -landroid -llog -o "$scratch/test"
"$adb" -s "$PETAI_ANDROID_SERIAL" push "$scratch/test" "$remote"
"$adb" -s "$PETAI_ANDROID_SERIAL" shell "$remote"
