#!/usr/bin/env bash
# Headless UPS benchmark of an existing save. Usage: scripts/benchmark.sh <save.zip> [ticks=3600]
# Compare mod enabled vs disabled by editing mod-list.json / or using --mod-directory.
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
"$FACTORIO_BIN" --benchmark "$1" --benchmark-ticks "${2:-3600}" --benchmark-verbose all --disable-audio
