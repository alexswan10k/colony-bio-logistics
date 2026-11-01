#!/usr/bin/env bash
# Copy reports from an in-game run into spike-results/<timestamp>/ and print a PASS/FAIL digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
SRC="$FACTORIO_USER_DIR/script-output/colony-spikes"
[ -d "$SRC" ] || { echo "no reports at $SRC"; exit 1; }
OUT="$REPO_ROOT/spike-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
cp "$SRC"/*.txt "$OUT"/
cp "$FACTORIO_USER_DIR/factorio-current.log" "$OUT/factorio-current.log" 2>/dev/null || true
grep -h "\[PROF\]\|spike_" "$OUT/factorio-current.log" > "$OUT/profiler-lines.txt" 2>/dev/null || true
echo "== collected to $OUT"; grep -hE "^\[(PASS|FAIL|ERR|\?\?\?\?)|SUMMARY" "$OUT"/s*.txt || true
