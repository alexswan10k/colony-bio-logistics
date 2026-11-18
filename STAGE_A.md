# Stage A — research-speed half of Inspired (#48), review fixes

Branch `agent/m2-recreation`. Base `master 1fe97bc`; first pass `ac8af36` was rejected by REVIEW.md; this
document describes the corrected state. Slice A of PLAN.md only: no Theatres, no plaza, no new prototypes.
Owner decision stands: use the force-wide `force.laboratory_speed_modifier`, self-healed from a cache written
at evaluation time, accepting the side effect on vanilla labs. No `research_progress` credits.

## Fixes to REVIEW.md findings

| Finding | Fix |
|---|---|
| **C1 CRITICAL** — cold load subtracted the *new* target from a live modifier that still held the *old* bonus, leaving a permanent force-wide buff when inspiration changed before the first post-load evaluation | The applied bonus is now **durable**: `storage.research_speed[force_name] = {base, applied}` (schema 44). `write()` derives the engine value from the **saved** `base` + the current target; it never derives `base` from the live value when a record exists. A new Lua state keeps `storage` but loses module locals, so the cold path is now exact. Three unit tests simulate a cold load (`package.loaded` cleared, `storage` retained) with target dropped to 0, target lowered to 0.125, and a foreign base retained. |
| **M1 MAJOR** — foreign non-zero base at cold start absorbed our bonus forever | On the first ever write for a force (no saved record), `base = live` because we have never touched that modifier; the bonus is **added** on top. A warm foreign write is detected by `live ~= base + applied` and folded into `base` without absorbing our own bonus. Unit test pins `0.4 -> 0.65`; a "cold load with a foreign base and target 0" test pins `0.65 -> 0.4`. |
| **M2 MAJOR** — last hall destroyed skipped the only `apply` call | `M.evaluate`'s dormant-hall early return now calls `research_speed.apply_all()`, which sweeps the forces with saved records; `target_for` ignores invalid halls, so the bonus drops to 0. Unit test drives the **real `colony.evaluate`** with an invalid hall; another pins `apply_all` leaving untouched forces alone. |
| **m1 MINOR** — sheltered scholars counted as on duty | `compute_inspiration` now excludes `to_shelter`, `sheltered` and `exposed` in addition to `sleeping`/`to_bed` and night. Unit test flips scholars into each state and asserts share 0. |
| **m2 MINOR** — s20's 2× assertion was too weak | Now requires both windows to progress and `rate1 / rate0` in `[1.9, 2.1]`; report includes the ratio. Measured `rate0=0.030000 rate1=0.060000 ratio=2.0000`. |

No module-local cache remains — `research_speed.lua` is stateless apart from the load-time event handler. No
per-tick scan, no new event beyond `on_technology_effects_reset`, max-combine unchanged.

## Changes (full set)

| File | What |
|---|---|
| `mod/scripts/model/inspiration.lua` (new, PURE, unchanged from first pass) | `RESEARCH_MAX = 0.5`, `TAVERN = 1.25`, `THEATRE = 1.5` (slice B ready), `QUALITY`, `research_bonus(share, quality) = clamp((quality-1)*share, 0, 0.5)`, generalized `work_ticks`. nil/NaN → 0. |
| `mod/scripts/research_speed.lua` (new adapter, rewritten) | Durable per-force record in `storage.research_speed`; `apply(force)`, `apply_all()` for dormant colonies, immediate self-heal on `on_technology_effects_reset`. Skips creating a record for a Tavern-less, untouched town so the determinism checksum does not move. |
| `mod/scripts/store.lua` | `SCHEMA = 44`, migration 44 creates `storage.research_speed`. Migrations 42 and 43 are reserved no-ops for the other in-flight M2 slices (owner assigned 44 to avoid collision). |
| `mod/scripts/colony.lua` | `serve_taverns` also writes derived `house.inspiration_quality`; `compute_inspiration` derives `colony.inspiration` once per evaluation from the sorted housing roster (on-duty scholars, now excluding shelter states); `inspiration_quality(colony, un)` added, `is_inspired` delegates to it (boolean API unchanged); `research_speed.apply` at evaluation end **and** `research_speed.apply_all` on the dormant-hall early return. |
| `mod/scripts/spike/s20_inspired_research.lua` (new) + `spike/loader.lua` | 13-check headless spike: exact modifier value, reset self-heal, ale-strip/tavern-removal reset, and a strict 2× research-rate check. |
| `tests/inspiration_test.lua`, `tests/research_speed_test.lua` (new) / `tests/glue_test.lua` (schema expectations updated to 44) | Pure rule; adapter durable/load-safe behaviour incl. all three CRITICAL/MAJOR mutations; real `evaluate()` dormant path; shelter exclusion. |

No new prototypes, no locale keys. `colony.inspiration` / `house.inspiration_quality` are derived nil-safe
fields; `storage.research_speed` is the only new saved table.

## Engine facts (Factorio runtime docs 2.1.25, verified 2026-11-18)

* `LuaForce::laboratory_speed_modifier` is a **read/write double**, force-wide
  — https://lua-api.factorio.com/latest/classes/LuaForce.html#laboratory_speed_modifier
* `0` = normal, `1` = double, `-0.5` = half — https://wiki.factorio.com/console
* Research is engine-driven while a lab is powered and stocked (proved by `s13_science`); Lua trip timers
  do not change research, hence the engine modifier.
* `LuaForce::reset_technology_effects()` discards script modifiers and raises `on_technology_effects_reset`
  with `force` — https://lua-api.factorio.com/latest/classes/LuaForce.html#reset_technology_effects and
  https://lua-api.factorio.com/latest/events.html#on_technology_effects_reset
* `storage` survives save/load; module-local Lua values do not. The durable record is the load-safe mechanism
  that replaces the rejected module-local-cache derivation.
* `s20` measurement: 180 ticks at modifier 0 → progress 0.030; at modifier 1 → 0.060 (ratio 2.0000).

## Gate outputs (exact, after all fixes)

```
$ scripts/test.sh
530 passed, 0 failed

$ scripts/lint-determinism.sh
determinism lint ok

$ luajit -bl (changed Lua)
OK mod/scripts/store.lua
OK mod/scripts/research_speed.lua
OK mod/scripts/colony.lua
OK mod/scripts/spike/s20_inspired_research.lua
OK tests/research_speed_test.lua
OK tests/glue_test.lua

$ scripts/typecheck.sh
... Factorio type definitions already present ...
Diagnosis completed, no problems found

$ TICKS=5000 scripts/headless-spike.sh s20_inspired_research
SUMMARY pass=13 fail=0 unknown=0 errors=0
[PASS] force lab modifier = 1 doubles research progress (ratio within 1.9..2.1) - rate0=0.030000 rate1=0.060000 ratio=2.0000

$ TICKS=5000 scripts/headless-spike.sh m1_tavern
SUMMARY pass=19 fail=0 unknown=0 errors=0

$ TICKS=19500 scripts/headless-spike.sh m1_colony
SUMMARY pass=116 fail=0 unknown=0 errors=0

$ scripts/save-load.sh
SAVE/LOAD: PASS

$ scripts/determinism.sh
SUMMARY pass=116 fail=0 unknown=0 errors=0
final checksum: 1550186985
DETERMINISM: PASS
```

**Determinism: checksum unchanged at 1550186985** even with the schema bump: migration 44 only creates an
empty table, and `research_speed` skips creating per-force records for Tavern-less/untouched towns, so
`m1_colony`'s state is bit-identical. Save/load passes at schema 44.

## Mutation checks (each fix proven to break a regression test when reverted)

```
C1  mutate research_speed.lua: e.applied = target -> e.applied = 0
    FAIL "CRITICAL: cold load with the target dropped to zero clears the saved bonus" (0.25 vs 0)

M1  mutate BOTH guards (record base = 0 AND disable foreign-write repair)
    FAIL "MAJOR: cold start with a foreign non-zero base still gets the Inspired bonus" (0.25 vs 0.65)
    (either guard alone is repaired by the other — the behaviour is deliberately double-guarded)

M2  mutate colony.lua dormant-hall return: remove research_speed.apply_all()
    FAIL "MAJOR: the real dormant evaluate() path clears the bonus when the hall dies" (0.25 vs 0)

m1  mutate colony.lua: remove to_shelter/sheltered/exposed exclusions
    FAIL "sheltered and exposed scholars are excluded from the inspired share" (1 vs 0)

m2  mutate s20's new assertion back to the old weak form would pass any positive rate1; the new
    assertion reports ratio=2.0000 and requires 1.9..2.1 (a 1.3x regression would fail).
```

All mutations were applied to temporary copies and restored; the committed tree is clean apart from the
deliberate changes.

## Reviewer scrutiny points (resolved)

1. **Force-wide side effect (accepted).** Research is force-wide in Factorio; extra colonies combine by
   max, never sum. Vanilla labs on the force also speed up — owner accepted.
2. **Cold load / cache invalidation.** Solved durably rather than by a module-local cache: `base` and
   `applied` are saved per force. Cold load with a changed or zero target now clears/adjusts the modifier on
   the first evaluation; `on_technology_effects_reset` still self-heals immediately.
3. **Foreign writes.** First write keeps a foreign base as the base and adds the bonus; a later foreign write
   is folded into `base` by comparing live against `base + applied`, so our own bonus is never absorbed.
4. **Dormant colonies.** `apply_all` on the early return covers the last-hall case; other forces untouched.
5. **On-duty definition.** Scholars need a live lab, daytime, and none of the sleeping/bed/shelter states;
   `to_hut` counts so the share does not flicker with trip timers. One pass per evaluation, no per-tick scan.
6. **Theatre forward-compat.** Quality 1.5 is in the pure table and `inspiration_quality` reads the numeric
   house field first, so slice B needs no research-rule rework; no Theatre prototype here.
