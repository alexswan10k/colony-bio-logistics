# Testing without running Factorio

`brew install luajit`, then:
- `scripts/test.sh [filter]` - unit tests (`tests/*_test.lua`, tiny built-in runner, no dependencies). Runs in CI.
- `scripts/sim.sh` - balance explorer (`sim/balance.lua`): prints tables for design questions.

## Three layers
1. **Pure models** (`mod/scripts/model/`): desirability, spoilage, job priority, colony step. **Rule: no `game`, `storage`, `script`, `defines`, `surface` in here.** In-game code becomes a thin adapter that reads the world into plain tables, calls the model, and applies results. This is what makes ideas testable offline, and it keeps game-API risk (the spikes) separated from game-rule risk (the models).
2. **Mock Factorio API** (`tests/mock_factorio.lua`): fake `storage`, `game.tick`, `script.on_event`, so the real glue modules (events, store migrations, scheduler, territory index) run under test. `env.tick(n)` advances time, `env.fire(event, data)` raises events, `env.reset()` reloads modules. Extend the mock only as far as a test needs it.
3. **Headless simulation** (`sim/`): run models for thousands of steps and print results; use to settle decisions #16-#22 with numbers before building.

## What this can and cannot tell you
- CAN: game-rule logic, balance theories, migration/starvation dynamics, scheduler/registry correctness, storage migrations, determinism.
- CANNOT: whether a Factorio API behaves as assumed (unit pathing, `gui.relative`, blueprint tags, spoilage on item-with-tags...) - that is what the in-game spikes in `docs/SPIKES.md` are for. Mocks encode *our beliefs* about the API; never treat a passing mock test as evidence about the engine.

## Adding a theory
1. Put the rule in `mod/scripts/model/<x>.lua` (pure). 2. Add `describe/it` in `tests/model_test.lua` stating the expected behaviour. 3. Add a table to `sim/balance.lua` if it is a tuning question. 4. Record the numbers in the decision issue.

## Regression gates (#39)
Three headless gates cover the things the unit tests and the playable spike cannot:

- `scripts/headless-spike.sh m1_colony` - the playable end-to-end scenario (53 checks).
- `scripts/save-load.sh` - builds a live colony on a headless server, saves it with `game.server_save`, then
  reloads that save in a **new process** (`--test-save ... --test-arg m1_persist_load`) and asserts every
  registry, scheduler entry, rendering and job lock came back (24 checks). Anything stored in
  `storage.persist_expected` must be plain data - a Lua object there would not survive serialisation.
  Gotchas: `server_save` only writes in multiplayer, `auto_save` is ignored in `--test-save`, `auto_save`
  and `server_save` both need `<write-data>/saves` to exist, and a dedicated server sits at tick 0 unless
  `auto_pause` is false in its server settings.
- `scripts/determinism.sh` - runs the same spike twice on the same map in separate processes and compares
  the reports *and* the final simulation checksum. This is the headless stand-in for a multiplayer desync
  test: a desync is two peers diverging on identical inputs. `m1_colony` (14000 ticks) currently produces
  checksum `3313452784` on both runs.
- `scripts/bench-colony.sh` - the #22 UPS gate. Builds a synthetic town with `m1_bench` (colonists, cabins,
  huts, opted-in machines), saves it, then benchmarks three saves with `--benchmark`: vanilla (mod off),
  mod on with no colony, and the town. An "inert" control (same entities, nothing registered with the
  colony) separates the engine cost of the town from our Lua.

  Measured on the reference Mac (500 colonists, 40 cabins, 17 huts, 2000 opted-in furnaces, 1800 ticks):

  | save | ms/tick |
  |---|---|
  | vanilla, no mod | 0.098 |
  | mod on, no colony built | 0.107 |
  | inert control (same entities, nothing registered) | 0.190 |
  | colony | 5.159 |

  So "no colony built" costs 9 microseconds per tick, but the colony layer at target scale is **~5 ms**,
  against the #22 budget of <1 ms. With machines set to 0 the layer is 1.10 ms, i.e. the per-assignment
  sweep over every opted-in machine is ~3.9 ms of it. Fixing that (offer index / round-robin sweep) is the
  remaining M1 performance work.

## Early findings from `scripts/sim.sh` (proposal params, not final)
- A 16-pop tier-1 colony needs ~1 food/colonist/interval of foraging output to hold; below that it stalls at the supply level.
- Spoilage with steady production only wastes *surplus*; shelf life (5 vs 10 min) barely matters. It will matter once transport latency/bursty hauling is modelled - add that before concluding anything about §3.1.
- Pollution above ~1.0 does not empty the colony: leaving frees housing, which raises D back above the leave threshold, so population settles at a lower equilibrium (8 of 16). Decide whether that is wanted or whether leaving needs hysteresis/"unhappy memory" (feeds #16).
- Hauling (`model/hauling.lua`, Q4/Q5): colony food supply has a **throughput cliff**: haulers needed ~= produce x round_trip / capacity. Below it, uncollected piles rot and ~95%+ is wasted while the colony starves; above it, waste = only the production surplus. Spoilage amplifies under-hauling (shelf life matters little once hauling suffices). Wait-for-full-load policy made no difference when hauler count suffices. Implication: surface hauler shortage clearly in UI; distance between producers and homes dominates; Tier 1 shelf life isn't the real constraint, hauling capacity is. (Model ignores job priority contention and path failures.)
