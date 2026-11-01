#!/usr/bin/env bash
# Headless UPS benchmark. Usage: scripts/benchmark.sh <save.zip> [ticks]
# Requires FACTORIO_BIN (path to factorio binary). Compare runs with the mod enabled vs disabled.
set -euo pipefail
: "${FACTORIO_BIN:?set FACTORIO_BIN to the factorio executable}"
"$FACTORIO_BIN" --benchmark "$1" --benchmark-ticks "${2:-3600}" --benchmark-verbose all --disable-audio
