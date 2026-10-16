#!/usr/bin/env bash
# Runs Pinup from source with live reload, beside the everyday Pinup: it
# builds a bare binary, runs it, and builds and restarts it when a Go file,
# an asset or mygo.json changes. A build that fails keeps the running one.
# Quit Pinup, or press Ctrl-C, to stop.
#
# A bare binary rather than mygo dev's "Pinup Dev" bundle: macOS 26 keeps the
# menu bar icon of that bundle hidden, even when System Settings allows it.
# The binary's name gives it an instance lock of its own; PINUP_HOME gives it
# its own history, settings and secrets.
#
# Usage: scripts/dev.sh [launch arguments, such as -show hosts]
# PINUP_HOME picks another data folder (default: Pinup-dev beside Pinup's).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PINUP_HOME="${PINUP_HOME:-$HOME/Library/Application Support/Pinup-dev}"
OUT="$ROOT/.mygo/dev"
BIN="$OUT/pinup"
STAMP="$OUT/built"

mkdir -p "$PINUP_HOME" "$OUT"
cd "$ROOT"

APP=""
stop() {
    if [ -n "$APP" ] && kill -0 "$APP" 2>/dev/null; then
        kill "$APP" 2>/dev/null || true
        wait "$APP" 2>/dev/null || true
    fi
    APP=""
}
trap 'stop; exit 0' INT TERM

build() {
    touch "$STAMP.next"
    if go build -o "$BIN.next" ./cmd/pinup; then
        mv "$BIN.next" "$BIN"
        mv "$STAMP.next" "$STAMP"
        return 0
    fi
    rm -f "$STAMP.next"
    return 1
}

# changed reports whether a source file is newer than the last build.
changed() {
    [ -n "$(find cmd internal mygo.json go.mod go.sum -newer "$STAMP" -type f \
        \( -name '*.go' -o -name '*.png' -o -name '*.json' -o -name 'go.mod' -o -name 'go.sum' \) \
        -not -name '*_test.go' -print -quit 2>/dev/null)" ]
}

start() {
    "$BIN" "$@" &
    APP=$!
    echo "==> Pinup is running (pid $APP, data in $PINUP_HOME)"
}

echo "==> building"
build
start "$@"
while true; do
    sleep 1
    if ! kill -0 "$APP" 2>/dev/null; then
        echo "==> Pinup quit"
        exit 0
    fi
    if changed; then
        echo "==> rebuilding"
        if build; then
            stop
            start "$@"
        else
            echo "==> the build failed; Pinup keeps running the last one"
        fi
    fi
done
