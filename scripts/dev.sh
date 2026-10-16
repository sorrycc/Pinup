#!/usr/bin/env bash
# Runs Pinup with live reload (go tool mygo dev) beside the everyday Pinup.
# MyGo gives it an identifier of its own, so an instance lock of its own;
# PINUP_HOME gives it its own history, settings and secrets.
# Usage: scripts/dev.sh [mygo dev flags]
# PINUP_HOME picks another data folder (default: Pinup-dev beside Pinup's).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PINUP_HOME="${PINUP_HOME:-$HOME/Library/Application Support/Pinup-dev}"
mkdir -p "$PINUP_HOME"

echo "==> mygo dev (data in $PINUP_HOME)"
cd "$ROOT"
exec go tool mygo dev "$@"
