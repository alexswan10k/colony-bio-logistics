#!/usr/bin/env bash
# Run spikes headlessly (no player) in an isolated mod dir, then collect reports into spike-results/<timestamp>/.
#   scripts/headless-spike.sh s05_pod s06_tiles s09_crates
#   scripts/headless-spike.sh s01_units:200:60       # name:arg1:arg2 ...
#   TICKS=7200 scripts/headless-spike.sh s04_platform
# Spikes needing a player position use (0,0) on Nauvis. Spikes that need terrain (s01, s06, s10) are better run in-game.
# Runs against an isolated write-data dir, so it does NOT need the Factorio GUI closed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
[ $# -ge 1 ] || { echo "usage: $0 <spike[:arg...]>..."; exit 1; }
MAP_SEED="${MAP_SEED:-1234567}"   # fixed so a failing spike can be re-run on the same terrain
WORK="$REPO_ROOT/build/headless"; rm -rf "$WORK"; mkdir -p "$WORK/mods"
WRITE="$WORK/write-data"; mkdir -p "$WRITE"
cat > "$WORK/config.ini" <<INI
[path]
write-data=$WRITE
INI
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
cp -R "$REPO_ROOT/mod" "$DEST"
{
  echo "return {"
  for spec in "$@"; do
    IFS=: read -ra parts <<< "$spec"
    printf '  {'; for p in "${parts[@]}"; do printf '"%s",' "$p"; done; echo '},'
  done
  echo "}"
} > "$DEST/autorun.lua"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":true}]}
JSON
rm -rf "$WRITE/script-output/colony-spikes"
echo "== creating map"; "$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --create "$WORK/spike.zip" --map-gen-seed "$MAP_SEED" --disable-audio > "$WORK/create.log" 2>&1 || { tail -30 "$WORK/create.log"; exit 1; }
echo "== running ${TICKS:-3600} ticks"
"$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --benchmark "$WORK/spike.zip" --benchmark-ticks "${TICKS:-3600}" --disable-audio > "$WORK/run.log" 2>&1 || { tail -40 "$WORK/run.log"; exit 1; }
OUT="$REPO_ROOT/spike-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
cp "$WRITE"/script-output/colony-spikes/*.txt "$OUT"/ 2>/dev/null || echo "no reports written (spike crashed before start? see $WORK/run.log)"
grep -E "spike|Error|error" "$WORK/run.log" > "$OUT/game-log-excerpt.txt" || true
echo "== results in $OUT"; grep -hE "^\[(PASS|FAIL|ERR|\?\?\?\?)|SUMMARY" "$OUT"/*.txt || true
