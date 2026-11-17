# Stage 1 — Militia job, unit prototype, damage simulation and armour (#55)

Branch `agent/defence-stack`. Base: Stage 0 (`6dd69b3`, `s19_defence`) on master `90e210d`.
Schema **unchanged at 38** (no new registry — gear lives in nil-safe `unit_state` fields, as Stage 0 advised).
Determinism checksum re-baselined **328728317 → 3400134649** (new `colony-militia` prototype changes Factorio's
prototype-table hash; existing-town behaviour is unchanged — `m1_colony` still 116/116 with the same checks).

## File-by-file changes

### New pure models (no Factorio globals, no input mutation)
- `mod/scripts/model/armour.lua` — `ARMOUR` tier table (vanilla armour item names), string-keyed `QUALITY`
  multipliers, clamped `mitigation(kind, quality_name)`, deterministic `best(counts, quality_by_item)`, `tier`.
- `mod/scripts/model/militia.lua` — `PREFERENCE` re-exported from `garrison`; static `WEAPONS` table
  (damage / type / ammo / wear / pierce); `outgoing`, `engage`, `best_gear`, `gear_wanted`, `spend`. All pure.

### New prototype
- `mod/prototypes/militia.lua` — `colony-militia`, a deepcopy of `colony-colonist` with **explicit
  `is_military_target = true`**, `allow_run_time_change_of_is_military_target = false`,
  `ai_settings.destroy_when_commands_fail = false`, and the native hitscan damage reduced to a **1-damage
  baseline** so engine + script damage do not double-count. Required from `mod/data.lua`.

### New adapter
- `mod/scripts/militia.lua` — bound via `M.bind` (no runtime `require` cycle). `spawn`, `convert`, `assign`,
  `issue_gear` (draw weapon/armour from the Town Hall into pure-data `st.gear`, quality read from the live
  stack as a string); `militia.scan` / `militia.strike` schedulers (event/timer-driven, no per-tick scan);
  `target.damage(damage, force, type, source, cause)` on a confirmed in-range engagement; heal-back mitigation
  on `on_entity_damaged` (clamped, never revives a unit killed by the engine); `release_claim` whistle hook.

### Wiring / integrations
- `mod/scripts/colony.lua` — requires `militia` + `command`; binds `militia`, `work.bind_militia`,
  `command.bind_militia` at the existing bind site.
- `mod/scripts/work.lua` — `M.bind_militia`, `militia` label, delegation in `work.assign` **after** the night
  block (militia sleep like guards), militia states excluded from the generic failed-command release, gear
  carried into the `to_bed` state.
- `mod/scripts/command.lua` — preserves `intents.gear` into the lease state and back on release; calls
  `militia.release_claim` when a whistle preempts a militia.
- `mod/scripts/model/command.lua` — militia states in `ORDERABLE`; `abort_intents` carries `gear` and sets
  `release_gear_claim`.
- `mod/scripts/model/alarm.lua` — militia states in `EXEMPT` (they fight, not hide).
- `mod/scripts/mortality.lua` — `colony-militia` added to the colonist-name set so a militia death is
  recorded **once** through the existing handler (name-aware death message).
- `mod/scripts/model/jobs.lua` — `militia` is a separate rank-2 job in `JOBS`/`DEFAULT`.
- `mod/scripts/gui.lua` — militia in the per-house lock dropdown, workforce table and job matrix (which is
  generated from `jobs.JOBS`).
- `mod/scripts/feedback.lua` — militia excluded from hut site-count logic.
- `mod/locale/en/locale.cfg` — `entity-name.colony-militia`, `job-militia`, `lock-militia`, `jobs` line.

### Tests / spike
- `tests/militia_test.lua` — 17 tests: armour tiers/quality/clamp/ties, weapon damage/type/ammo/quality,
  `engage` (piercing is offensive, mitigation is never subtracted twice), `best_gear`, `gear_wanted`
  (no input mutation), `spend`, job registration, alarm/command exemption, whistle gear carry.
- `mod/scripts/spike/m3_militia.lua` (+ `loader.lua`) — 16-check integration spike.

## What the Stage 0 spike facts forced

1. **No armour inventory / grid / resistances on a unit** → armour is pure data in `st.gear` with a scripted
   heal-back on `on_entity_damaged`; no schema bump (nil-safe `unit_state` fields).
2. **`is_military_target` is prototype-level only** → a distinct `colony-militia` prototype with the value set
   explicitly (true). This is also why the checksum moved.
3. **Runtime AI field is `allow_destroy_when_commands_fail`** → the prototype sets the data-side
   `destroy_when_commands_fail = false`; a probe in `m3_militia` reads the runtime field back (`false`).
4. **`damage()` applies resistances itself and returns damage actually applied** → the pure model returns the
   raw scripted damage; no second resistance subtraction. The native hitscan is 1 damage to avoid
   double-counting.
5. **Quality is a string** → read from the live item stack as a string and stored in gear; never `.quality.name`
   on an `ItemWithQualityCount`.
6. **`damage()` argument count** → dot form with all five params (`damage, force, type, source, cause`); colon
   form would pass a sixth `self` and is rejected by the engine.
7. **Direct `entity.health = max` makes `damage()` a no-op until next tick** (empirical, this binary) → the
   spike never pre-heals before a scripted hit; the heal-back handler never revives a unit taken to 0 health.

## Gate outputs (exact)

| Gate | Result |
|---|---|
| `scripts/test.sh` | `484 passed, 0 failed` |
| `scripts/lint-determinism.sh` | `determinism lint ok` |
| `luajit -bl` (16 changed Lua files) | all `OK` |
| `scripts/typecheck.sh` | `Diagnosis completed, no problems found` |
| `scripts/save-load.sh` | `SAVE/LOAD: PASS` (schema 38, unchanged) |
| `scripts/determinism.sh` run 1 | `DETERMINISM: PASS`, checksum **3400134649**, m1_colony 116/116 |
| `scripts/determinism.sh` run 2 | `DETERMINISM: PASS`, checksum **3400134649** (stable) |
| `scripts/headless-spike.sh m3_militia` | `SUMMARY pass=16 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_garrison` | `SUMMARY pass=18 fail=0 unknown=0 errors=0` |
| `TICKS=19500 scripts/headless-spike.sh m1_colony` | `SUMMARY pass=116 fail=0 unknown=0 errors=0` |
| `scripts/bench-colony.sh` | worst colony Lua **0.594 ms/tick** (500 colonists, 2000 machines), budget <1.00 → **PASS** |

## New checksum and attribution

- Old (Stage 0 / base): **328728317**.
- New (Stage 1): **3400134649**, reproduced identically on two consecutive `scripts/determinism.sh` runs.
- Attribution: the new `colony-militia` **prototype** changes Factorio's prototype-table hash. No existing-town
  behaviour changed: `m1_colony` passes the same 116 checks and the working-town UPS figure is unchanged
  (~0.55-0.59 ms/tick). Militia code is inert in towns with no militia.

## Deviations from PLAN.md

- **No schema bump [39].** PLAN made it conditional ("if a registry is added"). Gear is nil-safe fields on
  `unit_state`, so no `colony.militia` registry and no `store.lua` migration — the preferred option in PLAN §3.
- **Gear is drawn directly from the Town Hall, not via a new haul band.** `model/militia.gear_wanted` is
  implemented and unit-tested as the pure feedstock heuristic for Stage 2, but Stage 1 does not emit a haul
  offer: the militia draws weapon/armour out of hall stock atomically at assignment and spends ammo out of hall
  stock at each engagement. That sidesteps the #56 "never source from the requester's own stock" rule by making
  the militia's source the hall, never itself; the dedicated Armory haul path is Stage 2's job. A militia has no
  inventory, so a hauler could not deliver into it anyway.
- **No new tech / item / GUI building.** PLAN's Stage 1 lists none; the prototype reuses the colonist art and
  the rifle/pistol/bow/armour are existing items.
- **Militia staffing is via the per-house job lock and the existing job matrix** (delegated from `work.assign`),
  not through a labour hut. With no Stage 1 building there are no hut slots; the lock is the opt-in control.
  `work_plan.choose` gains the rank-2 entry in `jobs` but no hut-derived slots, so a militia is only created when
  the player locks a colonist (or a Stage 2 Armory supplies slots).

## What the adversarial reviewer should scrutinise

1. **Double-count damage.** The militia hitscan is 1 damage; `engage` returns raw script damage and never
   subtracts engine resistances. `engage`'s only use of the defender is an *offensive* pierce bonus (extra script
   damage), separate from the defender's heal-back mitigation. Verify no path applies both an engine and a
   script mitigation to the same hit, and that a hunter's `on_entity_damaged` +15 bonus (`work.lua`) cannot fire
   on a militia (its cause check is `colony-colonist`, not `colony-militia`).
2. **Heal-back correctness.** `scripts/militia.lua` heals `min(applied * mitigation, max_health - hp)` and
   returns when `hp <= 0` (never revive). Check the clamp against `final_damage_amount` vs
   `original_damage_amount` on 2.1, and that setting `entity.health` does not recurse (it does not raise
   `on_entity_damaged`). Confirm an armoured militia loses less than an unarmoured one (spike check 3).
3. **Gear loss on whistle release.** `abort_intents` carries `st.gear` into the lease; `command.lua` writes it
   into the new state on order and on release; `work.assign` carries it through the `to_bed` night state.
   `militia.release_claim` clears a stale engagement target on preemption. Check every state replacement
   (`command.plan`, `release_lease`, sleep, `militia.assign`) preserves gear, and that no two militia consume the
   same physical item (issue removes from hall; ammo removal is atomic).
4. **Garrison gear starvation.** Militia draw from the **hall**, while garrison rifles live in the **tower**
   stock room, so militia do not consume a posted tower's weapons. But both compete for rifles still in the hall
   before haulers move them to a manned tower. Stage 2's Armory must de-duplicate these pools. Verify
   `m1_garrison` stays green (18/18 here) and that raising a tower limit still gets rifles before a militia can
   strip the hall.
5. **Conversion edge cases.** `militia.convert` migrates per-unit storage keys (state, locks, labels, carry
   sprites, sick, age, away) to a new unit number and destroys the old entity. It does **not** migrate
   `storage.command.leased/selection/owner` or commuter/bookings — an edge case if a player whistles a colonist
   exactly as it is locked to militia. Reviewer should decide whether to forbid conversion while commanded.
6. **Determinism of scan jitter.** `m3_militia` forces both militia to scan immediately after spawning the
   biter; without that, the per-unit jitter can let one militia kill the target before the other scans, making
   the wear assertion flaky. The game itself is fine (a real militia scans on its own timer), but the spike's
   determinism depends on the forced scan.
