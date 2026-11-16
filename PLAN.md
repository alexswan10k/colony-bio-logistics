# Defect audit plan — housing / water / needs subsystem

*Planner output for the plan → implement → adversarial-review pipeline. Worktree: `audit-housing`.
No code was changed. All line references are against this worktree (HEAD).*

## Scope

Audited (pure model + thin adapter + tests/spikes):

- `mod/scripts/model/housing.lua` (tiers, `step`, `available`, `demand`, `plan`, `distribute`/`assign`)
- `mod/scripts/model/needs.lua` (`missing`, `ranked`, `wake_batch`)
- `mod/scripts/model/tower.lua`, `model/well.lua`, `model/desirability.lua`, `model/breeding.lua`
- Adapter consumption/drinking path in `mod/scripts/colony.lua` (`evaluate`, `house_stock`, `house_offer` via `work.lua`, registries, caches)
- Feedback status path `mod/scripts/feedback.lua` (`house_status`)
- Tests `tests/model_test.lua` (housing / needs / desirability blocks), `tests/glue_test.lua`
- Spikes `mod/scripts/spike/m2_tower.lua`, `m1_breed.lua`, `m1_desirability.lua`

Explicitly **out of scope**: commute/transit internals, cold chain (#45), ledger, shelter, garrison/territory except where they touch need evaluation.

## Findings

### D1 — HIGH: water-tower-fed houses still generate an endless *critical* colony-water haul request

**Evidence**

- `colony.lua:1183-1219`: each evaluation pours tower water into the house shelf, then `housing.step` (`:1222`) consumes exactly that amount, so after evaluation the house's `colony-water` shelf is **0**. `h.sat.water` is nevertheless `true` (`:1227`, from `step`).
- `work.lua:1151-1160`: `house_offer` calls `housing.plan(..., colony_mod.house_stock_cached(h), ..., h.mouths or h.occupants or 0, h.sat)`.
- `housing.lua:190-205` (`plan`): `lacking = ok == false or ok == nil or not satisfied_now(need, stock, powered)` (`:196`). With `sat.water = true` but an empty shelf, `satisfied_now` is false ⇒ `lacking` ⇒ water (a **critical** need on homestead/townhouse/apartment) sets `critical = true`.
- `housing.lua:153-182` (`demand`): even without the critical flag, `have = 0` and `have <= threshold` ⇒ a `count = target` water request is emitted (`:167-177`). So both bands request water.
- `feedback.lua:36-48` explicitly documents that "a house fed from a water tower shelf never holds its own water" and suppresses only the **UI nag** — there is no equivalent suppression in the haul planner.
- `tests/model_test.lua:1019-1024` pins the exact behaviour ("empty shelves lift the band even when the last evaluation met the need"), so this is a known rule whose interaction with towers was never tested.

**Why wrong**: the stated design (`colony.lua:1695-1696`, AGENTS #96) is "no hauler ever makes the drinking-water run" / "a town with a pump, pipes and a tank never rations its taps". In a normal game (well + hall water present) haulers will repeatedly shuttle bottled water to tower-served houses that do not need it, stealing trips from real requests. The `m2_tower` spike hides this because it deliberately keeps the hall dry (`m2_tower.lua:96-97`).

**Minimal fix**: make tower service visible to the planner. During evaluation record it (e.g. `h.tower_served = got > 0` next to `:1208-1215`, reset to `false` at the top of each house's evaluation). Add one optional trailing `skip` need-id-set argument to both `housing.plan(tier, stock, inflight, powered, occupants, sat, skip)` and `housing.demand(tier, stock, inflight, powered, occupants, force_reorder, skip)`; inside each, skip a need whose id is in `skip` (the `lacking` test at `:196` and the demand loop at `:156`). In `work.lua:1154-1155` pass `h.tower_served and {water = true}` to both. A `nil` skip keeps every existing unit test and non-tower house unchanged.

**Regression test**:
1. Unit (`tests/model_test.lua`): `h.plan(h.TIERS.homestead, {food=40, wood=40}, {}, false, 4, {food=true,water=true,heat=true}, {water=true}) == nil` and `h.demand(..., ..., ..., ..., 4, false, {water=true}).water == nil`; add the mirror assertion that without the skip set, the old critical demand still appears (pins both paths).
2. Integration (`m2_tower.lua`): keep hall water at 0 for the "no hauling" check, then add a second phase that seeds the hall with colony-water and asserts **no** supply offer for the homestead water need (or that hall water is unchanged over several evaluations while the tower serves it).

---

### D2 — MEDIUM: two disagreeing "food" lists; inedible Gleba produce is counted as colony food

**Evidence**

- `colony.lua:100-102`: `M.FOOD_ITEMS = {..., "colony-bread", "yumako", "jellynut", "bioflux", "yumako-mash", "jelly"}`.
- `housing.lua:9-12` (`M.FOOD`) contains only the colony food chain and **no** Gleba items; `step` (`:75-119`) can only consume `M.FOOD` options. `commute.lua:14-16` derives its food list from `housing.FOOD`, so the Canteen agrees with houses, not with `colony.M.FOOD_ITEMS`.
- The Gleba items have no edible consumer anywhere in `mod/` other than being a Frontier Charter ingredient (`buildings.lua:463-466`).
- `M.food_in` (`colony.lua:230-238`) and `M.total_food` (`:946-977`) iterate `M.FOOD_ITEMS`; `needs.missing` calls `api.food_in` at `needs.lua:53-57`; desirability `food_ratio` and the migration gate use `M.total_food` at `colony.lua:1372` and `:1386`.

**Why wrong**: a hall holding only yumako/jellynut is reported as "fed" — it suppresses the empty-larder promotion of food roles, inflates `food_ratio` desirability, and satisfies the `total_food > 0` migration gate, yet no colonist can eat it. This is a real logic error, not just drift (two sources of truth for "food"). It is legacy from the first M1 commit (`76e892c`) when `FOOD_ITEMS` was the original Gleba-only food set and predates the colony food chain.

**Minimal fix**: make one source of truth, e.g. `M.FOOD_ITEMS` built from `housing.FOOD` (as `commute.lua` does) — remove the six Gleba entries. If the design actually intends colonists to eat Gleba produce, the opposite fix is to *add* those items to `housing.FOOD` (a design decision, not a silent code change); either way the two lists must be derived from one table.

**Regression test**: add to `tests/model_test.lua` / `glue_test.lua`: (a) `colony.M.FOOD_ITEMS` has no item absent from `housing.FOOD` (or contains exactly `housing.FOOD` items); (b) a hall mock holding only `yumako` makes `M.food_in == 0`; (c) `needs.missing` with a hall full of yumako and empty colony-food still promotes all food roles to `empty`.

---

### D3 — MEDIUM: `needs.missing`'s "empty larder" reads only the hall, not distributed food

**Evidence**: `colony.lua:230-238` (`food_in` sums only `colony.hall`), passed straight through as `api.food_in` at `work.lua:734` → `needs.lua:53-57`. Meanwhile `M.total_food` (`colony.lua:946-977`) counts houses, crates, huts and towers.

**Why wrong**: a settled town whose food lives in house shelves/larders (the normal state after haulers deliver) reports `food_in == 0` and promotes every food role to the top "empty" band, over-prioritising foraging/farming over genuinely empty ore/wood. The emergency pantry (`colony.lua:1230-1250`) already proves central stock is only one of several stores.

**Minimal fix**: pass a food-anywhere accessor into the needs api — either use `M.total_food` for the empty-larder test, or add `api.food_available` backed by `total_food` and keep `food_in` for UI text. (Alternatively redefine "empty larder" as "no food in hall **and** no food in houses".)

**Regression test**: `needs.missing` with all colony food on house shelves (mock `food_in()==0`, `total_food()>0`) must not set `empty[job]` for food roles — only `below_target`.

---

### D4 — LOW: dead per-house stock snapshot allocated every evaluation

**Evidence**: `colony.lua:1220-1221` builds `local before = {}` by copying every key of `stock` for every house; `before` is never read again (grep confirms the only occurrences are these two lines).

**Why wrong**: pure waste on a periodic path that already runs for hundreds of houses; the #22 budget has been tight and this is an easy allocation to delete. No behaviour change.

**Minimal fix**: delete both lines.

**Regression test**: none needed (behaviour-preserving); optionally add a comment/lint assertion that the consumption block does not build unused snapshots.

---

## API verification (no defect found)

Suspicious calls were checked against the official 2.1 docs (`https://lua-api.factorio.com/latest/`), so they should **not** be "fixed":

- `tower.add_fluid(1, {name="water", amount=1000})` (`m2_tower.lua:49`) — `LuaEntity::add_fluid(index, fluid) → FluidAmount` (new). Correct signature/argument order. <https://lua-api.factorio.com/latest/classes/LuaEntity.html#add_fluid>
- `tower.get_inventory(defines.inventory.crafter_output)` (`colony.lua:1153`, `feedback.lua:45`, `m2_tower.lua:66/69/79/93`) — `defines.inventory.crafter_output` is present in 2.1 and is the modern replacement for the deprecated `assembling_machine_output`. Correct. <https://lua-api.factorio.com/latest/defines.html#defines.inventory>
- `s.on_flow(item, count)` (`stats.lua:35`) — bound-method convention already fixed; do not regress to `s.on_flow(s, item, count)`.
- Water tower drinking uses integer item counts and `LuaInventory::insert/remove/get_item_count` correctly; no renamed-defines or bound-method issue.

## Non-findings / explicitly not flagged

- **Determinism**: `plan`/`demand`/`step`/`tower.take`/`needs.ranked`/breeding growth all use `ipairs`, explicit `table.sort` or numeric tie-breaks. `desirability.compute` sums `parts` with `pairs()` (`desirability.lua:62`), but `parts` is always constructed with the same literal keys in the same order, so LuaJIT's (unrandomised) string hashing yields a stable iteration order across runs — no checksum risk in practice. Worth a note, not a defect.
- **Per-tick scans**: all house/tower/needs scans live in the scheduler-driven `colony.evaluate` (`:1432`) and use registries, not per-tick `find_entities`. `house_of_colonist`/`house_stock` are TTL-cached. Compliant.
- `needs.wake_batch` returns `first` values that can exceed `n` (`model_test.lua:898-901`), but its only consumer wraps with `% #keys` (`work.lua:489`), so no out-of-range access. Not a defect.

## Recommended ordered work list

1. **D1** — implement tower-service awareness in `housing.plan`/`housing.demand` + `work.lua`, add the unit test and the `m2_tower` second-phase test. Highest severity: directly contradicts the feature's design and wastes hauler capacity in normal play.
2. **D2** — unify the food item lists (one source of truth), add the consistency/food_in tests. Confirm with the owner whether Gleba produce is meant to be edible; default to removing inedible items from the "food" aggregate.
3. **D3** — feed a food-anywhere metric into `needs.missing`; add the distributed-food test. Closely related to D2; do after D2 so the single list is settled.
4. **D4** — delete the dead `before` snapshot in `colony.lua:1220-1221` (zero-risk cleanup).
5. Gate on `scripts/test.sh`, `scripts/lint-determinism.sh`, `luajit -bl` on changed Lua, and a determinism run (`scripts/determinism.sh`) — D1/D2/D3 change behaviour, so expect and record a new checksum if the town's trip assignment shifts.

## Risks / caveats

- **D1 fix shape**: `h.sat` is shared with `feedback`/advice; do not mutate `sat.water` itself (that would hide a real failure when the tower is empty). Pass a separate `served` set instead, and make sure the emergency-pantry fallback still runs when the tower has **no** stock (i.e. only mark served when `got > 0`). The `h.tower_served` flag must be reset to `false` at the top of each house's evaluation (before the injection block), otherwise a house whose tower ran dry one tick would stay marked served forever.
- **D1 determinism**: changing which houses request water will change haul trips and therefore the two-run checksum; this is an intended behaviour change, not a regression — document it in AGENTS.md as done for prior behaviour changes.
- **D2 intent**: I could not verify from the design docs whether Gleba produce should be edible (no mention in `docs/`); the finding is the inconsistency, and the correct direction of the fix is a design call.
- **Test-mock caveat**: `tests/mock_factorio.lua` mocks encode beliefs about engine behaviour; the API calls verified above are from the real docs, but the water-tower fluid-bottling claim itself only has the in-game `m2_tower` spike as evidence, which I did not run (headless harness requires the Steam/Factorio install).
