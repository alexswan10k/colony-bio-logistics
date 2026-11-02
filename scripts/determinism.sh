#!/usr/bin/env bash
# Determinism gate (#39): the same spike on the same map, run twice in separate processes, must produce an
# identical report and an identical final simulation checksum. This is the multiplayer stand-in we can run
# headlessly: a desync is a divergence between two peers running the same inputs.
#   scripts/determinism.sh                       # m1_colony, 14000 ticks
#   SPIKE=m1_food TICKS=3600 scripts/determinism.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
SPIKE="${SPIKE:-m1_colony}"; TICKS="${TICKS:-14000}"
MAP_SEED="${MAP_SEED:-1234567}"   # fixed so the two runs (and later re-runs) share one map
WORK="$REPO_ROOT/build/determinism"; rm -rf "$WORK"; mkdir -p "$WORK/mods"
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
cp -R "$REPO_ROOT/mod" "$DEST"
printf 'return {{"%s"},}\n' "$SPIKE" > "$DEST/autorun.lua"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":true}]}
JSON
echo "== creating map"
"$FACTORIO_BIN" --config <(printf '[path]\nwrite-data=%s\n' "$WORK/create-data") \
  --mod-directory "$WORK/mods" --create "$WORK/map.zip" --map-gen-seed "$MAP_SEED" --disable-audio > "$WORK/create.log" 2>&1 \
  || { tail -20 "$WORK/create.log"; exit 1; }

run_once() {  # run_once <a|b>
  local w="$WORK/run-$1"; mkdir -p "$w/write-data"
  printf '[path]\nwrite-data=%s\n' "$w/write-data" > "$w/config.ini"
  echo "== run $1: $SPIKE for $TICKS ticks" >&2
  "$FACTORIO_BIN" --config "$w/config.ini" --mod-directory "$WORK/mods" --benchmark "$WORK/map.zip" \
    --benchmark-ticks "$TICKS" --disable-audio > "$w/run.log" 2>&1 \
    || { tail -30 "$w/run.log"; exit 1; }
  cp "$w/write-data/script-output/colony-spikes/$SPIKE.txt" "$w/report.txt" 2>/dev/null \
    || { echo "FAILED: run $1 wrote no report (see $w/run.log)" >&2; exit 1; }
  grep -oE "checksum: [0-9]+" "$w/run.log" | tail -1 | grep -oE "[0-9]+"
}
CK_A=$(run_once a)
CK_B=$(run_once b)

OUT="$REPO_ROOT/spike-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
cp "$WORK/run-a/report.txt" "$OUT/$SPIKE-a.txt"; cp "$WORK/run-b/report.txt" "$OUT/$SPIKE-b.txt"

norm() { sed -E 's/^# spike .* tick [0-9]+/# spike header/' "$1"; }
fail=0
if [ "$CK_A" != "$CK_B" ]; then
  echo "CHECKSUM DIVERGED: $CK_A vs $CK_B"; fail=1
fi
if ! diff -q <(norm "$WORK/run-a/report.txt") <(norm "$WORK/run-b/report.txt") > /dev/null; then
  echo "REPORT DIVERGED:"; diff -u <(norm "$WORK/run-a/report.txt") <(norm "$WORK/run-b/report.txt") | head -40
  fail=1
fi
if grep -qhE "^\[(FAIL|ERR)" "$WORK"/run-*/report.txt; then echo "REPORT CONTAINS FAILURES"; fail=1; fi
grep -hE "^(SUMMARY|# spike)" "$WORK/run-a/report.txt" || true
echo "final checksum: $CK_A"
echo "== results in $OUT"
[ "$fail" = 0 ] && echo "DETERMINISM: PASS" || { echo "DETERMINISM: FAIL"; exit 1; }
