# Plan — Issue #59: Hand-feeding ammo to Gun Turrets & other turret logistics

> Planner note: this is a **feature plan**, not code. All paths are relative to the
> `turret-ammo` worktree. Worktree HEAD = `38fe643`; the main checkout was not touched.

---

## 1. Problem statement + scope

### The gap

Issue #59's entire body is **"Reuse opt-in turret hauling."** The design already promises the
behaviour twice:

* §4.1 job 4: *"Haul … including **hand-feeding ammo into Gun Turrets** and fuel into burner machines."*
* §5.2: colonists directly load ingredients/fuel into `assembling-machine`, `furnace`, `lab`,
  `boiler`, or `ammo-turret`, **strictly on an opt-in basis**.

The production code never delivered the turret half. `mod/scripts/gui.lua:33-35` defines the opt-in
surface set:

```lua
local MACHINE_GUIS = {
  ["assembling-machine"] = "assembling_machine_gui", ["furnace"] = "furnace_gui", ["boiler"] = "boiler_gui", ["lab"] = "lab_gui",
}
```

That one table gates **both** opt-in entry points: `gui.on_gui_opened` (line 1611) only opens the
supply panel for those types, and `scripts/marker.lua:22` only registers entities whose type is in
`gui.MACHINE_GUIS`. The dev-only probe `mod/scripts/spike/s08_registry.lua:10` already showed that
Factorio has a `turret_gui` relative-GUI type and probed an `ammo-turret`, but nothing in the shipped
mod uses it. So today a gun turret is invisible to colony logistics: no badge, no request rows, no
hauler trips, and its ammo request does not feed the transitive-demand graph (#90).

The watchtower garrison (#56) is **not** this feature. `model/garrison.lua` decides which *colonist*
weapon a guard uses and asks the tower's stock room for `firearm-magazine`/`colony-arrow`; that
path already works and stays untouched. #59 is about the **vanilla gun-turret entity** standing in
the territory, fed from colony stock by a hauler.

### Goals (first slice)

1. A vanilla `ammo-turret` (gun turret, and the other ammo-turret prototypes such as flamethrower /
   rocket turrets) can be opted into colony logistics with the **existing** marker drag or the
   **existing** machine supply panel — no new GUI framework, no new tool.
2. Opting in gives it a sensible **default ammo request row** (`gun-turret` → `firearm-magazine`),
   still editable in the existing 3-row machine panel.
3. Haulers feed ammo through the **existing** machine-requester path: swept registry → cached
   `m.need` → `machine_offer` at `request` priority → claim/inflight → walk → `entity.insert`.
4. The ammo request automatically becomes a demand seed for #90 (magazine → plate → ore) and rides
   the existing #36 blueprint/copy-paste tag channel.
5. No per-tick scans, no new registry, no schema bump, no vanilla prototype edits.

### Non-goals (explicit)

* No militia behaviour, patrols, armory building, RTS whistle, or mechanized patrols (#57, #61
  garrison slice and §7.1 stay as they are). Guard rifles/pistols/bows are a separate subsystem.
* No new building or item prototypes; no new ammo recipes (vanilla magazines already exist).
* No `electric-turret` (laser), `fluid-turret`, or `artillery-turret` support in the first slice —
  these are distinct prototype *types* (see §4) and artillery uses a different inventory define.
* No alarm-driven "ammo is urgent" band, no auto-upgrade to piercing rounds, no spent-shell/used-ammo
  clearance (vanilla consumes magazines outright; to be confirmed by the spike).
* Turret inventories are **not** added to the Town Hall ledger stock total (ledger = hall +
  warehouses + hut chests + carried goods, §5.3); counting turret magazines would double-count.
* No force/relationship changes: the turret stays the vanilla force the player built it on. Colony
  membership is by **territory**, exactly like every other opted-in machine.

---

## 2. File-by-file changes

### NEW pure model — `mod/scripts/model/turret.lua`

`---@diagnostic enable: undefined-field, missing-fields`, no Factorio globals, no `pairs()` iteration
for ordering (direct name lookups only), returns fresh tables. Rules:

| Symbol | Rule |
|---|---|
| `M.AMMO_FOR` | Static, deterministic map of known vanilla ammo-turret **entity names** to their default item: `gun-turret → firearm-magazine`, `flamethrower-turret → flamethrower-ammo`, `rocket-turret → rocket`. (No modded/unknown names: they return nil and the player sets a row by hand.) |
| `M.DEFAULT_TARGET` | Per-item target, e.g. `{["firearm-magazine"]=10, ["flamethrower-ammo"]=10, ["rocket"]=10}`. 10 matches a vanilla gun-turret's ammo inventory and one full magazine stack; the spike verifies capacity. |
| `M.DEFAULT_BUILDING_PRIORITY = 3` | Turret ammo outranks ordinary external machines (default 4) inside the same `request` band, but stays far below houses' `critical` band (1). Player can still change it with the existing +/- buttons. |
| `M.ammo_for(name)` | `M.AMMO_FOR[name]` or nil. |
| `M.default_request(name)` | `{{item = <ammo>, count = <target>}}` or `{}` for an unknown/no-ammo turret. Fresh table each call (machine rows are copied per entity). |
| `M.defaults(name)` | `{requests = M.default_request(name), collect = false, priority = M.DEFAULT_BUILDING_PRIORITY}`. `collect=false` matters: a turret has no output inventory and must never have its loaded ammo emptied into storage. |
| `M.want(count, inflight, target)` | Integer deficit `max(0, target - (count or 0) - (inflight or 0))`; nil-safe. Keeps the "inflight counts as already on its way" rule that stops two haulers claiming the same magazines. |

Why a new model rather than extending `model/garrison.lua`: the ammo there is *colonist weapon*
ammo (rifle wear, magazine-per-10-engagements, target 5/batch 3); turret ammo is an *opt-in machine
supply* concern with different targets and a different registry. Separating them keeps both
offline-testable and avoids coupling defence combat rules to the logistics panel.

### MODIFIED adapters (thin; rules stay in the model)

* **`mod/scripts/gui.lua`** — add `["ammo-turret"] = "turret_gui"` to `MACHINE_GUIS` (line 33-35).
  This is the whole opt-in enablement: it unlocks the marker tool, the relative GUI, and the supply
  panel. Reuse the existing `colony-gui.supply-*` and `colony-advice.req-*` locale keys — **no new
  locale keys**, so `tests/locale_test.lua`'s literal-caption audit keeps passing. Optional polish:
  hide/disable `colony_supply_collect` for `ammo-turret` in `fill_machine` (line 1494) so a player
  cannot turn a turret into an ammo *provider*; recommended, 3 lines, no new keys.

* **`mod/scripts/colony.lua`** — in `M.default_requests(e)` (line 2001-2013), before the
  assembler/furnace recipe branch: if `e.type == "ammo-turret"` (or `ghost_type`) return
  `turret_model.default_request(e.name or e.ghost_name)`. In `M.set_machine` (line 2015-2041), when
  the record is first created, take `collect` and `priority` from `turret_model.defaults(name)` for
  ammo-turrets instead of the hard-coded `collect = true, priority = 4`. Everything else in
  `set_machine` is already generic and stays: `script.register_on_object_destroyed`, badge creation,
  `invalidate_demand` (this is what makes ammo a #90 demand seed), `machine_dirty`.

* **`mod/scripts/work.lua`** — **prefer no change**: `machine_demands(m)` (line 1417-1432) already
  computes deficits from `m.entity.get_item_count(req.item) + m.inflight`, `refresh_machine` caches
  it into `m.need`, and `machine_offer` (line 1494-1507) already emits a `request`-band offer with
  `building_priority = m.priority`. Delivery at line 3165 is a plain
  `target.entity.insert{name = s.item, count = s.count}` and needs no turret case.
  *Conditional fallback (only if the new spike disproves the entity-level count belief):* add a
  turret branch in `refresh_machine`/sweep that caches the ammo inventory count into
  `m.available`, and change one line of `machine_demands` to
  `local current = (m.available and m.available[req.item]) or m.entity.get_item_count(req.item)`.
  The decision math stays in `model/turret.lua`.

* **`mod/scripts/marker.lua`** — **no change**; it already keys off `gui.MACHINE_GUIS[e.type]`
  (line 22) and `colony.set_machine`.

* **`mod/scripts/store.lua`** — **no change, no schema bump, no migration.** Turrets live in the
  existing per-colony `colony.machines[unit_number]` registry introduced by migration `[4]`; they
  are ordinary machine records with different defaults. `SCHEMA` stays 37.

* **`mod/scripts/model/types.lua`** — optionally annotate the machine record shape if the
  conditional `available` field is added; otherwise no change. (Pure-model types file, never
  required at runtime.)

* **Docs / issue hygiene (after implementation, per AGENTS.md):** update design §5.2 (line 208-215)
  and §7.2 to record the landed turret slice, add a decisions line to `AGENTS.md`, comment the
  outcome on issue #59 and close it.

### Pattern fit summary

| Concern | Decision |
|---|---|
| Pure vs adapter | All rules (ammo choice, target, default row, deficit, priority) in `model/turret.lua`; `colony.lua`/`gui.lua`/`work.lua` only read those values and touch engine objects. |
| Discovery | **Opt-in only** via the existing `colony.machines` registry. Lazy world discovery (`scripts/cold.lua`) is deliberately *not* used: it exists for global mobile entities with no natural owner (refrigerated wagons). Turrets have a territory owner and an existing durable registry. |
| Which colony / force | `territory.owner_at(surface.index, position)` via `colony_mod.colony_of(e)`, exactly as `set_machine` does today; turret force is whatever vanilla force the player used. |
| When feeding happens | Periodic: `work.machine_sweep` (each machine every `MACHINE_SWEEP_TICKS * MACHINE_SWEEP_SHARE` = 300 ticks) computes `m.need`; assignment takes at most `M.MACHINE_OFFERS_PER_ASSIGN` = 16 cached offers per trip. GUI edits call `refresh_machine` for immediate response. **Never per tick.** |
| How demand is signalled | Request rows `m.requests[i] = {item, count}` → `machine_demands` → `m.need` → `machine_offer` (priority `request`=4, building priority default 3 for turrets). Inflight claims prevent double-hauling; delivery clears `m.need` and decrements inflight. |

---

## 3. Data / schema / registry decisions

* **No new storage table, no new schema version, no migration.** Reuse `colony.machines[un]`.
  A turret record is `{entity, enabled=true, requests={{item="firearm-magazine",count=10}},
  collect=false, priority=3, inflight={}, need=nil, has_output=nil, badge=…}`.
* **No per-tick scanning.** The existing sliced sweep and cached demand/output lists are the only
  inventory reads; a turret costs the same as one more opted-in machine (~0 added cost at the
  measured 0.57 ms/tick colony budget).
* **Blueprint/copy-paste parity is free.** `model/tags.lua` + `colony.entity_tags/find_record`
  mirror `{requests, collect, priority}` into `BlueprintEntity.tags` and restore on build, revive,
  settings-paste and clone for *any* opted-in entity. Add one turret case to `m1_blueprint` as a
  regression check (below), not new code.
* **Demand graph parity is free.** `set_machine` already calls `invalidate_demand(colony)`; the
  ammo row becomes a #90 seed and drops the usual downstream plate/ore demand with the 30-tick
  `DEMAND_TTL` cache.
* **Priority band stays `request` (4)**, not `tools` (2) or `urgent_collect` (3). A turret out of
  ammo must not outrank feeding/starvation; its building priority (3) only wins ties inside the band.

---

## 4. Exact engine API facts verified

All facts below were checked against **https://lua-api.factorio.com/latest/** (docs page reports
runtime version **2.1.25**) on 2026-11-16. Per AGENTS.md, engine behaviour itself must still be
confirmed by an in-game spike; the API signatures are evidence, the inventory behaviour is a
belief until `m3_turret` runs.

| # | Fact (exact signature / name) | Source |
|---|---|---|
| 1 | `LuaControl.insert(items) → uint32` — *"Insert items into this entity. This works the same way as inserters or shift-clicking: the 'best' inventory is chosen automatically."* This is already the delivery call at `work.lua:3165`. | https://lua-api.factorio.com/latest/classes/LuaControl.html#insert |
| 2 | `LuaControl.get_item_count(item?) → uint32` — *"Get the number of all or some items in this entity."*; `remove_item(items) → uint32`; `can_insert(items) → boolean`. These back `machine_demands` (`work.lua:1421`) and `req_status` (`gui.lua:1459`). | https://lua-api.factorio.com/latest/classes/LuaControl.html#get_item_count (also `#remove_item`, `#can_insert`) |
| 3 | `LuaControl.get_inventory(inventory: defines.inventory) → LuaInventory?` — *"The inventory or nil if none with the given index was found"*; a define is only meaningful for the matching object type. | https://lua-api.factorio.com/latest/classes/LuaControl.html#get_inventory |
| 4 | `defines.inventory.turret_ammo` exists, and **separately** `defines.inventory.artillery_turret_ammo` exists — artillery is a distinct slice. | https://lua-api.factorio.com/latest/defines.html |
| 5 | `defines.relative_gui_type.turret_gui` exists (needed for the `gui.relative` anchor in `open_machine`, `gui.lua:1550-1553`). The dev probe `s08_registry.lua:10` already mapped `ammo-turret → "turret_gui"`. | https://lua-api.factorio.com/latest/defines.html |
| 6 | `LuaEntity.get_output_inventory() → LuaInventory?` — *"Gets the entity's output inventory if it has one."* A turret has none, so `collect` must default to **false** or the sweep could treat loaded ammo as output. | https://lua-api.factorio.com/latest/classes/LuaEntity.html#get_output_inventory |
| 7 | `LuaInventory.get_item_count(item?) → uint32`, `insert(items) → uint32`, `is_full() → boolean`, `get_contents() → array<ItemWithQualityCount>`. | https://lua-api.factorio.com/latest/classes/LuaInventory.html#get_item_count (etc.) |
| 8 | `AmmoTurretPrototype`, `ElectricTurretPrototype`, `FluidTurretPrototype`, `ArtilleryTurretPrototype` are **distinct prototype types**. So `entity.type == "ammo-turret"` covers gun/flamethrower/rocket turrets only; laser/artillery need their own later slice. | https://lua-api.factorio.com/latest/index-prototype.html |
| 9 | `LuaEntityPrototype.ammo_category` is documented as *"Name of the ammo category of this land mine"* — it is **not** a reliable way to derive a turret's ammo. Use the pure static name→item map plus the editable GUI row. (The data-stage `AmmoTurretPrototype` page likewise exposes `automated_ammo_count` and `inventory_size`, not an ammo item.) | https://lua-api.factorio.com/latest/classes/LuaEntityPrototype.html#ammo_category · https://lua-api.factorio.com/latest/prototypes/AmmoTurretPrototype.html |
| 10 | In-repo verified (no new API): `BlueprintEntity.tags` channel via `model/tags.lua`, `m1_blueprint` (26 checks); `on_object_destroyed` pruning; scheduler cadence. | repo |

**Unverified / must be spike-checked:** (a) whether `LuaEntity.get_item_count("firearm-magazine")`
after `turret.insert{...}` actually reports turret-ammo-inventory contents (docs say "in this entity"
but do not enumerate inventories); (b) whether `get_output_inventory()` on a turret is truly nil;
(c) that `defines.inventory.turret_ammo` / `turret_gui` are present in the owner's exact 2.0/2.1
Steam build (docs show 2.1.25, and s14_circuit already found 2.1 inventory-define renames). The
plan's fallback in §2 covers (a); (b) is covered by defaulting `collect=false`; (c) is asserted by
the spike's first checks.

---

## 5. Tests

### Unit tests — extend `tests/model_test.lua`

Add `describe("turret ammo (#59)")` (the file already has `describe("garrison (#56)")` at line 239
as a style template):

* `ammo_for("gun-turret") == "firearm-magazine"`; flamethrower → `flamethrower-ammo`; rocket → `rocket`;
  unknown and laser names → nil.
* `default_request("gun-turret")` is exactly one row `{item="firearm-magazine", count=DEFAULT_TARGET}`;
  unknown name → `{}`; two calls return **different table objects** (no shared mutable rows).
* `defaults("gun-turret")` → `{collect=false, priority=DEFAULT_BUILDING_PRIORITY}`, and its `requests`
  are not shared with a second call.
* `want(0, 0, 10) == 10`; `want(8, 2, 10) == 0` (inflight counted); `want(12, 0, 10) == 0`; nil
  counts → full deficit (nil-safe).
* Regression: `garrison.ammo_wanted` behaviour from the existing #56 tests is unchanged (no
  accidental coupling).

### Adapter tests — extend `tests/glue_test.lua`

Under `mock.install()` (pattern at `tests/glue_test.lua:1-12`):

* `colony.default_requests({type="ammo-turret", name="gun-turret"})` → the ammo row.
* `colony.default_requests({type="ammo-turret", name="unknown-t"})` → `{}` (no crash).
* `colony.default_requests({type="furnace", ...})` still returns recipe-derived rows (fake a
  `get_recipe` on the stub) — guards the existing machine path.
* Schema assertion: `SCHEMA` stays 37 (the existing migration test at lines 14-39 can be left as-is).

### New headless spike — `mod/scripts/spike/m3_turret.lua`

Register with `core.register("m3_turret", {issue = 59, auto = true, desc = ..., run = function(ctx)})`,
following `m2_tower.lua`. Run with `TICKS=... scripts/headless-spike.sh m3_turret`. Exact checks:

1. **Engine facts:** `defines.inventory.turret_ammo ~= nil`; `defines.relative_gui_type.turret_gui ~= nil`;
   build a `gun-turret` on `player` force inside colony territory;
   `turret.insert{name="firearm-magazine", count=5} == 5` AND
   `turret.get_item_count("firearm-magazine") == 5` AND
   `turret.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine") == 5`
   (record `turret.get_output_inventory()` result — must be nil/empty). This is the critical
   belief check; if the entity count is 0 while the inventory count is 5, apply the §2 fallback.
2. **Opt-in:** `colony.set_machine(c, turret, true)` creates `c.machines[turret.unit_number]` with
   `requests[1].item == "firearm-magazine"`, `collect == false`, `priority == 3`, badge alive;
   `invalidate_demand` ran (a demand lookup for the magazine is non-zero after the TTL tick).
3. **Demand path:** after a `work.machine_sweep` with the turret empty, `m.need` contains the ammo
   deficit; `work.find_haul_task` with magazines in the hall returns a supply candidate whose
   `machine == m` and whose `load` contains `firearm-magazine`.
4. **End-to-end feed:** spawn colonists with haul rank 1, put 10 magazines in the hall, run ticks;
   assert `turret.get_item_count("firearm-magazine") > 0`, the hall count fell by the same amount,
   and `m.inflight["firearm-magazine"]` settled back to 0 after delivery.
5. **No top-up loop:** once the turret holds `DEFAULT_TARGET`, `m.need == nil` and no further ammo
   offer is produced for it over another sweep.
6. **Opt-out / loss:** `colony.set_machine(c, turret, false)` destroys the badge and removes it from
   the demand list; separately destroy an opted-in turret mid-haul and assert no crash and no
   orphaned offer (existing `entity.valid` checks).

### Extend existing spike — `mod/scripts/spike/m1_blueprint.lua`

Add two checks: opt in a gun turret, run the existing blueprint capture/revive path, assert the
revived turret record has the ammo row and `collect=false`. This proves tag persistence without a
new runner.

### Interactive probe — `mod/scripts/spike/s08_registry.lua`

It already maps `ammo-turret → turret_gui`; add one line so the interactive report confirms the
checkbox docks beside the vanilla turret GUI and that copy/paste carries the row. (Dev-only spike;
no assertions in headless runs.)

### Commands to run before committing (AGENTS.md)

`scripts/test.sh` · `scripts/typecheck.sh` · `scripts/lint-determinism.sh` · `luajit -bl` on every
changed Lua file · `TICKS=... scripts/headless-spike.sh m3_turret` · `scripts/save-load.sh` ·
`scripts/determinism.sh`. The determinism checksum should be **unchanged**: `m1_colony` never opts a
turret in, so the town must evolve identically; if the checksum moves, a default leaked into the
normal machine path and that is a bug.

---

## 6. Risks, open questions, minimal first slice

### Risks and mitigations

| Risk | Mitigation |
|---|---|
| `get_item_count` on an entity does not see the turret ammo inventory → perpetual "empty" demand and a hauler loop. | Spike check #1 compares entity-level and inventory-level counts. Fallback: cache ammo inventory into `m.available` in the sweep and make `machine_demands` prefer it (§2). |
| `get_output_inventory()` on a turret returns the ammo inventory → `collect=true` would let haulers steal loaded magazines. | Default `collect=false` from `model/turret.defaults`, plus optional GUI guard hiding the collect checkbox; spike records the actual return value. |
| Default target 10 exceeds a modded/small ammo inventory → insert refuses and the machine is marked `blocked_until`. | Spike asserts insert count and inventory capacity; clamp `DEFAULT_TARGET` if needed. Unknown turret names get no default row (safe). |
| Modded turret names not in the static map → no auto-row. | Deliberate, documented; the existing 3-row panel lets the player choose any item. No crash, no guessing. |
| Hundreds of turrets opted in → cost. | They are ordinary machine records on the existing 300-tick sliced sweep; no new per-tick work. Same scaling contract as #75. |
| Turret destroyed mid-haul / blueprint churn. | Existing `entity.valid` guards, `on_object_destroyed` pruning and tag restore already cover this; spike checks 6 exercises both. |
| Force/friendly-fire surprises (turret shooting wildlife/hunters). | No force changes in this slice; the #61 `colony-wildlife` ceasefire stays as-is. |

### Open questions (flag to owner; not blocking the slice)

1. **Emergency priority.** Should turret ammo jump into the `tools`/`urgent_collect` band while an
   `#61` alarm covers the turret? The first slice keeps `request` (4) with building priority 3; a
   follow-up can lift `m.priority` from `colony.alarms` in the adapter (pure rule would live in
   `model/alarm.lua`/`model/turret.lua`). Defence-vs-starvation is a design call.
2. **Ammo choice.** Auto-prefer `piercing-rounds-magazine` when available (mirroring
   `garrison.MAGAZINES`), or keep one plain `firearm-magazine` default and let the player edit?
   Default is the simplest deterministic choice.
3. **Scope of "other turret logistics."** Interpreted here as other *ammo-turret* prototypes
   (flamethrower/rocket) via the same static map. Laser/artillery (different types/inventory
   defines) and spent-ammo handling are a separate follow-up; confirm that matches the owner's
   intent for #59.
4. **Ledger visibility.** Should ammo inside turrets count as colony stock? Plan says no
   (double-counting); confirm.

### Recommended minimal first slice (delivers #59)

Four production files, zero schema/registry/framework changes:

1. `mod/scripts/model/turret.lua` (new, pure): static ammo map, default row, `collect=false`,
   priority 3, nil-safe deficit rule.
2. `mod/scripts/gui.lua`: add `["ammo-turret"] = "turret_gui"` to `MACHINE_GUIS` (+ hide collect for
   turrets) — this is the literal "reuse opt-in turret hauling" of the issue body.
3. `mod/scripts/colony.lua`: use `turret.default_request/defaults` in `default_requests`/`set_machine`.
4. `mod/scripts/work.lua`: **only if** the spike disproves entity-level ammo counting — otherwise
   zero lines.

Ship it with the `model_test.lua`/`glue_test.lua` assertions and the `m3_turret` headless spike;
extend `m1_blueprint` for persistence. Then comment the outcome on #59, close it, and update the
design doc + AGENTS.md decisions per AGENTS.md. This gives a player a vanilla `gun-turret` they can
marker-drag once and watch a colonist physically carry magazines to it — on the existing periodic
haul cadence, with no new scan, no new schema, and no vanilla prototype edits.
