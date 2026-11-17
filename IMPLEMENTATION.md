# Implementation — Issue #59: Hand-feeding ammo to Gun Turrets

Branch `agent/turret-ammo`, worktree HEAD started at `38fe643`. Main checkout untouched.
Steam Factorio **2.1.24 (build 87808, mac-arm64)** was available via
`/Volumes/RTL9210/SteamLibrary/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio`,
so **all headless engine gates ran for real** (no unit-test-only fallback).

## File-by-file changes

| File | Change |
|---|---|
| `mod/scripts/model/turret.lua` | **NEW, pure.** `AMMO_FOR` (gun→firearm-magazine, flamethrower→flamethrower-ammo, rocket→rocket), `DEFAULT_TARGET` (10 each), `DEFAULT_BUILDING_PRIORITY = 3`, `ammo_for`, `default_request` (fresh row tables), `defaults` (`collect=false`, priority 3), nil-safe `want`. No Factorio globals, no `pairs()` for ordering. |
| `mod/scripts/gui.lua` | `MACHINE_GUIS["ammo-turret"] = "turret_gui"` (this is the whole opt-in enablement: marker + relative GUI + supply panel). `fill_machine` computes `is_turret`, hides `colony_supply_collect`, and ends the panel with a short plain-string note instead of the misleading "output" helper. The ghost "enable" click path now takes `collect`/`priority` from `colony_mod.machine_defaults` instead of hard-coding `true/4`. |
| `mod/scripts/colony.lua` | Requires the new model. `default_requests` returns `turret_model.default_request(name)` for ammo-turrets (incl. ghosts), before the recipe branch. New `machine_defaults(e)` helper returns `(false, 3)` for turrets and `(true, 4)` otherwise; `set_machine` uses it **only when the record is first created** (so a player's later edits survive re-enable). `copy_settings` now refuses to copy `collect=true` or priority 4 onto a turret (both the live and ghost branches) — see "Reviewer scrutiny". |
| `mod/scripts/work.lua` | **No change.** `machine_demands` → cached `m.need` → `machine_offer` (request band, `m.priority`) → claim/inflight → walk → `target.entity.insert` all already generic. The engine confirmed entity-level ammo counting works, so the planned `m.available` fallback was not needed. |
| `mod/scripts/marker.lua`, `store.lua`, `scripts/model/types.lua` | **No change.** Marker already keys off `gui.MACHINE_GUIS`. Turrets are ordinary `colony.machines[un]` records; **schema stays 37, no migration**. |
| `mod/scripts/spike/m3_turret.lua` | **NEW** headless spike, 32 checks: engine facts; opt-in defaults + demand seed; cached need → task → real haul; no top-up loop; opt-out + mid-haul destruction. |
| `mod/scripts/spike/loader.lua` | Registers `m3_turret`. |
| `mod/scripts/spike/m1_blueprint.lua` | Adds a gun turret to the blueprint: default row/`collect=false` at opt-in, tags in blueprint and ghost, revive → opted-in record with ammo row and priority 3. Widened the blueprint capture area and the ghost search box so all three entities are found (the third entity shifted the blueprint's placement origin). Now 32 checks. |
| `mod/scripts/spike/s08_registry.lua` | One interactive log line confirming the turret GUI anchor resolves. Dev-only, no assertions. |
| `tests/model_test.lua` | `describe("turret ammo (#59)")`: 5 tests (ammo map, fresh rows, defaults, `want`, garrison non-coupling). |
| `tests/glue_test.lua` | `describe("turret ammo adapter (#59)")`: 7 tests (schema 37, `default_requests`, furnace path unchanged, `machine_defaults`, `set_machine`, copy-settings guard, GUI hides collect). |
| `docs/factorio_colony_mod_design_document.md` | §5.2 records the landed turret slice and the engine fact; §7.2 records that garrison weapon ammo and turret ammo stay separate. |
| `AGENTS.md` | New Decisions paragraph for #59. |

## Gate outputs (exact)

```
$ scripts/test.sh
421 passed, 0 failed                       # was 409; +12 new tests

$ scripts/lint-determinism.sh
determinism lint ok

$ luajit -bl <each of the 9 changed .lua files>
OK mod/scripts/model/turret.lua
OK mod/scripts/colony.lua
OK mod/scripts/gui.lua
OK mod/scripts/spike/m3_turret.lua
OK mod/scripts/spike/loader.lua
OK mod/scripts/spike/m1_blueprint.lua
OK mod/scripts/spike/s08_registry.lua
OK tests/model_test.lua
OK tests/glue_test.lua

$ scripts/typecheck.sh
...
Diagnosis completed, no problems found

$ FACTORIO_BIN=... scripts/determinism.sh
== creating map
== run a: m1_colony for 19500 ticks
== run b: m1_colony for 19500 ticks
# spike m1_colony (issue #28) tick 120
SUMMARY pass=116 fail=0 unknown=0 errors=0
final checksum: 2960604716
DETERMINISM: PASS                          # UNCHANGED from the pre-feature value

$ FACTORIO_BIN=... TICKS=3600 scripts/headless-spike.sh m3_turret
[PASS] ... (32 lines)
SUMMARY pass=32 fail=0 unknown=0 errors=0

$ FACTORIO_BIN=... TICKS=400 scripts/headless-spike.sh m1_blueprint
[PASS] ... (32 lines)
SUMMARY pass=32 fail=0 unknown=0 errors=0

$ FACTORIO_BIN=... scripts/save-load.sh
...
SAVE/LOAD: PASS
```

Notable m3_turret lines (the ones that decided the design):

```
[PASS] turret.insert put 5 magazines into the ammo inventory - inserted=5
[PASS] entity-level get_item_count sees the loaded magazines - entity=5 inventory=5
[PASS] turret_ammo inventory agrees - inventory=5
fact: turret get_output_inventory = [LuaInventory: entity #1=turret_ammo] (ammo=5) - collect=false and the hidden checkbox are what keep rounds in the gun
[PASS] the ammo row became a #90 demand seed - demand=10
[PASS] the colonist was assigned the turret ammo haul - haul/true
[PASS] the colonist physically inserted magazines into the turret - turret=10 hall 10->0
[PASS] the same number arrived (no teleport duplication) - loaded=10 moved=10
[PASS] no further ammo offer is produced - none
SUMMARY pass=32 fail=0 unknown=0 errors=0
```

## API facts confirmed

Docs checked against https://lua-api.factorio.com/latest/ (reports runtime 2.1.25); engine behaviour checked in the real 2.1.24 Steam build by `m3_turret`.

| Planner item | Result |
|---|---|
| `LuaControl.insert(items) → uint32`, `get_item_count(item?) → uint32`, `can_insert`, `remove_item`, `get_inventory(inventory) → LuaInventory?` | Confirmed in docs and exercised by the spike. Entity-level `get_item_count("firearm-magazine")` on a `gun-turret` **does** see the loaded ammo (5/5), so **no `m.available` fallback was needed** — `work.lua` stayed untouched. |
| `defines.inventory.turret_ammo` | Confirmed in docs; value `1` in the 2.1.24 build. `turret.get_inventory(...)` returns a real inventory. |
| `defines.inventory.artillery_turret_ammo` | Docs list it, but in the 2.1.24 build it is also `1` (not distinct by value). Recorded as a logged fact in the spike, **not** asserted; artillery is out of scope so nothing depends on it. |
| `defines.relative_gui_type.turret_gui` | Confirmed in docs; in build 2.1.24 it resolves to `turret-gui`. `gui.MACHINE_GUIS` mapping verified by the spike. |
| `LuaEntity.get_output_inventory() → LuaInventory?` | Confirmed in docs, but **the planner's risk #2 is real**: in 2.1.24 a turret's "output inventory" IS `turret_ammo` (5 magazines visible). Designed around it: `collect=false` default, collect checkbox hidden in the panel, and `copy_settings` guard. No ammo can be hauled back out through the machine path. |
| `AmmoTurretPrototype` distinct from electric/fluid/artillery | Confirmed in docs; only `entity.type == "ammo-turret"` is opted in. |
| Blueprint tags (`model/tags.lua`) | No new code; `m1_blueprint` proves the turret record survives capture/revive. |

## Deviations from PLAN.md

1. **`machine_defaults(e)` helper added** to `colony.lua` (plan only named `default_requests`/`set_machine`). It keeps the collect/priority rule in one place and covers the GUI's ghost "enable" click, which otherwise hard-coded `true/4`. Pure rule still lives in `model/turret.lua`.
2. **`copy_settings` guard added** (not in the plan). The spike's output-inventory discovery exposed a hole: copying a furnace's settings onto a turret would set `collect=true` and let haulers strip loaded rounds into storage. Now a turret destination always forces `collect=false`/priority 3 while still copying the request rows. Regression test included.
3. **`fill_machine` early-returns for turrets** (plan suggested only hiding the checkbox). Avoids showing "Collect is off / finished products" text on a gun turret. No new locale keys.
4. **Spike check #1 reframed.** The planned assertion "output inventory is nil/empty" is false in 2.1.24; it is now a logged engine fact plus an assertion that our *protections* (`collect=false`, hidden checkbox, copy guard) are in place.
5. **Spike check #4 uses the real assignment path.** `spawn_colonist` calls `work.assign` synchronously, so the new colonist is already handed the turret haul (and the magazines are already claimed) when the spike looks. The spike asserts `storage.unit_state[un].dest_entity == turret` and then lets the shipped walk/insert complete, rather than hand-driving `start_haul` (which failed precisely because the claim had already happened). This is stronger than the planned version.
6. **Spike check #6 also inserts fresh magazines** before starting a second turret's haul, so "destroy mid-haul" actually exercises a claimed trip instead of an empty task.
7. **Unit test counts differ from the plan's estimate** (421 total, 32 m3 checks, 32 m1_blueprint checks) because the copy-settings regression test and the GUI test were added.

## Reviewer scrutiny checklist

* **The `collect=false` chain is the safety property.** Three independent entry points can create a machine record: `set_machine` (fixed), the GUI ghost click (fixed via `machine_defaults`), and `copy_settings` (fixed). If any future code path writes `collect=true` onto an ammo-turret, haulers will drain its magazines because `get_output_inventory()` returns the ammo inventory. A 4th path (blueprint tags forged by another mod) is validated but not forced; consider hardening `machine_ctx`/`open_machine` if that becomes a real scenario.
* **`default_requests` uses `e.ghost_name` for turret ghosts** — confirm the engine always supplies it on a ghost (the spike's blueprint path did).
* **`default_request` returns a table with `count = M.DEFAULT_TARGET[item]`.** All three mapped items have a target; an unknown name returns `{}` before this line, so `count` is never nil. If someone adds a name to `AMMO_FOR` without a `DEFAULT_TARGET`, the row gets a nil count and the panel shows an empty target.
* **`M.want` is not called by the adapter** (the existing `machine_demands` threshold rule is different). It is a pure rule implemented and tested because PLAN.md specifies it; if you prefer no dead code it can be deleted with its one test, but it documents the "inflight counts as on its way" rule the real path also follows.
* **Priority 3 vs houses' critical band.** `request` band (4) with building priority 3 means an out-of-ammo turret never outrages feeding/starvation — per plan. The alarm-driven urgency band remains an open design question (#59 follow-up).
* **`m1_blueprint` search box widened to `at.x - 8`** because adding a third entity shifted where the blueprint placed the furnace ghost. The old box silently found only two ghosts; the widened box is still bounded and should not pick up unrelated entities in this isolated spike.

---

## Review fixes (post-review commit)

The adversarial review found one blocking gap: `M.apply_tags` — the primary blueprint/restore path — overwrote
a turret's safe `collect=false` straight from untrusted tag data, and `tags.decode` defaults a *missing*
`collect` to `true`. Because a turret's `get_output_inventory()` is its ammo inventory, that made haulers
strip loaded rounds into storage. Fixed as follows.

### MAJOR — the safety invariant is now enforced on every restore path

* `model/turret.lua`: two new pure rules, `safe_collect(entity_type, collect)` (always `false` for
  `ammo-turret`; otherwise a truthy flag becomes `true` and a nil/false flag becomes `false`, preserving the
  old `not m.collect` guard) and `priority_default(entity_type, fallback)` (3 for turrets when a payload has
  no explicit priority). All adapters call these instead of hand-rolling the guard.
* `colony.lua apply_tags`: **both** branches now use `safe_collect` and `priority_default`. The live branch
  also falls back to priority 3 when the payload has no priority; an explicitly stored player priority is
  still honoured.
* `colony.lua set_machine`: a turret's `collect` is forced to `false` on **every** enable, not just record
  creation. This closes the "sticky across opt-out/opt-in" case and sanitises a poisoned record carried over
  from an older save (the load-time `colony.rebadge` also calls through here).
* `gui.lua`: the three duplicated ghost-tag decodes (open panel, 30-tick refresh, click context) are replaced
  by one `ghost_machine_record` helper built on `safe_collect`. A ghost's panel edits re-serialise that record
  into tags, so the poisoned value could otherwise have survived there. The `colony_supply_collect` click
  handler now also passes through `safe_collect` (defence in depth; the checkbox is hidden for turrets).
* `work.lua collect_offer`: a final guard calls `safe_collect(m.entity.type, m.collect)` before touching the
  output inventory. Even a record poisoned by an older save can never produce a drain offer. `collect_offer`
  is exported as a test hook (like `machine_demands`/`find_haul_task`) so this is pinned behaviourally.
* `copy_settings` (live + ghost) was already guarded in the first commit and remains so.

Adversarial re-trace of **every** `.collect` writer in `mod/scripts/`:

| Path | Turret result |
|---|---|
| `set_machine` new record (`machine_defaults`) | `false` |
| `set_machine` re-enable / `colony.rebadge` on load | forced `false` |
| `apply_tags` live entity | `safe_collect` → `false` |
| `apply_tags` ghost/blueprint | `safe_collect` → `false` (tags re-encoded safe) |
| `copy_settings` live | forced `false` |
| `copy_settings` ghost | forced `false` |
| GUI ghost record (3 decodes → re-serialised on row edit) | `safe_collect` → `false` |
| GUI ghost "enable" click (`machine_defaults`) | `false` |
| GUI collect checkbox click | `safe_collect` → `false` |
| `tags.decode` default for a missing flag | `true`, but **every** consumer above sanitises it |
| `collect_offer` (point of consequence) | refuses turrets regardless of the stored flag |

No live-entity code path found that can leave `collect=true` on an ammo-turret; the only way to write it is
direct mutation of another mod's storage table, which no in-repo code does.

### MINOR — behavioural coverage

* `tests/glue_test.lua`: a behavioural test loops over an **explicit `collect=true` tag** and a tag that
  **omits `collect`**, applies each through `apply_tags`, and asserts on the real `work.collect_offer`:
  the record yields `nil` even though the turret's ammo inventory is full; a deliberately poisoned record
  also yields `nil`; the sweep leaves `has_output` falsy. A control using the *same* non-empty inventory on
  an ordinary furnace confirms the offer machinery still works, so the test is not a stub artefact.
  Also added: `apply_tags` live/ghost sanitisation, and poisoned-record re-enable regression tests.
* `tests/model_test.lua`: `safe_collect` and `priority_default` pure-rule tests.
* `m3_turret`: new checks that a turret holding `DEFAULT_TARGET` magazines has a full ammo inventory, that
  the sweep does not mark it as output, that it produces **no collect offer**, and that even a poisoned
  record produces none — now 36 checks.
* `m1_blueprint`: two real engine ghosts with forged tags (explicit `collect=true`, and omitted `collect`),
  sanitised through `apply_tags` and revived; neither yields a provider record — now 34 checks.

### MINOR — `M.want`

Kept as-is at the reviewer's instruction. It remains a pure, tested statement of the "inflight counts as
already on its way" rule; the adapter's `machine_demands` uses its own threshold logic and does not call it.
Dead code is acceptable here — it documents the rule and is covered by `tests/model_test.lua`.

### Gate outputs after review fixes

```
scripts/test.sh                          427 passed, 0 failed   (was 421)
scripts/lint-determinism.sh              determinism lint ok
luajit -bl (8 changed Lua files)        all OK
scripts/typecheck.sh                     Diagnosis completed, no problems found
scripts/determinism.sh                   final checksum: 2960604716 — UNCHANGED; DETERMINISM: PASS
                                         m1_colony SUMMARY pass=116 fail=0
scripts/save-load.sh                     SAVE/LOAD: PASS
headless-spike.sh m3_turret              SUMMARY pass=36 fail=0 unknown=0 errors=0
headless-spike.sh m1_blueprint           SUMMARY pass=34 fail=0 unknown=0 errors=0
```

Docs (AGENTS.md, design document) were deliberately **not** touched in this fix commit — the docs-hygiene
agent owns them.
