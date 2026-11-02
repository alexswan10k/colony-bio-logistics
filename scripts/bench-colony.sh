#!/usr/bin/env bash
# UPS gate (#39 / #22): measure the colony layer's cost at target scale.
#   1. headless server builds a synthetic town (m1_bench) and saves it;
#   2. --benchmark the fresh map (mod on, no colony) = baseline;
#   3. --benchmark the colony save = loaded;
# and compare the per-tick average against the #22 budget.
#   scripts/bench-colony.sh                          # 500 colonists, 2000 machines, 3600 ticks
#   POP=200 MACHINES=500 TICKS=1800 scripts/bench-colony.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"; need_bin
POP="${POP:-500}"; MACHINES="${MACHINES:-2000}"; TICKS="${TICKS:-3600}"; BUDGET_MS="${BUDGET_MS:-1.0}"
MAP_SEED="${MAP_SEED:-1234567}"
WORK="$REPO_ROOT/build/bench"; rm -rf "$WORK"; mkdir -p "$WORK/mods"
WRITE="$WORK/write-data"; mkdir -p "$WRITE" "$WRITE/saves"
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
cfg.update({"name": "colony bench", "auto_pause": False, "autosave_interval": 0,
            "visibility": {"public": False, "lan": True}})
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PYEOF
DEST="$WORK/mods/${MOD_NAME}_${MOD_VERSION}"
cp -R "$REPO_ROOT/mod" "$DEST"
cat > "$WORK/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":true}]}
JSON
FACT=(--config "$WORK/config.ini" --mod-directory "$WORK/mods" --disable-audio)

echo "== creating map"
"$FACTORIO_BIN" "${FACT[@]}" --create "$WORK/spike.zip" --map-gen-seed "$MAP_SEED" > "$WORK/create.log" 2>&1 || { tail -20 "$WORK/create.log"; exit 1; }
cp "$WORK/spike.zip" "$WORK/baseline.zip"     # pristine map, kept for the no-colony baseline

# build_town <name> [inert] : run a headless server that builds the town and saves it as colony-bench[-inert]
build_town() {
  local name="$1"; local mode="${2:-}"
  cp "$WORK/baseline.zip" "$WORK/town-$name.zip"
  if [ -n "$mode" ]; then
    echo "return {{\"m1_bench\", \"$POP\", \"$MACHINES\", \"$mode\"},}" > "$DEST/autorun.lua"
  else
    echo "return {{\"m1_bench\", \"$POP\", \"$MACHINES\"},}" > "$DEST/autorun.lua"
  fi
  local save="$WRITE/saves/colony-bench${mode:+-$mode}.zip"
  rm -f "$save"
  "$FACTORIO_BIN" "${FACT[@]}" --start-server "$WORK/town-$name.zip" --port 34202 \
    --server-settings "$WORK/server-settings.json" > "$WORK/build-$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 "${BUILD_TIMEOUT:-600}"); do
    [ -f "$save" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [ ! -f "$save" ]; then echo "FAILED: $name town was not saved (see $WORK/build-$name.log)"; tail -30 "$WORK/build-$name.log"; exit 1; fi
  grep -hoE "(built|at save): pop=[0-9]+[^\"]*" "$WRITE"/script-output/colony-spikes/m1_bench.txt | tr '\n' ' ' || true
  echo
}

echo "== building a $POP-colonist town with $MACHINES machines"
build_town colony
echo "== building the inert control (same entities, nothing registered)"
build_town inert inert
echo "== building the demand town (every machine asks for ore)"
build_town demand demand

# The baseline must not re-run the bench spike, or it would build the town again.
rm -f "$DEST/autorun.lua"

# bench <save> <label> -> "<total> <script>" ms/tick. Column 3 is the whole update, column 44 is the Lua
# script time, both from --benchmark-verbose.
bench() {
  local out="$WORK/bench-$2.log"
  "$FACTORIO_BIN" "${FACT[@]}" --benchmark "$1" --benchmark-ticks "$TICKS" --benchmark-verbose all \
    > "$out" 2>&1 || { tail -20 "$out"; exit 1; }
  if ! awk -F, '/^t[0-9]+,/ {if (NF < 44) exit 1}' "$out"; then
    echo "FAILED: benchmark output has no script-time column (see $out)"; exit 1
  fi
  awk -F, '/^t[0-9]+,/ {t += $3; s += $44; k++} END {printf "%.3f %.3f\n", t / k / 1e6, s / k / 1e6}' "$out"
}
mkdir -p "$WORK/mods-vanilla"
cat > "$WORK/mods-vanilla/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},
{"name":"space-age","enabled":true},{"name":"${MOD_NAME}","enabled":false}]}
JSON
echo "== benchmarking vanilla + Space Age, no colony mod, for $TICKS ticks"
read -r BASE_T BASE_S < <(bench "$WORK/baseline.zip" baseline)
echo "== benchmarking the mod with no colony built"
VANILLA_T=$("$FACTORIO_BIN" --config "$WORK/config.ini" --mod-directory "$WORK/mods-vanilla" \
  --benchmark "$WORK/baseline.zip" --benchmark-ticks "$TICKS" --disable-audio 2>&1 \
  | grep -oE "avg: [0-9.]+ ms" | tail -1 | grep -oE "[0-9.]+")
echo "== benchmarking the inert control (same entities, nothing registered)"
read -r INERT_T INERT_S < <(bench "$WRITE/saves/colony-bench-inert.zip" inert)
echo "== benchmarking the colony (machines collect only)"
read -r LOADED_T LOADED_S < <(bench "$WRITE/saves/colony-bench.zip" colony)
echo "== benchmarking the demand town (every machine also requests ore)"
read -r DEMAND_T DEMAND_S < <(bench "$WRITE/saves/colony-bench-demand.zip" demand)

python3 - "$VANILLA_T" "$BASE_T" "$BASE_S" "$INERT_T" "$INERT_S" "$LOADED_T" "$LOADED_S" \
  "$DEMAND_T" "$DEMAND_S" "$POP" "$BUDGET_MS" <<'PYEOF'
import sys
(v_t, base_t, base_s, inert_t, inert_s, loaded_t, loaded_s,
 demand_t, demand_s) = (float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]),
                        float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7]), float(sys.argv[8]),
                        float(sys.argv[9]))
pop, budget = int(sys.argv[10]), float(sys.argv[11])
print(f"vanilla, mod disabled:            {v_t:6.3f} total")
print(f"mod on, no colony:                {base_t:6.3f} total  {base_s:6.3f} script   ({base_s - v_t:+.3f} with no colony)")
print(f"inert control (same entities):    {inert_t:6.3f} total  {inert_s:6.3f} script")
print(f"colony, machines collect only:    {loaded_t:6.3f} total  {loaded_s:6.3f} script")
print(f"colony, machines also demand ore: {demand_t:6.3f} total  {demand_s:6.3f} script")
print()
worst = max(loaded_s, demand_s)
print(f"worst colony Lua: {worst:.3f} ms/tick for {pop} colonists "
      f"({worst * 1e6 / max(pop, 1):.0f} us/colonist), budget <{budget:.2f}")
ok = worst <= budget
print(f"budget (#22): -> {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
PYEOF
