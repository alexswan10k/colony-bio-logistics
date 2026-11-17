# Implementation report — housing / water / needs defect audit

Branch: `agent/audit-housing` · Base: `38fe643` · Spec: `PLAN.md` (D1–D4)

## Summary

| Defect | Action | Behaviour change |
|---|---|---|
| D1 — tower-fed houses emit a critical water haul request | Fixed (skip set threaded through `housing.plan`/`housing.demand`, `h.tower_served` recorded at evaluation, adapter passes the set) | Yes, in games with water towers |
| D2 — `FOOD_ITEMS` vs `housing.FOOD` disagree | **Fixed (owner decision):** `M.FOOD_ITEMS` is now derived from `housing.FOOD`, so the inedible Gleba entries are gone and the two lists cannot drift again | Yes, in Gleba-only colonies |
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
- **D2:** `M.FOOD_ITEMS` is now derived from `housing.FOOD` instead of a hand-maintained literal, so the
  inedible `yumako`/`jellynut`/`bioflux`/`yumako-mash`/`jelly` entries are gone and the ledger, migration gate,
  desirability and empty-larder rule all agree with what a colonist can eat.
- **Stale-flag tradeoff documented in code** at the `h.tower_served = false` reset: the flag is only recomputed
  on the evaluation cadence (600 ticks), so a tower that runs dry mid-interval leaves its water need suppressed
  for at most one interval; the next evaluation resets it and the pantry/haul offer covers the gap.
- Removed the dead `local before = {}` / copy loop (D4).

### `mod/scripts/work.lua` (thin adapter)
- `house_offer` passes `h.tower_served and housing.TOWER_SERVED or nil` as `housing.plan`'s new `skip` argument.
  The set is now shared with the GUI (see below).

### `mod/scripts/gui.lua` (thin adapter)
- **Review fix:** the household panel passes the same `h.tower_served and housing.TOWER_SERVED or nil` skip set
  to `housing.demand`, so it no longer renders a phantom `requesting [item=colony-water] 12` for a house the
  haul planner deliberately does not serve.

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
- `tests/glue_test.lua`: D2 regression test (every `FOOD_ITEMS` entry is edible, no Gleba entry is counted, a
  hall of only Gleba produce gives `food_in == 0` **and** `total_food == 0`, so the migration gate's food
  clause fails and the empty-larder rule still promotes food roles); D3 glue test (`food_available` reaches
  through `M.total_food` to a house shelf and into `needs.missing`); and a **GUI regression test** that fires
  `on_gui_opened` on a tower-served house and asserts no phantom request caption is rendered.

## Gate outputs (exact)

`scripts/test.sh`:
```
414 passed, 0 failed
```

`scripts/lint-determinism.sh`:
```
determinism lint ok
```

`luajit -bl` on every changed `.lua` file:
```
== mod/scripts/colony.lua          OK
== mod/scripts/gui.lua             OK
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
== results in .../spike-results/20261117-090052
DETERMINISM: PASS
```

**Determinism checksum after the review fixes: `2960604716` — STILL UNCHANGED.** This is not a missed gate:
`m1_colony` (a) has no water towers, so D1 never fires there; (b) keeps its hall stocked with 200 `raw-fish`,
so `food_in > 0` throughout and the D3 branch never fires; and (c) never holds Gleba produce, so removing the
inedible entries from `FOOD_ITEMS` changes no total in that scenario. D4 is behaviour-preserving. The behaviour
changes are proven by the D1/D2/D3 unit+glue tests and the `m2_tower` phase-2 spike. No AGENTS.md or docs edit
was made (owned by the docs-hygiene worktree); the owner should reconcile the checksum entry.

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

## D2 — owner decision (resolved)

The **owner decided to REMOVE** the inedible Gleba entries so the ledger/migration/desirability agree with
`housing.FOOD`. Implemented by deriving `M.FOOD_ITEMS` from `housing.FOOD` (the same pattern `commute.lua`
already uses), which removes the entries *and* makes future drift impossible.

The entries actually absent from `housing.FOOD` were **five**, not six: `yumako`, `jellynut`, `bioflux`,
`yumako-mash`, `jelly`. The audit/review both said "six" while listing five; the sixth item in the old literal
was `colony-bread`, which *is* in `housing.FOOD` and was correctly kept. The regression test asserts the
set-level invariant (every counted food is edible, no Gleba item is counted) rather than a hard-coded count.

Effect: a Gleba-only hall now has `food_in == 0` and `total_food == 0`, so the migration gate's `total_food > 0`
clause fails, desirability no longer reports "fed", and the empty-larder rule still promotes food roles. The
former FLAG test is now a real regression test covering all three consumers.

## Deviations from PLAN.md

- **D2**: PLAN's "minimal fix" offered unification; the owner has now decided on that option, so the FLAG was
  replaced with the real fix in this follow-up commit.
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

1. **D1 reset timing (accepted tradeoff, now documented in code)**: `h.tower_served` is reset at the top of
   *each house's* evaluation and set only on a successful tower pour. If a tower runs dry or is destroyed
   mid-interval the flag stays set for at most one evaluation period (600 ticks). The next evaluation resets
   it, and the emergency pantry covers the gap in the meantime, so no per-tick tower rescan is needed.
2. **D1 skip breadth**: skipping water in `plan` also clears the `critical` band contribution from water. A
   tower-served house whose *food* is still critical keeps its critical band via food — confirm no other
   flow relied on water alone setting `critical` for that house (the emergency pantry at evaluation time is
   unchanged and still pulls when the tower is empty).
3. **D3 `or` fallback**: confirm `api.food_available and api.food_available(colony) or api.food_in(colony)` is
   the intended precedence and that no caller passes a `food_available` that can return `nil` for an empty but
   valid colony (it would then silently fall back to hall-only). `M.total_food` always returns a number.
4. **D3 caching**: `food_available` returns `M.total_food`'s TTL-cached value (30 ticks); a brief window where
   a freshly emptied hall still reads as "food available" is possible. Acceptable for job prioritisation?
5. **D2 list derivation**: confirm deriving `M.FOOD_ITEMS` from `housing.FOOD` is safe for every consumer.
   All uses in `colony.lua` are `ipairs` summation/counting (`food_in`, `total_food`, crates/towers/huts), so
   the different item order cannot change a result; `commute.lua` already derives its list the same way.
6. **No schema bump**: `tower_served` is a plain boolean on the house record. Save/load passes, but confirm
   there is no code that iterates house keys and would treat the new key as data (no such consumer was found).

## Review fixes (second commit, against `REVIEW.md`)

All three review items are resolved:

1. **MAJOR — D2 resolved by owner decision.** `colony.M.FOOD_ITEMS` is now derived from `housing.FOOD`; the
   inedible Gleba entries are gone. The former FLAG test in `tests/glue_test.lua` was rewritten as a real
   regression test: it asserts (a) every counted food is edible, (b) no Gleba item is in the aggregate,
   (c) a hall holding only Gleba produce gives `food_in == 0` and `total_food == 0`, so the migration gate's
   `total_food > 0` clause is false, and (d) the empty-larder rule still promotes food roles on such stock.
   The count discrepancy is noted above: five entries actually differed, not six.
2. **MINOR — GUI phantom request fixed.** `gui.fill_house` now passes the same skip set as the haul planner.
   The shared `housing.TOWER_SERVED` constant replaced the duplicate literal in `work.lua`, so the two readers
   cannot diverge again. A new glue test drives `on_gui_opened` on a tower-served house and asserts the panel
   renders `fully-stocked` and no `requesting` caption.
3. **MINOR — stale-flag tradeoff documented** in a code comment at the `h.tower_served = false` reset in
   `colony.evaluate` (up to one 600-tick interval, then re-evaluated; no per-tick tower rescan).

The review's test-hygiene question about `prototypes.item` is answered: `mock.install()` assigns a fresh
`_G.prototypes = {technology = {}, item = {}}` on every call and `env.reset()` calls `install()`, so the D2
test's prototypes cannot leak into later tests.

### Mutation checks (each fix reverted independently, then restored)

| Reverted fix | Test that failed | Observed |
|---|---|---|
| D2: restore the old `FOOD_ITEMS` literal with the Gleba entries | `D2: inedible Gleba produce is not colony food...` | `yumako is counted as food but no house can eat it (got nil)` |
| GUI: drop the skip argument in `gui.lua` | `D1 GUI: a tower-served house panel shows no phantom water request` | `a served house with full shelves needs nothing (got nil)` |

After restoring both lines, `scripts/test.sh` returned to `414 passed, 0 failed`. The earlier D1 mutation
proof (reverting `work.lua`'s skip makes `m2_tower` phase 2 fail with `hall=79, shelf=21`) is unchanged.

### Re-run gates after the review fixes

`scripts/test.sh` → `414 passed, 0 failed` · `scripts/lint-determinism.sh` → `determinism lint ok` ·
`luajit -bl` on 7 changed files → all `OK` · `scripts/typecheck.sh` → `Diagnosis completed, no problems found` ·
`scripts/determinism.sh` → `PASS`, checksum `2960604716` (**did not move**, reason above) ·
`scripts/save-load.sh` → `PASS` · `TICKS=19500 scripts/headless-spike.sh m2_tower` → `SUMMARY pass=18 fail=0` ·
`TICKS=19500 scripts/headless-spike.sh m1_colony` → `SUMMARY pass=116 fail=0`.

Steam/Factorio was available, so all headless gates ran. No AGENTS.md, design doc or `docs/` file was touched.
