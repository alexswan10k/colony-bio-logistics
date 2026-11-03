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

- `TICKS=19500 scripts/headless-spike.sh m1_colony` - the playable end-to-end scenario (108 checks, final checks at
  tick 18000: haulers walk to every pickup now, so the multi-hop chains - meat to smokehouse, spoilage to compost to
  fertilized plots - need the longer window). It includes the onboarding
  path: building a Town Hall completes the Settlement milestone, every house and hut gets a status line, the hall
  workshop makes a missing tool from stock, and an untooled hut says so on its tooltip. The milestone techs are
  granted before the research queue check, so that check tests research, not onboarding.
- `scripts/headless-spike.sh m1_desirability` - the desirability inputs and leaving (19 checks): migrants
  arrive on a fed/housed site, scenic rises when trees are planted in the sampled box, `pollute()` at the
  hall pushes the pollution component to -0.60, and with D under the leave line colonists pack up - proven
  distinct from starvation by checking the death list did not grow. Needs `TICKS=4000`; it shortens
  `storage.interval_override` to 150 so evaluations do not cost 3600 ticks each.
- `scripts/headless-spike.sh s12_wildlife` - the #79 hunting spike (14 checks, `TICKS=1800`): game on its own
  force, an idle colonist that does not shoot it, a commanded hunt that kills it from range, `ev.cause` naming
  the hunter, no retaliation, and `wander` actually moving the animal. It exists because hunting is the one
  feature whose core mechanism is engine AI rather than our own loop.
- `scripts/headless-spike.sh m1_blueprint` - the #36 blueprint round-trip (26 checks): opt a furnace in and
  give a demand crate filters, `create_blueprint` the pair, tag it, build the blueprint elsewhere and
  `revive` the ghosts - the opt-in flag, `collect`, the supply rows and the crate filters all come back.
  Also covers copy-paste in both directions (an opted-in source copies its settings, a plain source clears
  the destination) and that a foreign tag on the same blueprint entity is not clobbered. `TICKS=400` is
  plenty: the spike is event-driven, not a simulation.
- `scripts/headless-spike.sh m1_rail` - the #49 passenger rail spike (17 checks, `TICKS=8000`): two colonies ~200 tiles
  apart on one rail line, a platform by each stop; colony A loses its only tent, its four colonists walk to the platform
  and wait, board the coach (riders drawn on it), and step off at B as B's colonists; nobody is lost. Migrants are
  switched off in both colonies so head counts only move by train.
- `scripts/headless-spike.sh m1_death` - the #53 permanent death spike (16 checks, `TICKS=1500`): a colonist killed by
  a biter (`LuaEntity.die("enemy", biter)`) is struck off once with cause `enemy` and a Grave where it fell; after a
  Cemetery is built a car kill (`vehicle`) is buried there instead; a coach wrecked with three riders adds three
  deaths, one removed with `destroy()` sends its two riders back to the hall; the death penalty decays at the cemetery
  half-life; any starvation in the underfed test town must balance the books too (one penalty per death).
- `scripts/headless-spike.sh m1_shelter` - the #61 civil defence spike (14 checks, `TICKS=4800`): a biter standing
  64 tiles east bites one of two colonists placed beside it (`LuaEntity.damage(10, "enemy", ...)`); one alarm goes up,
  both run for a shelter at least 24 tiles from the threat while the other six carry on, they arrive and cannot be hurt,
  the Town Hall shows the attack, and once the biter is destroyed the alarm clears and everyone is vulnerable and back
  at work. A last phase lets six biters `attack_area` the town and only logs survivors and whether the alarm rose.
- `scripts/headless-spike.sh m1_tavern` - the #48 Tavern spike (19 checks, `TICKS=5000`): haulers fill an empty
  Tavern with ale from the hall, a tent within 24 tiles is Inspired and one 30+ tiles away is not, recreation sits
  between 0 and 1 and shows in desirability, ale is consumed, the tooltip says `tavern-serving`, and once all ale is
  gone the buff clears. It clears one evaluation *after* the last ale is poured (evaluations read stock before
  consuming), so the spike waits for in-flight ale to land before stripping it.
- `scripts/headless-spike.sh m1_motor` - the #60 Motor Pool spike (26 checks, `TICKS=6000`): a pool checks a car
  out for a full hand-load with more wanted, the `colony-truck` carries 100 in one trip at 2.5x colonist speed,
  the driver waits under its stop order, the truck parks when its fuel is spent, the car goes back to the pool,
  coal is burnt by the trip count, and the driver is released off the pool afterwards.
- `scripts/save-load.sh` - builds a live colony on a headless server, saves it with `game.server_save`, then
  reloads that save in a **new process** (`--test-save ... --test-arg m1_persist_load`) and asserts every
  registry, scheduler entry, rendering and job lock came back (25 checks). Anything stored in
  `storage.persist_expected` must be plain data - a Lua object there would not survive serialisation.
  Gotchas: `server_save` only writes in multiplayer, `auto_save` is ignored in `--test-save`, `auto_save`
  and `server_save` both need `<write-data>/saves` to exist, and a dedicated server sits at tick 0 unless
  `auto_pause` is false in its server settings.
- `scripts/determinism.sh` - runs the same spike twice on the same map in separate processes and compares
  the reports *and* the final simulation checksum. This is the headless stand-in for a multiplayer desync
  test: a desync is two peers diverging on identical inputs.
  All four harnesses create their world with `--map-gen-seed "$MAP_SEED"` (default `1234567`) instead of a
  random map, so a failing spike can be re-run on the same terrain and the determinism gate compares a
  world it did not just invent. `MAP_SEED=42 scripts/headless-spike.sh m1_colony` widens coverage on demand.
- `scripts/bench-colony.sh` - the #22 UPS gate. Builds a synthetic town with `m1_bench` (colonists, cabins,
  huts, opted-in machines), saves it, then benchmarks four saves with `--benchmark --benchmark-verbose all`:
  vanilla (mod off), mod on with no colony, an "inert" control (same entities, nothing registered with the
  colony) and the town itself - both with machines that only have output and with machines that also
  request ore. Column 3 of the verbose CSV is the whole update, **column 44 is the Lua script time**, so
  the budget is read directly instead of being inferred from a delta.

  Measured on the reference Mac (500 colonists, 83 cabins, 20 huts, 2000 opted-in furnaces, 3600 ticks), run
  2026-11-03 at commit 12c0854 (`scripts/bench-colony.sh`):

  | save | total ms/tick | script ms/tick |
  |---|---|---|
  | vanilla, no mod | 0.096 | - |
  | mod on, no colony built | 0.101 | 0.002 |
  | inert control (same entities, nothing registered) | 0.201 | 0.008 |
  | colony, machines collect only | 0.557 | **0.333** |
  | colony, machines also demand ore | 0.582 | **0.357** |

  Budget is <1 ms of Lua per tick, so the gate **passes** with ~60% headroom, and "mod enabled, no colony"
  costs 2 microseconds of script time. An earlier run (before the milestone and feedback work) saw a median tick of
  0.2 ms and a p99 tail of ~8 ms from assignment bursts; the percentiles have not been re-measured since.

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

## Engine behaviour worth remembering (learned the expensive way)

Each of these cost a debugging round in a spike; check them before assuming the API behaves the obvious way.

- **`revive` returns three values**: `(items it collided with, the revived entity, the item request proxy)`.
  Assigning the call to one variable gives you the *item list*, which is truthy on success - so it looks
  like it worked and the entity is a table, not a `LuaEntity`. Use `select(2, ghost.revive{...})`.
  (`clone` returns the entity first; don't assume.)
- **2.0 methods are not all table-argument**: `copy_settings`, `die`, `damage`, `get_filter`... are declared
  `takes_table = false` and take **positional** arguments (`dst.copy_settings(src, player)`), unlike
  `revive{...}`. The API docs JSON at `lua-api.factorio.com/latest/runtime-api.json` carries
  `parameters[].format.takes_table` per method - grep it instead of guessing.
- **Blueprint tags are the only channel from a blueprint back into the world.** `BlueprintEntity.tags`
  (via `LuaItemCommon.get/set_blueprint_entity_tags`) come back as `ev.tags` on `on_built_entity`,
  `on_robot_built_entity`, `script_raised_revive` and `on_blueprint_settings_pasted`, and as `ghost.tags` on
  the ghost itself. `LuaEntity.tags` is **ghost-only** - a placed entity has no tags, so state written there
  is gone. Tags are basic Lua values, and a *sparse* table comes back with its numeric keys stringified
  (row 3 becomes `["3"]`), so serialise dense lists (`mod/scripts/model/tags.lua`).
- **A `local function` only exists after its definition**, and a nil call shows up as "attempt to call global
  'x' (a nil value)" at a *call site*, not at the definition. `work.lua`'s helpers are ordered deliberately:
  `chest_contents` sits near the top because `hut_offer` uses it, and `use_tool` sits after `item_name`.
  Moving a helper "next to the code that uses it" is how both mistakes got made.
- **Tile collision layers are named with underscores, not hyphens**: `tile.collides_with("water_tile")`, not
  `"water-tile"` (`base/prototypes/collision-layers.lua`). A tile-level probe is the planet-agnostic way to
  find water (ponds and oceans on any planet, no per-planet tile-name list to maintain), and lava tiles do not
  collide with it.
- **Units are AI, and `LuaEntity.commandable` is the only handle on them.** `commandable.set_command{type =
  defines.command.wander}` is a real "chill" order the engine carries out (measured: ~6 tiles over 8 s), and a
  colonist given `defines.command.attack` walks into its own weapon range and kills. `distraction = none` means
  "keep doing this even while being attacked", which is how docile game stays docile. Units on a force with
  `set_cease_fire` in both directions simply never fight, and a *scripted* attack still works (verified).
- **`on_entity_died` is the only link between a kill and the killer**: `ev.cause` is the entity that dealt the
  last damage (a colonist, here) and `ev.force` is the dead entity's force. Capture what you need *inside* the
  handler - reading `ev.entity` 600 ticks later raises "LuaEntity API call when LuaEntity was invalid", which
  is how the first version of `s12_wildlife` crashed.
- **`revive` refuses to place an entity where a `unit` stands**, and it does not move that unit. A colonist
  that walks to its own ghost and stops on it blocks the build forever (#76).
- **A headless server has no player and cannot make one** (`game.create_player` fails), so events that only
  fire "as a player" - `on_entity_settings_pasted` without `by_player`, `on_player_setup_blueprint` - cannot
  be exercised headlessly. Test the handler directly and say so in the report.
- **`create_blueprint` / `build_blueprint` are script paths**: they do not raise the player events, so a
  spike has to call the same helper the event handler calls (that is why `colony.tag_blueprint` takes a plain
  index -> entity table as well as a `LuaLazyLoadedValue`).
- **A train stop only connects where its rail end is**: a stop placed beside the middle of a straight run, or two
  rows off with the wrong facing, never gets `connected_rail` and the train reports no path. In `m1_rail` what worked
  was a stop touching each end of the run (west end facing west on the north side, east end facing east on the
  south side). Schedules in 2.1 still take `train.schedule = {current = 1, records = {{station = ..., wait_conditions =
  {{type = "time", ticks = 300, compare_type = "and"}}}}}` followed by `train.manual_mode = false`.
- **Trains run colonists over.** A colonist that walks across a live track dies to the train; since #53 that is a
  recorded death (`hit by a train`) like any other. Keep spike layouts off the line unless that is the test.
- **`on_entity_died` fires inside `LuaEntity.die()`**, before it returns, and the entity is invalid afterwards, so read
  `unit_number` first. Code that kills a colonist itself (starvation) strikes it off the roster before calling `die()`,
  which is how the generic handler knows not to count it again.
- **Factorio 2.1 merged a recipe's `category` / `additional_categories` into `categories`**, and a recipe that still
  sets `category` stops the game at the data stage. Leave the field out for plain crafting (the default), or use
  `categories = {...}`.
- **`LuaEntity.active` is read-only in 2.0** (the first `m1_motor` version crashed with "LuaEntity::active is
  read only"). To park a unit so it stays put, give it a long `defines.command.stop` with `ticks_to_wait` set to
  4294967295 and `distraction = none`, and clear it by issuing the next command.
- **A walker and a truck race for the same load.** A hauler on foot claims its load when it sets off, so a truck
  that claims nothing until it reaches the pool finds the source already emptied 20 at a time by the walkers,
  and comes out with nothing to carry. The truck claims its load and its car at checkout, the same moment.

## Early findings from `scripts/sim.sh` (proposal params, not final)
- A 16-pop tier-1 colony needs ~1 food/colonist/interval of foraging output to hold; below that it stalls at the supply level.
- Spoilage with steady production only wastes *surplus*; shelf life (5 vs 10 min) barely matters. It will matter once transport latency/bursty hauling is modelled - add that before concluding anything about §3.1.
- Pollution above ~1.0 does not empty the colony: leaving frees housing, which raises D back above the leave threshold, so population settles at a lower equilibrium (8 of 16). Decide whether that is wanted or whether leaving needs hysteresis/"unhappy memory" (feeds #16).
- Hauling (`model/hauling.lua`, Q4/Q5): colony food supply has a **throughput cliff**: haulers needed ~= produce x round_trip / capacity. Below it, uncollected piles rot and ~95%+ is wasted while the colony starves; above it, waste = only the production surplus. Spoilage amplifies under-hauling (shelf life matters little once hauling suffices). Wait-for-full-load policy made no difference when hauler count suffices. Implication: surface hauler shortage clearly in UI; distance between producers and homes dominates; Tier 1 shelf life isn't the real constraint, hauling capacity is. (Model ignores job priority contention and path failures.)
