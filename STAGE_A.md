# Stage A — research-speed half of Inspired (#48)

Branch `agent/m2-recreation` (base master `1fe97bc`). Slice A of PLAN.md only: no Theatres, no plaza, no
prototype changes, no schema bump. Owner decision: use the force-wide
`force.laboratory_speed_modifier`, self-healed from a module-local cache written at evaluation time;
accept the side effect on vanilla labs on the same force. No `research_progress` credits.

## Changes

| File | What |
|---|---|
| `mod/scripts/model/inspiration.lua` (new, PURE) | `RESEARCH_MAX = 0.5`, `TAVERN = 1.25`, `THEATRE = 1.5` (slice B represented now), `QUALITY` table, `research_bonus(share, quality) = clamp((quality-1)*share, 0, 0.5)`, generalized `work_ticks(base, quality)`. nil/NaN inputs read as 0. |
| `mod/scripts/research_speed.lua` (new adapter) | `apply(force)` computes `max` bonus over colonies whose hall is on that force and writes `force.laboratory_speed_modifier`. Module-local `applied`/`reset` maps are derived data (no `storage` schema). Load-time handler for `on_technology_effects_reset` re-applies immediately after an engine wipe. No per-tick scan; one idempotent pass per colony evaluation. |
| `mod/scripts/colony.lua` | `serve_taverns` now also writes derived `house.inspiration_quality`; new `compute_inspiration(colony, split, houses)` derives `colony.inspiration = {share, quality}` once per evaluation from the same sorted housing roster used elsewhere (scholars on duty = `job == "research"`, live lab, not asleep); `inspiration_quality(colony, un)` added and `is_inspired` delegates to it (boolean API unchanged, so all ★ label callers are untouched); `research_speed.apply(colony.hall.force)` at the end of `evaluate`. |
| `mod/scripts/spike/s20_inspired_research.lua` (new) + `spike/loader.lua` | 13-check headless spike: Inspired scholars raise the modifier to the exact pure-rule value, reset self-heals, stripping ale drops it to 0, removing the tavern clears quality, and modifier 1 doubles research progress vs 0. |
| `tests/inspiration_test.lua`, `tests/research_speed_test.lua` (new) | Pure rule (cap, no inspiration, NaN/nil, Theatre quality, work ticks) and adapter (share/quality, max across colonies, other force ignored, foreign write preserved, reset self-heal, fresh-load no double-add, no-inspiration writes 0). |

No new prototypes, no locale keys, no `storage` schema change (still 41), no new registries. `colony.inspiration`
and `house.inspiration_quality` are derived, nil-safe fields on existing tables.

## Engine facts (Factorio runtime docs 2.1.25, verified 2026-11-18)

* `LuaForce::laboratory_speed_modifier` is a **read/write double**, force-wide
  — https://lua-api.factorio.com/latest/classes/LuaForce.html#laboratory_speed_modifier
* `0` = normal, `1` = double speed, `-0.5` = half speed (the lever really changes the research rate, not
  just a label) — https://wiki.factorio.com/console
* Research is engine-driven while a lab is powered and stocked (already proven by `s13_science`); Lua work
  trip timers do not change research, which is why the engine modifier is required.
* `LuaForce::reset_technology_effects()` discards custom/script modifier changes and raises
  `on_technology_effects_reset` **with the `force`** —
  https://lua-api.factorio.com/latest/classes/LuaForce.html#reset_technology_effects and
  https://lua-api.factorio.com/latest/events.html#on_technology_effects_reset
* Empirical confirmation in `s20_inspired_research`: 180 ticks at modifier 0 advanced progress 0.030;
  180 ticks at modifier 1 advanced 0.060 (exactly 2×). No new lab prototype was needed — the real
  `colony-town-archive` was used, so no `Laboratory.prototype` change was required or made.

## Gate outputs (exact)

```
$ scripts/test.sh
523 passed, 0 failed

$ scripts/lint-determinism.sh
determinism lint ok

$ for f in <changed Lua>; do luajit -bl "$f" >/dev/null && echo OK; done
OK mod/scripts/model/inspiration.lua
OK mod/scripts/research_speed.lua
OK mod/scripts/colony.lua
OK mod/scripts/spike/s20_inspired_research.lua
OK mod/scripts/spike/loader.lua
OK tests/inspiration_test.lua
OK tests/research_speed_test.lua

$ scripts/typecheck.sh
... Generated bundle with 1171 files ...
Diagnosis completed, no problems found

$ TICKS=5000 scripts/headless-spike.sh s20_inspired_research
SUMMARY pass=13 fail=0 unknown=0 errors=0

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

**Determinism result: checksum unchanged at 1550186985** (the gate value recorded in AGENTS.md). The new
module-local cache and derived fields write no engine state on a Tavern-less town, so `m1_colony` stays
bit-identical. No rebaseline was made.

## Reviewer scrutiny points

1. **Force-wide side effect (accepted).** `laboratory_speed_modifier` is the only dynamic lab-speed lever
   and it applies to every lab on the force, including vanilla ones. Research is force-wide in Factorio, so
   a per-colony bonus is not representable without physical speed modules (haul/supply, out of scope). The
   owner explicitly accepted this. Multiple colonies combine by **max**, never by sum, so extra towns cannot
   stack the bonus.
2. **Cache invalidation / engine resets.** `reset_technology_effects()` wipes script modifiers; the
   load-time `on_technology_effects_reset` handler sets a `reset` flag and re-applies from the live modifier
   immediately (s20 proves self-heal). Foreign writes between evaluations are preserved by subtracting the
   cached previous bonus (`base = live - applied`) before adding the new target. A raw third-party write of
   the modifier to exactly 0 outside that event would be read as "no bonus yet" and overwritten; no mod in
   this codebase does that.
3. **Save/load.** The engine serializes the force modifier but not the module-local `applied` map. On the
   first write after load, a non-zero live modifier is treated as already containing our bonus and the
   target recomputed from the saved `colony.inspiration` is subtracted, so a load does not double-add (unit
   test pins this). A zero live modifier is treated as a fresh map/reset so the bonus is applied. Residual
   edge case: if another mod writes a non-zero base on a *fresh map before our first evaluation*, that first
   write is preserved for one evaluation instead of receiving the bonus; the warm cache corrects all later
   evaluations. `scripts/save-load.sh` passes on schema 41.
4. **Scope of "on duty".** Scholars are counted when `job == "research"`, their lab is live, and they are
   not asleep/in bed; walking-to-lab (`to_hut`) counts so the share does not flicker with trip timers. Houses
   are Inspired by the existing Tavern service; inspectors live in the house assigned by this evaluation's
   sorted housing roster. No per-tick scan; the pass is one loop over colonists per colony evaluation.
5. **Theatre forward-compat.** The pure table already carries quality 1.5, and `inspiration_quality` reads a
   numeric `house.inspiration_quality` first, so slice B can set 1.5 on Theatre-served houses without
   touching the research rule. This slice still writes only 1.25 (Tavern) and adds no Theatre prototype.
