#!/usr/bin/env bash
# Compiles the app's sources, minus its entry point, with Tests/SelfTest.swift and runs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
OUT="$ROOT/build/selftest"
SOURCES=$(find "$ROOT/Sources/Pinup" -name '*.swift' ! -name main.swift)
# shellcheck disable=SC2086
swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 -framework Carbon \
    $SOURCES "$ROOT/Tests/SelfTest.swift" -o "$OUT"
"$OUT"
