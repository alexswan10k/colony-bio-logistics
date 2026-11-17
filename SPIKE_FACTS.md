# Stage 0 M3 defence stack — verified engine facts (`s19_defence`)

All values below are **actual readings from the 2.1.24 binary** used by `scripts/headless-spike.sh`,
not wiki assumptions. Run: `scripts/headless-spike.sh s19_defence` (27 checks, 0 fail, 0 errors).
API URLs are the 2.1.25 docs pinned during planning; where the binary differed from the docs, the
binary is recorded and the difference is called out.

Base: `90e210d` (467 tests, checksum 328728317, schema 38). No prototypes, models, schema or
gameplay behaviour were added — the spike registers load-time handlers that are inert unless the spike
is running, so the two-run checksum is **unchanged at 328728317**.

---

## 1. Colonist prototype / `ai_settings`

| Fact | Actual value | Source |
|---|---|---|
| `colony-colonist` is a `unit` | `unit/colony-colonist` | spike |
| Prototype `attack_parameters.range` | `14` | spike (`prototypes.entity[...]`) |
| Prototype `distraction_cooldown` | `1000000` | spike |
| Prototype `vision_distance` | `1` | spike |
| Prototype `ai_settings` (UnitAISettings) | `destroy_when_commands_fail=false`, `allow_try_return_to_spawner=false`, `do_separation=true` | spike; <https://lua-api.factorio.com/latest/concepts/UnitAISettings.html> |
| Prototype `allow_run_time_change_of_is_military_target` | `false` | spike; <https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#allow_run_time_change_of_is_military_target> |
| Live `entity.ai_settings` readable | yes (`LuaAISettings`, valid) | <https://lua-api.factorio.com/latest/classes/LuaEntity.html#ai_settings> |
| Live `ai_settings.allow_destroy_when_commands_fail` | `false` (matches prototype `destroy_when_commands_fail`) | spike; <https://lua-api.factorio.com/latest/classes/LuaAISettings.html#allow_destroy_when_commands_fail> |
| Live `ai_settings.destroy_when_commands_fail` | **does not exist** — access throws `LuaAISettings doesn't contain key destroy_when_commands_fail` | spike (name differs from the prototype field) |
| Other live AI fields | `allow_try_return_to_spawner=false`, `do_separation=true`, `join_attacks=true`, `path_resolution_modifier=0`, `size_in_group=1` | spike |
| `ai_settings.allow_destroy_when_commands_fail` writable at runtime | **yes** (write succeeded; spike restored `false`) | <https://lua-api.factorio.com/latest/classes/LuaAISettings.html> |

**Implication (Stages 1 & 3).** The deep-research hazard is closed: the runtime field is
`allow_destroy_when_commands_fail`, *not* `destroy_when_commands_fail`. The prototype is authored with
`ai_settings = { destroy_when_commands_fail = false, ... }`, but any adapter assertion/readback must use
`.allow_destroy_when_commands_fail`. Keep it `false` on the militia prototype so failed nest paths never
silently delete units (see §5).

## 2. `is_military_target` — prototype-level only

| Fact | Actual value | Source |
|---|---|---|
| `colony-colonist.is_military_target` | `true` (inherited from `small-biter`) | spike |
| Runtime write `unit.is_military_target = false` | **rejected**: `entity colony-colonist (unit) does not allow to change is_military_target run-time`; value stays `true` | spike |
| Prototype `allow_run_time_change_of_is_military_target` | `false` | spike |

<https://lua-api.factorio.com/latest/classes/LuaEntity.html#is_military_target> — RW only when the prototype
allows it.

**Implication (Stage 1).** Per-unit switching is impossible. A distinct `colony-militia` prototype must set
`is_military_target` explicitly in data. Recommended `true` (raid waves path to militia, useful for
nest-clearing), civilians stay `true` today by inheritance — if civilians must be non-targets, that is a
*separate* prototype change, not a runtime toggle. Adding the prototype changes the Factorio prototype-table
hash, so the determinism checksum will legitimately move at Stage 1 (re-baseline then).

## 3. `LuaEntity:damage` — return, resistance, death cause

Signature: `damage(damage, force, type?, source?, cause?) → float`.
<https://lua-api.factorio.com/latest/classes/LuaEntity.html#damage>;

| Fact | Actual value | Source |
|---|---|---|
| `type` default | `"impact"` (docs) | docs |
| `source` | must be on the same surface; `cause` need not be | docs |
| 50 raw `"physical"` on a stone-wall | returned `37.600002288818`; health `350 → 312.400` (loss `37.600`) | spike |
| Return value | equals the health actually lost — i.e. **damage after resistances** | spike + docs ("total damage actually applied after resistances") |
| Resistances applied inside `damage()` | **yes** — 50 raw became 37.6 applied | spike |
| Prototype `resistances` readable at runtime | **no** (`stone-wall` prototype exposes none); behaviour is the only evidence | spike |
| `on_entity_damaged` fired for typed hit | yes (`n=1`, `damage_type=physical`) | spike; <https://lua-api.factorio.com/latest/events.html#on_entity_damaged> |
| `destructible=false` target | `damage(50, "enemy", "physical")` returned `0`, health unchanged — **no-op** | spike (consistent with shelter, #61) |
| Lethal hit | `damage(10000, "enemy", "physical", source, cause)` returned `350` (capped at remaining health) and raised `on_entity_died` | spike |
| `on_entity_died ev.cause` | **the `cause` entity passed to `damage()`** (`unit_number` 5, `small-biter`) | spike; <https://lua-api.factorio.com/latest/events.html#on_entity_died> |
| `on_entity_died ev.force.name` | `"enemy"` (the **damaging** force) | spike |
| `on_entity_died ev.damage_type.name` | `"physical"` | spike |

**Implication (Stages 1 & 2).** Scripted damage and mortality attribution work exactly as
`scripts/mortality.lua` assumes: `ev.cause` is the cause entity, `ev.force.name == "enemy"` drives the enemy
cause, `ev.damage_type.name` is the typed string. Route militia kills through the existing handler unchanged.
Two cautions: (a) the engine already subtracts resistances inside `damage()` — a pure damage model must NOT
subtract them again; (b) the colonist already carries a fixed 10-damage hitscan attack used by guards/hunters,
so Stage 1 must avoid double-counting (lower it to a baseline, or use the engine attack and script damage on
different paths). Heal-back mitigation on `on_entity_damaged` is event-driven and the event is proven to fire.

## 4. Armour on units — DOES NOT EXIST (biggest risk resolved)

| Fact | Actual value | Source |
|---|---|---|
| `defines.inventory.character_armor` / `character_guns` | exist (`5` / `3`) | spike; <https://lua-api.factorio.com/latest/defines.html#defines.inventory> |
| colonist `get_inventory(character_armor)` | **`nil`** | spike; <https://lua-api.factorio.com/latest/classes/LuaControl.html#get_inventory> |
| colonist `get_inventory(character_guns)` | **`nil`** | spike |
| colonist `.grid` (direct entity grid) | `nil` | spike; <https://lua-api.factorio.com/latest/classes/LuaEntity.html#grid> |
| colonist `.resistances` | access throws `LuaEntity doesn't contain key resistances` — no per-unit path | spike |
| Contrast: a real `character` entity | **does** have `character_armor` inventory | spike |

**Implication (Stage 1, mandatory).** A `small-biter`-derived unit has no armour slot, no equipment grid and
no per-unit resistance/quality path — native armour mitigation is impossible. Armour **must** be pure-data:
storage-backed gear (like tools), with mitigation as a scripted fraction applied by heal-back on
`on_entity_damaged`. This confirms PLAN.md Top risk #1 and the Stage 0 expectation. It also means no schema is
needed for gear if it lives in existing `unit_state` as nil-safe fields (preferred).

## 5. Equipment grid + quality — observable on items, not units

| Fact | Actual value | Source |
|---|---|---|
| `power-armor` item stack `.grid` | present (`LuaEquipmentGrid`) | spike; <https://lua-api.factorio.com/latest/classes/LuaItemCommon.html#grid> |
| `grid:put{name="energy-shield-equipment", quality="uncommon", position={0,0}}` | succeeded → `LuaEquipment (uncommon)` | spike; <https://lua-api.factorio.com/latest/classes/LuaEquipmentGrid.html#put> |
| `LuaEquipment.quality.name` | `"uncommon"` | spike; <https://lua-api.factorio.com/latest/classes/LuaEquipment.html#quality> |
| `grid.shield` / `grid.max_shield` | `0 / 65` | <https://lua-api.factorio.com/latest/classes/LuaEquipmentGrid.html#shield> |
| `grid.get_contents()` | 1 entry, keys `{count, name, quality}` | <https://lua-api.factorio.com/latest/classes/LuaEquipmentGrid.html#get_contents> |
| `grid:take{equipment=eq}` | `ItemWithQualityCount` `{name="energy-shield-equipment", count=1, quality="uncommon"}` | <https://lua-api.factorio.com/latest/classes/LuaEquipmentGrid.html#take> |
| `ItemWithQualityCount.quality` type | **`string`** (`"uncommon"`), not a `LuaQualityPrototype` — `.name` on it is `nil` | spike (differs from the docs' type wording) |

**Implication (Stage 1).** Quality *is* observable as a plain string, which is exactly the shape
`model/armour.lua` wants (`quality_name` is a string from the adapter). But because a unit cannot wear an
armour item (§4), quality must be read from *stored gear data*, not from a live equipment grid on the unit.
If a future slice ever gives units a grid, read quality from `LuaEquipment.quality.name` while it is in the
grid; do not rely on `ItemWithQualityCount.quality.name` (it is a string).

## 6. Commands / distraction / patrols

| Fact | Actual value | Source |
|---|---|---|
| `defines.command.attack_move` | **`nil`** (does not exist) | spike; <https://lua-api.factorio.com/latest/defines.html#defines.command> |
| `defines.command.attack_area` | exists (value `5`) | spike |
| `defines.distraction.by_enemy` | exists | spike; <https://lua-api.factorio.com/latest/defines.html#defines.distraction> |
| `attack_area` at a live `biter-spawner` with `by_enemy` | readback `type=5`, nearby biter killed, nest alive, militia survived, `completions=0` (no completion while a target remains / while distracted) | spike (re-confirms `s18_command`) |
| `destroy_when_commands_fail=false` under 5 repeated failed `go_to_location` into water over 900 ticks | unit **survived**, no silent deletion | spike |
| Contrast biter with `allow_destroy_when_commands_fail=true` set at runtime | **destroyed** under the same failed paths | spike — proves the flag is what controls deletion |

**Implication (Stage 3).** `attack_area + by_enemy` remains the only attack-move surrogate. It does not emit a
completion event while a target survives, so patrol waypoint/lease expiry must be driven by `scheduler.after`
timers as planned, not by `on_ai_command_completed` alone. The `colony-militia` prototype must set
`destroy_when_commands_fail = false`: the biter contrast shows that with it `true`, repeated failed paths into
a nest silently delete the unit — exactly the #57 hazard. Civilian `distraction_cooldown` stays `1000000`;
whether a smaller militia value is needed for nest-clearing retargets is a playtest/balance decision this spike
did not measure.

## 7. Cost

| Fact | Actual value | Source |
|---|---|---|
| `damage()` × 200 (health reset each call), avg of 20 | ~3.2 ms total → **~16 µs/call** | `ctx.profile` |
| one `attack_area` dispatch, avg of 20 | ~0.003 ms → **~3 µs** | `ctx.profile` |

**Implication.** Event-driven damage and patrol dispatch are negligible against the <1 ms/tick colony Lua
budget (#22). No UPS concern for Stages 1–3.

---

## Gates (exact results)

- `scripts/test.sh` → **467 passed, 0 failed**
- `scripts/lint-determinism.sh` → **determinism lint ok**
- `luajit -bl mod/scripts/spike/s19_defence.lua` → syntax OK (also `loader.lua`)
- `scripts/typecheck.sh` → **Diagnosis completed, no problems found**
- `scripts/determinism.sh` → **PASS**, final checksum **328728317** (unchanged — no prototypes/behaviour)
- `scripts/save-load.sh` → **SAVE/LOAD: PASS** (schema 38, unchanged)
- `scripts/headless-spike.sh s19_defence` → **SUMMARY pass=27 fail=0 unknown=0 errors=0**
- `TICKS=19500 scripts/headless-spike.sh m1_colony` (regression) → **SUMMARY pass=116 fail=0 unknown=0 errors=0**

## Mechanics that are IMPOSSIBLE / changed from plan expectations

1. **Native armour on a unit is impossible** (no armour inventory, no grid, no resistances). Stage 1 armour
   is pure-data with scripted heal-back — not optional.
2. **Runtime `is_military_target` switching is impossible.** A distinct militia prototype is required.
3. **The runtime AI field is `allow_destroy_when_commands_fail`, not `destroy_when_commands_fail`** — adapter
   assertions must use the former (accessing the latter throws).
4. **`attack_move` does not exist**; `attack_area + by_enemy` is the surrogate and needs timer-driven lease
   expiry because it does not complete while a target remains.
5. **`get_contents()`/`ItemWithQualityCount.quality` is a string**, not a prototype object — read
   `LuaEquipment.quality.name` if a prototype is ever needed.
