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

## Early findings from `scripts/sim.sh` (proposal params, not final)
- A 16-pop tier-1 colony needs ~1 food/colonist/interval of foraging output to hold; below that it stalls at the supply level.
- Spoilage with steady production only wastes *surplus*; shelf life (5 vs 10 min) barely matters. It will matter once transport latency/bursty hauling is modelled - add that before concluding anything about §3.1.
- Pollution above ~1.0 does not empty the colony: leaving frees housing, which raises D back above the leave threshold, so population settles at a lower equilibrium (8 of 16). Decide whether that is wanted or whether leaving needs hysteresis/"unhappy memory" (feeds #16).
- Hauling (`model/hauling.lua`, Q4/Q5): colony food supply has a **throughput cliff**: haulers needed ~= produce x round_trip / capacity. Below it, uncollected piles rot and ~95%+ is wasted while the colony starves; above it, waste = only the production surplus. Spoilage amplifies under-hauling (shelf life matters little once hauling suffices). Wait-for-full-load policy made no difference when hauler count suffices. Implication: surface hauler shortage clearly in UI; distance between producers and homes dominates; Tier 1 shelf life isn't the real constraint, hauling capacity is. (Model ignores job priority contention and path failures.)
