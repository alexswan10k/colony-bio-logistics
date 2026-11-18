#!/usr/bin/env bash
# Tourism save/load regression (#51, REVIEW.md MINOR 4): phase 1 runs a headless server, lets a real tourist
# board a coach and alight at the Spa, then saves mid-visit. Phase 2 loads that save in a new process and
# asserts the pending visit/beds survive and exactly one insight per visitor is paid at home - no duplicate
# payout on load. Modelled on scripts/save-load.sh (#39).
#   scripts/tourism-save-load.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
MAP_SEED="${MAP_SEED:-1234567}"   # fixed so a failing round-trip is reproducible
WORK="$REPO_ROOT/build/tourism-persist"; rm -rf "$WORK"; mkdir -p "$WORK/mods"
WRITE="$WORK/write-data"; mkdir -p "$WRITE"
cat > "$WORK/config.ini" <<INI
[path]
write-data=$WRITE
[other]
port=34202
INI
SERVER_EXAMPLE="$(cd "$(dirname "$FACTORIO_BIN")/../data" && pwd)/server-settings.example.json"
python3 - "$SERVER_EXAMPLE" "$WORK/server-settings.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.update({"name": "colony tourism persist test", "auto_pause": False, "autosave_interval": 0,
            "visibility": {"public": False, "lan": True}})
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PYEOF
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
cp -R "$REPO_ROOT/mod" "$DEST"
echo 'return {{"m2_tourism_save"},}' > "$DEST/autorun.lua"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":true}]}
JSON
rm -rf "$WRITE/script-output/colony-spikes"
mkdir -p "$WRITE/saves"; rm -f "$WRITE"/saves/*.zip
run() {  # run <logfile> <factorio args...>
  local log="$1"; shift
  if ! "$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --disable-audio "$@" > "$log" 2>&1; then
    echo "FAILED: factorio $*"; tail -40 "$log"; exit 1
  fi
}
echo "== creating map"
run "$WORK/create.log" --create "$WORK/spike.zip" --map-gen-seed "$MAP_SEED"
echo "== phase 1: real tourist reaches the Spa, save mid-visit (headless server)"
"$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods" --start-server "$WORK/spike.zip" \
  --port 34202 --server-settings "$WORK/server-settings.json" --disable-audio > "$WORK/phase1.log" 2>&1 &
PID=$!
SAVE="$WRITE/saves/colony-tourism.zip"
for _ in $(seq 1 "${PHASE1_TIMEOUT:-240}"); do
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
echo "== phase 2: reload $SAVE and assert one payout (${PHASE2_TICKS:-16000} ticks)"
run "$WORK/phase2.log" --test-save "$SAVE" --test-ticks "${PHASE2_TICKS:-16000}" --test-arg m2_tourism_load
OUT="$REPO_ROOT/spike-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
cp "$WRITE"/script-output/colony-spikes/*.txt "$OUT"/ 2>/dev/null || true
grep -hE "^\[(PASS|FAIL|ERR|\?\?\?\?)" "$OUT"/*.txt >/dev/null 2>&1 || {
  echo "FAILED: no spike reports (see $WORK/phase2.log)"; tail -30 "$WORK/phase2.log"; exit 1; }
echo "== results in $OUT"
grep -hE "^\[" "$OUT"/*.txt || true
if grep -qhE "^\[(FAIL|ERR|\?\?\?\?)" "$OUT"/*.txt; then echo "TOURISM SAVE/LOAD: FAIL"; exit 1; fi
echo "TOURISM SAVE/LOAD: PASS"
