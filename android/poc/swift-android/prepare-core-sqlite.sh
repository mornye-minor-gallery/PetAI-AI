#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
artifacts="$repo/android/.artifacts"
archive="$artifacts/sqlite-amalgamation-3530400.zip"
mkdir -p "$artifacts"
if [ ! -f "$archive" ]; then
    curl -fL https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip -o "$archive"
fi
actual=$(openssl dgst -sha3-256 "$archive" | awk '{print $NF}')
test "$actual" = 628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
unzip -q -o "$archive" -d "$artifacts"
target="$artifacts/sqlite-package"
mkdir -p "$target/Sources/SQLite3/include"
cp "$artifacts/sqlite-amalgamation-3530400/sqlite3.c" "$target/Sources/SQLite3/"
cp "$artifacts/sqlite-amalgamation-3530400/sqlite3.h" "$target/Sources/SQLite3/include/"
cp "$repo/android/poc/swift-android/SQLitePackage.swift" "$target/Package.swift"
printf 'SQLite 3.53.4 source verified and prepared.\n'
