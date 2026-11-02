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
- `scripts/headless-spike.sh m1_desirability` - the desirability inputs and leaving (19 checks): migrants
  arrive on a fed/housed site, scenic rises when trees are planted in the sampled box, `pollute()` at the
  hall pushes the pollution component to -0.60, and with D under the leave line colonists pack up - proven
  distinct from starvation by checking the death list did not grow. Needs `TICKS=4000`; it shortens
  `storage.interval_override` to 150 so evaluations do not cost 3600 ticks each.
- `scripts/save-load.sh` - builds a live colony on a headless server, saves it with `game.server_save`, then
  reloads that save in a **new process** (`--test-save ... --test-arg m1_persist_load`) and asserts every
  registry, scheduler entry, rendering and job lock came back (24 checks). Anything stored in
  `storage.persist_expected` must be plain data - a Lua object there would not survive serialisation.
  Gotchas: `server_save` only writes in multiplayer, `auto_save` is ignored in `--test-save`, `auto_save`
  and `server_save` both need `<write-data>/saves` to exist, and a dedicated server sits at tick 0 unless
  `auto_pause` is false in its server settings.
- `scripts/determinism.sh` - runs the same spike twice on the same map in separate processes and compares
  the reports *and* the final simulation checksum. This is the headless stand-in for a multiplayer desync
  test: a desync is two peers diverging on identical inputs.
- `scripts/bench-colony.sh` - the #22 UPS gate. Builds a synthetic town with `m1_bench` (colonists, cabins,
  huts, opted-in machines), saves it, then benchmarks four saves with `--benchmark --benchmark-verbose all`:
  vanilla (mod off), mod on with no colony, an "inert" control (same entities, nothing registered with the
  colony) and the town itself - both with machines that only have output and with machines that also
  request ore. Column 3 of the verbose CSV is the whole update, **column 44 is the Lua script time**, so
  the budget is read directly instead of being inferred from a delta.

  Measured on the reference Mac (500 colonists, 40 cabins, 17 huts, 2000 opted-in furnaces, 1800 ticks):

  | save | total ms/tick | script ms/tick |
  |---|---|---|
  | vanilla, no mod | 0.108 | - |
  | mod on, no colony built | 0.107 | 0.001 |
  | inert control (same entities, nothing registered) | 0.201 | 0.002 |
  | colony, machines collect only | 0.797 | **0.579** |
  | colony, machines also demand ore | 0.895 | **0.671** |

  Budget is <1 ms of Lua per tick, so the gate **passes** with ~30% headroom, and "mod enabled, no colony"
  costs 1 microsecond. Median tick is 0.2 ms; a tail of ~8 ms remains at the p99, from assignment bursts.

  To attribute a budget miss, short-circuit a function (e.g. make `M.assign` return immediately), re-copy
  the mod into `build/bench/mods` and re-run the two `--benchmark` passes; the drop is that function's cost.
  `LuaProfiler` cannot be read as a number from Lua (only displayed as a localised string), so the
  short-circuit delta is the practical profiler here.

  How it got there (#75, measured with the same harness): the haul planner used to read every opted-in
  machine's inventory on every assignment (`4.97 ms` at 2000 machines, and `17.3 ms` once those machines
  actually had requests). Now a slice sweep visits 1/10 of the registry every 30 ticks and caches
  `has_output` / `need` / `damaged` on each machine, assignment looks at a 16-machine window rotated by a
  cursor, and population / food / stock are cached with a short TTL instead of being recomputed per
  assignment. `construct.scan` also used to read health for every machine every 300 ticks (a 13 ms tick).

## Early findings from `scripts/sim.sh` (proposal params, not final)
- A 16-pop tier-1 colony needs ~1 food/colonist/interval of foraging output to hold; below that it stalls at the supply level.
- Spoilage with steady production only wastes *surplus*; shelf life (5 vs 10 min) barely matters. It will matter once transport latency/bursty hauling is modelled - add that before concluding anything about §3.1.
- Pollution above ~1.0 does not empty the colony: leaving frees housing, which raises D back above the leave threshold, so population settles at a lower equilibrium (8 of 16). Decide whether that is wanted or whether leaving needs hysteresis/"unhappy memory" (feeds #16).
- Hauling (`model/hauling.lua`, Q4/Q5): colony food supply has a **throughput cliff**: haulers needed ~= produce x round_trip / capacity. Below it, uncollected piles rot and ~95%+ is wasted while the colony starves; above it, waste = only the production surplus. Spoilage amplifies under-hauling (shelf life matters little once hauling suffices). Wait-for-full-load policy made no difference when hauler count suffices. Implication: surface hauler shortage clearly in UI; distance between producers and homes dominates; Tier 1 shelf life isn't the real constraint, hauling capacity is. (Model ignores job priority contention and path failures.)
