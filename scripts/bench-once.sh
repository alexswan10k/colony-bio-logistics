#!/usr/bin/env bash
# Fast #22 loop: benchmark an existing bench save with the CURRENT mod tree, without rebuilding the town.
#   scripts/bench-once.sh [save] [ticks]
# Default save is the demand town that scripts/bench-colony.sh leaves in build/bench (every machine asks
# for ore, the worst realistic case). Copies mod/ into the bench mod dir first, so edits are picked up.
# Prints total and script ms/tick for the run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
WORK="${BENCH_DIR:-$REPO_ROOT/build/bench}"
SAVE="${1:-$WORK/write-data/saves/colony-bench-demand.zip}"
TICKS="${2:-${TICKS:-1800}}"
[ -f "$SAVE" ] || { echo "no save at $SAVE - run scripts/bench-colony.sh once to build one"; exit 1; }
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"; cp -R "$REPO_ROOT/mod" "$DEST"
OUT="$WORK/bench-once.log"
"$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --disable-audio \
  --benchmark "$SAVE" --benchmark-ticks "$TICKS" --benchmark-verbose all > "$OUT" 2>&1 || { tail -20 "$OUT"; exit 1; }
awk -F, '/^t[0-9]+,/ {if (NF < 44) exit 1; t += $3; s += $44; k++}
  END {printf "total %.3f ms/tick   script %.3f ms/tick   (%d ticks)\n", t / k / 1e6, s / k / 1e6, k}' "$OUT"
