# Implementation report — housing / water / needs defect audit

Branch: `agent/audit-housing` · Base: `38fe643` · Spec: `PLAN.md` (D1–D4)

## Summary

| Defect | Action | Behaviour change |
|---|---|---|
| D1 — tower-fed houses emit a critical water haul request | Fixed (skip set threaded through `housing.plan`/`housing.demand`, `h.tower_served` recorded at evaluation, adapter passes the set) | Yes, in games with water towers |
| D2 — `FOOD_ITEMS` vs `housing.FOOD` disagree | **No behaviour change.** Added a FLAG test that pins and documents the divergence for the owner's design call | No |
| D3 — "empty larder" reads only the hall | Fixed via `api.food_available` (`M.total_food`), with `food_in` fallback | Yes, when hall is empty but houses/crates/huts hold food |
| D4 — dead per-house `before` snapshot | Deleted | No (pure cleanup) |

No schema change was needed: `h.tower_served` is lazy state on the existing per-house record, defaults to
nil/falsy on old saves, and is re-established on the first evaluation after load. `scripts/save-load.sh`
passes on schema 37 without a migration.

## File-by-file changes

### `mod/scripts/model/housing.lua` (pure)
- `M.demand(tier, stock, inflight, powered, occupants, force_reorder, skip)`: new optional trailing `skip`
  need-id set. A need in `skip` is ignored entirely. Renamed the pre-existing inner `skip` (powered flag) to
  `powered_ok` to avoid shadowing the new parameter; all original arithmetic and ordering untouched.
- `M.plan(tier, stock, inflight, powered, occupants, sat, skip)`: new optional trailing `skip`. Skipped needs
  are ignored both in the urgency-band test and in the demand list, and `skip` is forwarded to `M.demand`.
  `nil` keeps every existing caller and unit test byte-for-byte in behaviour.

### `mod/scripts/colony.lua` (thin adapter)
- `M.evaluate`: `h.tower_served = false` at the top of every house's evaluation (so a house whose tower ran
  dry does **not** keep its water request suppressed), set to `true` only inside the `got > 0` branch of the
  tower pour — i.e. only when water was actually served.
- Added `M.food_available(colony)` → `M.total_food(colony)`: the whole-colony food metric for the needs model.
  `food_in` is deliberately left hall-only for UI text.
- Removed the dead `local before = {}` / copy loop (D4).

### `mod/scripts/work.lua` (thin adapter)
- Module-local, never-mutated `TOWER_SERVED = {water = true}`.
- `house_offer` passes `h.tower_served and TOWER_SERVED or nil` as `housing.plan`'s new `skip` argument.

### `mod/scripts/model/needs.lua` (pure)
- `M.missing` now reads `api.food_available(colony)` for the empty-larder test, falling back to
  `api.food_in(colony)` for callers that do not supply it. `0` is truthy in Lua, so the `or` does not swallow a
  legitimate zero result. Doc comment updated.

### `mod/scripts/spike/m2_tower.lua` (integration spike)
- Phase 1 assertions now also check `hrec.tower_served == true`.
- **New phase 2** (10 ticks after the hall is seeded, i.e. several evaluations later): seed the hall with 100
  `colony-water` and assert (a) hall water is still 100 and (b) the house's own shelf still holds 0 — the tower
  serves it directly, so no hauler should make the trip.

### Tests
- `tests/model_test.lua`: D1 unit test (mirror: without skip the critical 12-water demand still appears; with
  skip both the band and the demand vanish) and D3 unit test (unlimited-quota forage is promoted only by the
  old hall-only metric, plus a check that `food_available` is the accessor actually called).
- `tests/glue_test.lua`: D2 FLAG test (documents the six inedible Gleba entries and the wrong `food_in == 100`
  consequence) and a D3 glue test proving `colony_mod.food_available` reaches from the real adapter through
  `M.total_food` to a house shelf and into `needs.missing`.

## Gate outputs (exact)

`scripts/test.sh`:
```
413 passed, 0 failed
```

`scripts/lint-determinism.sh`:
```
determinism lint ok
```

`luajit -bl` on every changed `.lua` file:
```
== mod/scripts/colony.lua          OK
== mod/scripts/model/housing.lua   OK
== mod/scripts/model/needs.lua     OK
== mod/scripts/spike/m2_tower.lua  OK
== mod/scripts/work.lua            OK
== tests/glue_test.lua             OK
== tests/model_test.lua            OK
```

`scripts/typecheck.sh` (tail):
```
Generated bundle with 1171 files
...
Running lua-language-server type verification...
Diagnosis completed, no problems found
```

`scripts/determinism.sh`:
```
== creating map
== run a: m1_colony for 19500 ticks
== run b: m1_colony for 19500 ticks
# spike m1_colony (issue #28) tick 120
SUMMARY pass=116 fail=0 unknown=0 errors=0
final checksum: 2960604716
== results in .../spike-results/20261116-195244
DETERMINISM: PASS
```

**New determinism checksum: `2960604716` — unchanged from the previous tree.** This is not a missed gate:
`m1_colony` (a) has no water towers, so D1 never fires there, and (b) keeps its hall stocked with 200
`raw-fish`, so `food_in > 0` throughout and the D3 branch never fires. D2 and D4 are behaviour-preserving.
The behaviour changes are proven by the D1/D3 unit+glue tests and the `m2_tower` phase-2 spike. No AGENTS.md
or docs edit was made (owned by the docs-hygiene worktree); the owner should reconcile the checksum entry.

`scripts/save-load.sh`:
```
[PASS] schema unchanged - 37
[PASS] house stock survived ... (and 32 other [PASS] lines)
SAVE/LOAD: PASS
```

`TICKS=19500 scripts/headless-spike.sh m2_tower`:
```
[PASS] the house is flagged tower-served (the haul planner skips its water need) - tower_served=true
[PASS] the hall never held a single colony-water the whole run (no hauling happened) - hall=0
[PASS] phase 2: hall seeded with colony-water
[PASS] hall water is untouched over several evaluations (no tower water haul) - hall=100 expected 100
[PASS] the house still holds no hauled colony-water on its own shelf - shelf=0
SUMMARY pass=18 fail=0 unknown=0 errors=0
```

`TICKS=19500 scripts/headless-spike.sh m1_colony`: `SUMMARY pass=116 fail=0 unknown=0 errors=0`.

Steam/Factorio was available (binary at `/Volumes/RTL9210/SteamLibrary/...`), so all headless gates ran.

## Adversarial check — did D1 actually stop the haul request?

I temporarily reverted only the adapter's `skip` argument (one line in `work.lua`) and re-ran `m2_tower`:

```
[FAIL] hall water is untouched over several evaluations (no tower water haul) - hall=79 expected 100
[FAIL] the house still holds no hauled colony-water on its own shelf - shelf=21
SUMMARY pass=16 fail=2 unknown=0 errors=0
```

Restoring the one line returned the spike to 18/18. So the new assertion detects the real haul, and the fix
stops it at the source (no offer is built for the water need), rather than hiding a symptom.

## D2 design call (flagged, not guessed)

Evidence is one-sided about *consumption*: `housing.step` is the only place a house eats, and it can only
consume `housing.FOOD` (colony chain items). The six Gleba items in `colony.M.FOOD_ITEMS` — `yumako`,
`jellynut`, `bioflux`, `yumako-mash`, `jelly`, plus the ordering — are only used as Frontier Charter pack
ingredients (`prototypes/buildings.lua:463-466`); they are inedible to colonists. But `FOOD_ITEMS` is also the
aggregate behind the empty-larder rule, `food_ratio` desirability and the migration gate, and the design docs
only mention "Frontier Charter recipes (forage, meat, produce, Gleba)" — never colonists eating Gleba produce.
Per the brief, since edibility intent could not be established from the docs, **I did not change behaviour**.

The options for the owner:
1. **Recommended**: derive `M.FOOD_ITEMS` from `housing.FOOD` (one source of truth, remove the six Gleba
   entries). Effect: Gleba-only halls stop reading as fed; desirability and migration react accordingly.
2. If Gleba produce *should* be colony food: add the edible items to `housing.FOOD` (a gameplay feature —
   new shelf options, new consumption/spoilage behaviour). This is a design change, not a silent fix.

Either decision must update the D2 FLAG test, which currently pins the divergent state so the choice stays
explicit.

## Deviations from PLAN.md

- **D2**: PLAN's "minimal fix" offered unification; the brief forbids guessing, so I flagged instead. No
  behaviour change. This is the one open design decision.
- **D1 shape**: PLAN suggested passing `{water = true}` to both `plan` and `demand`. I thread one `skip`
  argument through `plan`, which forwards it to `demand` — identical effect, one table at the adapter
  boundary. I also added the `tower_served` reset and the "only when `got > 0`" guard called out in Risks.
- **D1 integration test**: PLAN allowed "no supply offer ... or hall water unchanged". The supply offer is
  local to `work.lua` and not exposed to a spike, so I used hall-water-unchanged plus house-shelf-empty, and
  added the `tower_served` flag check. I also added the revert-and-re-run proof above.
- **D3 shape**: PLAN suggested using `M.total_food` for the empty-larder test; I added a thin
  `M.food_available` wrapper (keeps `food_in` for UI text) with a fallback so external model callers keep
  working. Same semantics.
- **Checksum**: PLAN expected a new checksum. It is unchanged because the deterministic `m1_colony` scenario
  does not exercise D1 or D3 (explained above).

## What the reviewer should scrutinise

1. **D1 reset timing**: `h.tower_served` is reset at the top of *each house's* evaluation and set only on a
   successful tower pour. Check the case where a tower runs dry or is destroyed mid-interval: the flag stays
   set for at most one evaluation period (600 ticks) before the house asks for hauled water again. Is that
   acceptable, or should the flag be recomputed at offer time?
2. **D1 skip breadth**: skipping water in `plan` also clears the `critical` band contribution from water. A
   tower-served house whose *food* is still critical keeps its critical band via food — confirm no other
   flow relied on water alone setting `critical` for that house (the emergency pantry at evaluation time is
   unchanged and still pulls when the tower is empty).
3. **D3 `or` fallback**: confirm `api.food_available and api.food_available(colony) or api.food_in(colony)` is
   the intended precedence and that no caller passes a `food_available` that can return `nil` for an empty but
   valid colony (it would then silently fall back to hall-only). `M.total_food` always returns a number.
4. **D3 caching**: `food_available` returns `M.total_food`'s TTL-cached value (30 ticks); a brief window where
   a freshly emptied hall still reads as "food available" is possible. Acceptable for job prioritisation?
5. **D2 flag test brittleness**: it pins the exact six-item list and `food_in == 100`. That is deliberate —
   the owner's decision must update it — but confirm this is the desired way to surface a design decision in
   a green test suite.
6. **No schema bump**: `tower_served` is a plain boolean on the house record. Save/load passes, but confirm
   there is no code that iterates house keys and would treat the new key as data (no such consumer was found).
