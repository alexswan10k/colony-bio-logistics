# AGENTS.md
Factorio 2.0 + Space Age (hard dep) colony mod. Design: `docs/factorio_colony_mod_design_document.md`. Work tracked in GitHub issues/milestones (M0 spikes+decisions gate M1-M4). Repo: alexswan10k/colony-bio-logistics. Owner uses macOS + Steam. API docs: https://lua-api.factorio.com/latest/ (always verify 2.0 signatures here).

## Layout
`mod/` mod (Lua 5.2 runtime) · `mod/scripts/model/` PURE logic · `mod/scripts/spike/` dev-only API spikes · `tests/` · `sim/` balance · `scripts/` tooling · `docs/` (SPIKES, TESTING, DEPLOYMENT, ART) · `spike-results/` run reports.

## Commands
`scripts/test.sh [filter]` unit tests (luajit) · `scripts/sim.sh` balance tables · `scripts/lint-determinism.sh` · `scripts/link-dev.sh` symlink into Factorio mods · `scripts/package.sh [--release]` · `scripts/headless-spike.sh <spike[:args]>` · `scripts/collect-results.sh` + `scripts/post-results.sh <report>` · `scripts/benchmark.sh <save>`.
Always run test.sh + lint-determinism.sh + `luajit -bl` on changed Lua before committing. Commit and push after changes.

## Rules
- Game rules go in `model/` with NO Factorio globals (`game/storage/script/defines/surface`); in-game code is a thin adapter. Test models offline; engine behaviour only via in-game spikes. Mocks encode beliefs, not evidence.
- Factorio 2.0 Lua API: Reference https://lua-api.factorio.com/latest/ for exact classes, parameters, and signatures.
- Lua 5.2: no `|`, `&`, `//`, `goto` ok. No `math.random`/`os`/`io` outside spikes (use `game.create_random_generator`). Never store functions in `storage`. Register events via `scripts.events` at load time only. Schema changes need a `store.lua` migration.
- Do not edit vanilla prototypes (opt-in design pillar). Don't scan entities per tick; use registries + `scheduler`.
- Spike/decision outcomes: record on the GitHub issue (comment + close), update docs/design doc if the design changes. Track progress via `gh issue` and project milestones.

## Decisions made
Territory = chunk-granular 32x32 (#15). Space Age required (#12). Open: #16-#22 (desirability, individuality, housing, science, disease, tourism, perf budget).

## Status
M0 in progress: spikes #1-#11 coded, unrun. First action when Factorio is installed: `scripts/link-dev.sh`, follow `docs/SPIKES.md` order, post results, fix harness errors.

## M1 slice (playable)
Hall -> territory; houses (`model/housing.lua` tiers+needs; power substitutes fuel via hidden `colony-power-sink`) hold real inventories; colonists loop haul/forage/chop/mine (`work.lua`, `model/work_plan.lua`); axes/pickaxes wear (hall/rack supply). Integration test: `TICKS=7000 scripts/headless-spike.sh m1_colony`. Runtime `require` is illegal: break cycles via `bind`.
