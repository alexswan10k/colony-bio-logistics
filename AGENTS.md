# AGENTS.md
Factorio 2.0 + Space Age (hard dep) colony mod. Design: `docs/factorio_colony_mod_design_document.md`. Work tracked in GitHub issues/milestones (M0 spikes+decisions gate M1-M4). Repo: alexswan10k/colony-bio-logistics. Owner uses macOS + Steam. API docs: https://lua-api.factorio.com/latest/ (always verify 2.0 signatures here).

## Layout
`mod/` mod (Lua 5.2 runtime) · `mod/scripts/model/` PURE logic · `mod/scripts/spike/` dev-only API spikes · `tests/` · `sim/` balance · `scripts/` tooling · `docs/` (SPIKES, TESTING, DEPLOYMENT, ART) · `spike-results/` run reports.

## Commands
`scripts/test.sh [filter]` unit tests (luajit) · `scripts/sim.sh` balance tables · `scripts/lint-determinism.sh` · `scripts/link-dev.sh` symlink into Factorio mods · `scripts/package.sh [--release]` · `scripts/headless-spike.sh <spike[:args]>` · `scripts/save-load.sh` (#39 save/load round-trip) · `scripts/determinism.sh` (#39 two-run checksum) · `scripts/bench-colony.sh` (#39/#22 UPS gate) · `scripts/collect-results.sh` + `scripts/post-results.sh <report>` · `scripts/benchmark.sh <save>`.
Always run test.sh + lint-determinism.sh + `luajit -bl` on changed Lua before committing. Commit and push after changes.

## Rules
- Game rules go in `model/` with NO Factorio globals (`game/storage/script/defines/surface`); in-game code is a thin adapter. Test models offline; engine behaviour only via in-game spikes. Mocks encode beliefs, not evidence.
- Factorio 2.0 Lua API: Reference https://lua-api.factorio.com/latest/ for exact classes, parameters, and signatures.
- Lua 5.2: no `|`, `&`, `//`, `goto` ok. No `math.random`/`os`/`io` outside spikes (use `game.create_random_generator`). Never store functions in `storage`. Register events via `scripts.events` at load time only. Schema changes need a `store.lua` migration.
- Do not edit vanilla prototypes (opt-in design pillar). Don't scan entities per tick; use registries + `scheduler`.
- Spike/decision outcomes: record on the GitHub issue (comment + close), update docs/design doc if the design changes. Track progress via `gh issue` and project milestones.

## Decisions made
Territory = chunk-granular 32x32 (#15). Space Age required (#12). Watchtower = 1-chunk ring, must be built on claimed land (#56). Farming = player-placed plots + tile fertility table (#44 first pass). Crates are plain containers (belts/inserters still work), driven by our own registry (#33). Construction = pay the ghost's `items_to_place_this` from colony stock, carry it, `revive`; repairs = one repair pack per 200 health (#37). Job locks are per-house, ore priorities are per-hut. Open decisions: #18-#22 (housing, science, disease, tourism, perf budget).

## Status
M0 spikes run; M1 core loop is playable and spike-verified (80 unit tests, 53-check `m1_colony`, save/load round-trip 24 checks, two-run determinism gate, #22 UPS gate passing: 0.58-0.67 ms Lua/tick at 500 colonists + 2000 opted-in machines, budget <1 ms). Implemented M1 issues are closed with evidence; still open: #29 (colonists leaving + real scenic/pollution inputs), #30 (hunting/fishing/salt/compost), #31 (Tool Rack entity), #36 (blueprint persistence of opt-in flag), #41 (playtest/balance).

## M1 slice (playable)
Hall -> territory (watchtowers extend it); tents/cabins hold real inventories and per-house occupant rosters (locks live on the house, not the hall); colonists loop haul/forage/chop/mine/farm (`work.lua`, `model/work_plan.lua`); harvest yield lands in the worker's hut and haulers clear it inward; axes/pickaxes/hoes wear and are delivered from the Hall; opt-in machines are supplied and emptied via the marker tool; supply crates feed the colony stock, demand crates are filled to filters, and warehouses act as bulk stock; builders revive ghosts inside territory and repair colony buildings with repair packs. Integration test: `TICKS=14000 scripts/headless-spike.sh m1_colony`. Runtime `require` is illegal: break cycles via `bind`.
