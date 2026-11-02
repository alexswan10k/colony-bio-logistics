#!/usr/bin/env bash
# Save/load regression (#39): build a live colony, auto-save it, reload the save in a *new process* and
# assert that every registry, scheduler entry and rendering came back. Reports land in
# spike-results/<timestamp>/ like the other spikes.
#   scripts/save-load.sh            # phase 1 = 900 ticks, phase 2 = 600 ticks
#   PHASE1_TICKS=1200 PHASE2_TICKS=900 scripts/save-load.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
WORK="$REPO_ROOT/build/persist"; rm -rf "$WORK"; mkdir -p "$WORK/mods"
WRITE="$WORK/write-data"; mkdir -p "$WRITE"
cat > "$WORK/config.ini" <<INI
[path]
write-data=$WRITE
[other]
port=34201
INI
# auto_pause defaults to true: an empty dedicated server would sit at tick 0 and never save.
SERVER_EXAMPLE="$(cd "$(dirname "$FACTORIO_BIN")/../data" && pwd)/server-settings.example.json"
python3 - "$SERVER_EXAMPLE" "$WORK/server-settings.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.update({"name": "colony persist test", "auto_pause": False, "autosave_interval": 0,
            "visibility": {"public": False, "lan": True}})
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PYEOF
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
cp -R "$REPO_ROOT/mod" "$DEST"
echo 'return {{"m1_persist"},}' > "$DEST/autorun.lua"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":true}]}
JSON
rm -rf "$WRITE/script-output/colony-spikes"
mkdir -p "$WRITE/saves"; rm -f "$WRITE"/saves/*.zip   # server_save needs the directory to exist
run() {  # run <logfile> <factorio args...>
  local log="$1"; shift
  if ! "$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --disable-audio "$@" > "$log" 2>&1; then
    echo "FAILED: factorio $*"; tail -40 "$log"; exit 1
  fi
}
echo "== creating map"
run "$WORK/create.log" --create "$WORK/spike.zip"
# Phase 1 runs as a headless *server*: game.server_save only writes in multiplayer, and a dedicated server
# ticks with nobody connected. The spike saves a few hundred ticks in; we wait for the file, then stop it.
echo "== phase 1: build a colony and save (headless server)"
"$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --start-server "$WORK/spike.zip" \
  --port 34201 --server-settings "$WORK/server-settings.json" --disable-audio > "$WORK/phase1.log" 2>&1 &
PID=$!
SAVE="$WRITE/saves/colony-persist.zip"
for _ in $(seq 1 "${PHASE1_TIMEOUT:-180}"); do
  [ -f "$SAVE" ] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
if [ ! -f "$SAVE" ]; then
  echo "FAILED: no save file was written (see $WORK/phase1.log)"
  tail -30 "$WORK/phase1.log" || true
  exit 1
fi
echo "== phase 2: reload $SAVE and assert (${PHASE2_TICKS:-600} ticks)"
run "$WORK/phase2.log" --test-save "$SAVE" --test-ticks "${PHASE2_TICKS:-600}" --test-arg m1_persist_load
OUT="$REPO_ROOT/spike-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
cp "$WRITE"/script-output/colony-spikes/*.txt "$OUT"/ 2>/dev/null || true
grep -hE "^\[(PASS|FAIL|ERR|\?\?\?\?)" "$OUT"/*.txt >/dev/null 2>&1 || {
  echo "FAILED: no spike reports (see $WORK/phase2.log)"; tail -30 "$WORK/phase2.log"; exit 1; }
echo "== results in $OUT"
grep -hE "^\[" "$OUT"/*.txt || true
if grep -qhE "^\[(FAIL|ERR|\?\?\?\?)" "$OUT"/*.txt; then echo "SAVE/LOAD: FAIL"; exit 1; fi
echo "SAVE/LOAD: PASS"
