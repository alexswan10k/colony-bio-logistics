# PLAN — Freight Link: colony-to-colony crate pair (#52)

**Owner decision (authoritative):** go ahead with the **crate-pair freight link**: an *export* crate in the
source colony + an *import* crate in the destination colony, both registered as demand-style crates with a
`kind = "link"` discriminator and a `tags.depot`/link payload, riding the existing `crates.lua` / `work.lua`
demand slowpaths. Rail Transit tech gate. The train and track are the **player's** — no new vehicle, no
autonomous AI, no per-tick scans. `s16_links` already proved vanilla rail carries cargo between two colonies
with zero colonists.

Worktree: `m2-freight`. Do not touch the main checkout. Write only this file for the planning step.

---

## 0. Scope: what is built, what is deferred

From the `s16_links` "ours but NOT built yet" list:

| Item | Decision |
|---|---|
| Tag round-trip (`model/tags.lua`, one namespaced key, dense row lists) | **INCLUDE** — extend `tags.crate`/`tags.decode` with a `link` sub-payload |
| Pair registration / "crate co-scheduler" | **INCLUDE**, minimal: a global plain-data link registry + both halves emitting ordinary offers inside `work.find_haul_task` (no new scheduler chain) |
| Blueprint tagging of *pairs* (not just filters) | **INCLUDE** — `link` id + role ride the same `colony-bio-logistics` tag; rebind rule for pasted duplicates |
| GUI for linking ("Link with \<colony\>") | **INCLUDE** in the crate panel |
| Tech gate | **INCLUDE** — new crate unlocked by existing `colony-rail-transit` (no new tech) |
| Discriminator naming | **INCLUDE** — `crates.LINK = "link"`, roles `export`/`import` |
| Exporter-side trust boundary | **INCLUDE** — surplus above `colony.quota_target`, minus in-flight export claims |
| Import-crate flow at B | **INCLUDE** via the normal haul cycle (a `collect`-band provider offer); no new ration-debt ledger |
| Destination-aware empty-train scheduling (circuit `item_count` wait) | **DEFER** — player uses `time` wait conditions, as in `s16_links`; API note in §4 |
| New wagon/locomotive prototypes, driver units, rail AI, collision masks | **EXCLUDE** — opt-in pillar, player owns the train |
| Cross-force / cross-surface links | **DEFER** — same force + same surface only (see §2) |
| Car Routes (#3), tourism (#51), cold-chain wagon reuse (#45) | **OUT OF SCOPE** |

---

## 1. Linking two crates: GUI, identity, save/load, blueprints

### 1.1 Player flow

1. Rail Transit researched (`colony-rail-transit`, already needs `railway`). Builds one **Freight Crate**
   (`colony-freight-crate`) in colony A and one in colony B, both inside colony territory (same build path as
   the other crates — `colony.lua:1723`). Each registers `kind = crates.LINK`, `role = nil` (unpaired).
2. Player opens crate A's panel. Because `kind == crates.LINK`, `fill_crate` shows the normal four item
   filter rows (the same `colony_crate_item_N` / `colony_crate_count_N` widgets as a demand crate) plus:
   - a read-only "Role: Export" line,
   - a drop-down `colony_link_target` listing other colonies on the **same force and surface** that have an
     unpaired Freight Crate (label = hall name / colony id),
   - a button `colony_link_apply` ("Link with \<colony\>") and `colony_link_unlink`.
3. Clicking apply calls the thin adapter `M.bind_link(colony, crate_a, colony_b, crate_b, player)` (§3).
   A is **export**, B is **import** (direction is GUI-chosen; the player can unlink and re-link reversed).
   A flying text / native alert reports success or the reason key (wrong force, no crate in B, already paired).
4. Editing a filter row on either crate mirrors the row list to its peer (pure `links.mirror`), so both panels
   show the same "what A sends / what B receives" list. Empty peer is a no-op.

### 1.2 Identity (all plain data, keyed by unit_number)

```
storage.links[id] = { id = id, a = {colony_id = <int>, un = <int>},
                      b = {colony_id = <int>, un = <int>} }   -- a = export, b = import
storage.next_link_id = <int>                                   -- monotonic, starts at 1
colony.crates[un] = { entity, kind = "link", colony_id, filters, inflight, priority,
                      logistics_enabled, link = <id>|nil, role = "export"|"import"|nil }
```

- `id` is a **stable integer link id**, not a unit number: unit numbers are stable for save/load but change
  when a blueprint is pasted, so the id is the durable identity and `un` is only the live lookup key.
- Both halves store the same `link = id`; the role is per-half. `storage.links[id]` is the O(1) resolver:
  `links.peer(id, self_un, slots)` returns the opposite slot. No scanning of colonies on any hot path
  (`M.link_candidates` iterates colonies only on GUI refresh).
- Save/load: it is plain data in `storage` (integers, strings, tables), with `LuaEntity` references only in
  the existing `colony.crates` records, which the engine already re-resolves. No functions.
- Destruction: the existing `colony.crates[un] = nil` path (`colony.lua:2063`) calls `M.unbind_link(un)`,
  which clears the peer's `link`/`role` and frees/removes `storage.links[id]`. `on_object_destroyed` already
  fires for crates via `script.register_on_object_destroyed` at registration. Re-linking a freed half works.

### 1.3 Blueprints / copy-paste (one namespaced key, dense lists)

`model/tags.lua` keeps one tag dictionary key `colony-bio-logistics`. `tags.crate(c)` gains, only when
`c.kind == crates.LINK`:

```lua
link = { id = <positive int or nil>, role = "export"|"import" }   -- scalars, validated on decode
```

Filters still go through the existing `encode_rows`/`decode_rows` dense-row helpers (`row = 1..FILTER_ROWS`,
`item` string, `count` clamped to `crates.MAX_COUNT`) — a sparse filter map would have its numeric keys
stringified by the engine, which is why lists stay dense. `tags.decode` treats the payload as untrusted:
`id` must be a positive integer (else nil), `role` must be exactly one of the two words (else nil).

The existing plumbing is reused unchanged:

- write on `on_player_setup_blueprint` → `M.tag_blueprint` / `M.entity_tags` (`colony.lua:2391`, `2241`);
- read on `on_built_entity`, `on_robot_built_entity`, `script_raised_revive` → `M.apply_tags`
  (`colony.lua:2258`); ghosts keep the `link` payload in `e.tags` until revived;
- `on_entity_settings_pasted` / `on_entity_cloned` → `M.copy_settings` (`colony.lua:2317`),
  `on_blueprint_settings_pasted` (`colony.lua:2423`).

**Duplicate-id rule (pasting a paired crate twice).** On build/revive/copy, if `storage.links[id]` already has
**two live halves**, the pasted crate gets a **fresh** id (`storage.next_link_id`) with its role preserved —
it is an unpaired half the player must re-link. If exactly one slot is dead/mined, rebind the pasted crate into
the free slot. If no id was in the tag, leave it unpaired. This is deterministic, needs no scan, and is proven
by the new blueprint case in the spike (§5).

---

## 2. Trust boundary

Direction of physical freight (the player's inserters/train do the rail leg; colonists do the two ends):

```
A hall/stock --A haulers--> A export crate --player inserters--> wagon --player train--> 
B import crate --B haulers--> B hall/stock
```

**Who may pull from whom.** Only the pair the player explicitly created: a crate's source/destination is its
`storage.links[id]` peer, never a proximity scan. `M.bind_link` refuses pairs where the two crates are not
both `kind="link"`, not in valid colonies, on different forces, or on different surfaces (a train cannot
cross surfaces). The `colony_id` stored in each slot is cross-checked against the crate's live registry record
before any offer is emitted; a stale slot yields no offer (so mined/replaced crates cannot be drained).

**Export side (source A) — the only place goods leave a colony.**
Reuse the existing quota/reserve rule exactly: `colony.quota_target(colony, item)` (`colony.lua:781`) =
`base_quota_target + resource_demand` where `resource_demand` is the cached #90 demand table
(`colony.demand_table`, `colony.lua:727`). This is the same number `work.supply_capped` uses to stop
collecting machine output (`work.lua:1481`). Pure rule in `links.export_wants`:

```
reserve(item)   = colony.quota_target(A, item)          -- 0 means "player opted out (unlimited)"
claimed(item)   = sum of c.inflight[item] over A's export crates   -- take_load already tracks this
available(item) = stock_count(A, item) - reserve(item) - claimed(item)
want(item)      = clamp(f.count - c.inflight[item], 0, available(item))
```

- No offer at all when `available <= 0`: A never parts with the stock it needs for itself. `stock_count`
  is hall + bulk storage + towers (`colony.lua:420`), i.e. exactly the stock the demand system reasons about.
- Per-link cap = the row's `count` (clamped `1..crates.MAX_COUNT` by the existing `crates.set_count`); a row
  with count 0 exports nothing. Per-colony cap = the reserve above. Multiple links from A each see the same
  `claimed` total, so two haulers/links cannot both count the same surplus.
- Offer priority = `haul_plan.PRIORITY.request` (4), i.e. the normal demand-crate/machine-request band —
  below houses (1), tools (2), urgent (3), above machine-output `collect` (5). "The exporter's chest gets
  priority over the hall's export sink" because it is an ordinary demand offer; no new band is added.
- When quota_target is 0 (unlimited base), reserve = 0: the per-link cap is the only ceiling, which is the
  player's explicit opt-out (same semantics as #54 "0 = unlimited").

**Import side (destination B).**
- The import crate's filters are B's **want list**: they are added to `colony.demand_table`'s seed loop
  (extend `colony.lua:741-746` to include LINK crates with `role == "import"`), so B's #90 demand, quotas and
  hall-space planning know B wants these items. The export crate in A deliberately does **not** seed A's
  demand — it exports surplus, it does not want.
- Goods the train unloads into B's import crate are offered as a **provider** (`kind = "collect"`),
  using `links.import_wants(filters, contents, cap)` as the demand list, priority `collect` (5) — below every
  real request, so B's own needs are filled first. This is the existing `crate_supply_offer` shape
  (`work.lua:1435`) with a different demand function; no new ration-debt ledger, no special unloader.
  With no filters, the import crate accepts nothing (safe default; the panel says "set filters to receive").
- This is what "charges the importing colony's ration debt like anything else home" means concretely:
  arriving goods become ordinary colony stock via the normal haul cycle, and B's existing needs/quota logic
  decides what to do with them.

**Opt-in / no scans.** No `find_entities_filtered` per tick; the link registry is consulted in `find_haul_task`
alongside the existing crate lists, and both offers reuse `crate_contents` / `inflight` / `take_load`
(`work.lua:1799`) and the deterministic `haul_plan.match` ordering.

---

## 3. Pure model and thin adapter

### 3.1 Pure module — `mod/scripts/model/links.lua`

No `game`, `storage`, `script`, `defines`, `surface`, no `require` of adapter modules (only `model/crates.lua`
for constants). All functions take/return plain tables and scalars; outputs sorted by item name so
determinism holds. Proposed API (annotated in `model/types.lua` for strict missing-fields):

- `M.EXPORT, M.IMPORT = "export", "import"`
- `M.MAX_LINKS = 32` (guard against unbounded registry growth; bind returns a reason key when exceeded)
- `M.peer(slots, id, self_un)` → opposite slot or nil.
- `M.valid_pair(id, a, b, force_ok, surface_ok, kind_ok)` → boolean (scalars passed in by the adapter).
- `M.export_wants(filters, stock, reserves, claimed, inflight)` → `{ {item, count}, ... }` for the source,
  applying §2's clamp and hysteresis (reuse `crates.demands`' 50%/10 rule by passing the surplus table as
  `contents` and the crate's `inflight` as-is).
- `M.import_wants(filters, contents, cap)` → the same shape for the destination's provider offer.
- `M.mirror(filters)` → deep copy for writing to the peer (never share row tables).
- `M.validate_id(v)` / `M.validate_role(v)` → nil-safe validators shared by `tags.decode` and `apply_tags`.
- `M.candidates(colonies, self_colony_id, force_name, surface_index)` → plain `{colony_id, un, label}` list
  for the GUI (adapter passes scalar summaries).

Unit tests: new `tests/links_test.lua` (clamp at reserve, `claimed` across two links, 0 = unlimited,
valid_pair rejection, mirror, deterministic sort, validators) + tags round-trip cases added to
`tests/model_test.lua` (link id/role survive, forged id/role rejected, dense row list preserved).

### 3.2 Thin adapter (no game rules)

- **`colony.lua`** (binding hub, already holds the crate registry and blueprint plumbing):
  - `M.LINK_CRATE = "colony-freight-crate"`; `M.CRATES[M.LINK_CRATE] = crates.LINK` (`:85`).
  - `M.crate_list` (`:362`) used for both roles; add `M.link_crate_list(colony, role)` filter helper.
  - `M.bind_link` / `M.unbind_link` / `M.link_candidates` — plain-data writes, validity checks, flying text.
  - `M.demand_table` (`:741`) includes import LINK crates as seeds.
  - `M.apply_tags` (`:2282`) restores `link`/`role` and calls the bind/rebind rule; `M.entity_tags`
    (`:2241`) and `M.copy_settings` (`:2364`) carry the link payload; `M.find_record` (`:2214`) handles it.
  - `M.on_object_destroyed` crate branch (`:2063`) calls `M.unbind_link(un)`.
- **`work.lua`**: in `find_haul_task` (`:1683-1688`), alongside the DEMAND loop, add two loops — export
  crates → `requesters[#+1] = link_export_offer(c, colony)`; import crates → `providers[#+1] =
  link_import_offer(c)`. Both are 6-10 line wrappers over `links.export_wants`/`import_wants` with the same
  shape as `crate_demand_offer`/`crate_supply_offer` (`key = c.entity.unit_number`, `crate = c`), so
  `take_load`/`inflight` and `haul_plan.match` need no changes. No new event, no new timer, no scan.
- **`gui.lua`**: `fill_crate` (`:1393`) gets a `crates.LINK` branch (filters + role + peer + link/unlink
  controls); `crate_ctx` (`:1520`) builds the ghost record from the decoded tags including `link`;
  `on_gui_elem_changed`/`on_gui_text_changed` (`:1899`, `:1927`) already route filter edits — add the mirror
  call for link crates; add `on_gui_click`/`on_gui_selection_state_changed` handlers for the three new
  widget names. All literal captions go in locale.
- **`model/tags.lua`**: extend `M.crate` / `M.decode` with the validated `link` payload (§1.3).
- No `require` at runtime outside the existing load-time graph; `colony.lua` already requires `links` via
  the model layer (no cycles — `links.lua` only requires `crates.lua`).

---

## 4. Engine facts verified against https://lua-api.factorio.com/latest/

| Fact | Source |
|---|---|
| `LuaEntity.tags` is **ghost-only** — "nil if this is not an entity ghost or when the ghost has no tags". Live link state must live in `storage`, not on the entity. | https://lua-api.factorio.com/latest/classes/LuaEntity.html |
| `Tags` = `dictionary[string → AnyBasic]`; modifies must be written back wholesale; **non-sequence numeric keys are stringified**, so only dense row lists are safe. | https://lua-api.factorio.com/latest/concepts/Tags.html |
| `LuaItemCommon.get_blueprint_entity_tags(index)` / `set_blueprint_entity_tags(index, tags)` are the blueprint write channel used by `M.tag_blueprint`. | https://lua-api.factorio.com/latest/classes/LuaItemStack.html (inherited from `LuaItemCommon`) |
| `on_train_changed_state` fires on train state change; `on_built_entity`, `on_robot_built_entity`, `script_raised_revive`, `on_blueprint_settings_pasted`, `on_entity_settings_pasted`, `on_entity_cloned`, `on_player_setup_blueprint` are the tag/registry events we use. **No new train handler is needed by this slice** — the rail leg is the player's and was proven by `s16_links`. | https://lua-api.factorio.com/latest/events.html |
| `LuaTrain.manual_mode` must be false for a Lua-assigned schedule to run; `schedule` is RW but must be assigned a new table (mutating the returned table does not apply); `cargo_wagons`, `station`, `state` are readable. | https://lua-api.factorio.com/latest/classes/LuaTrain.html |
| `defines.train_state.wait_station` exists ("Waiting at a station"); `defines.inventory.chest` exists for chest inventories. | https://lua-api.factorio.com/latest/defines.html |
| `WaitCondition` fields `type`, `ticks`, `condition`; valid types include `time`, `item_count`, `circuit`, `full`, `empty`, `not_empty`, `specific_destination_full`, `at_station`. **There is no `no_items_all` member in 2.1.25** — the issue's phrase maps to `item_count` with a `CircuitCondition` (comparator `<`, constant 1) or `empty`; destination-aware scheduling is therefore deferred and would need its own probe. | https://lua-api.factorio.com/latest/concepts/WaitCondition.html · https://lua-api.factorio.com/latest/concepts/WaitConditionType.html |
| In-repo engine evidence (do not re-derive): `s16_links` proved rail + inserters move cargo with zero colonists, `wait_station` fires at both stops, and the wagon parks short of the stop sign (inserters must sit beside the parked wagon). | `mod/scripts/spike/s16_links.lua`, issue #52 report |

---

## 5. File-by-file changes, schema, locale, tests, determinism

### Prototypes / data
- `mod/prototypes/buildings.lua`: add `local freight_crate = chest_clone("iron-chest", "colony-freight-crate",
  "freight-crate", 16, 1)` next to the demand crate (`:187-188`); add it to the `data:extend` list (`:340`),
  its item (`:378` area) and a recipe (`:587` area, e.g. wood 10 + iron-plate 10 + steel-plate 2 — parity
  with demand crate plus a rail-age material). First slice reuses the demand-crate sprite/icon with a TODO,
  as Haul Station does (`:193`); a distinct `icon-freight-crate.png` is a nice-to-have.
- `mod/prototypes/technology.lua`: add `unlock("colony-freight-crate")` to `colony-rail-transit` (`:182-187`).
- `mod/locale/en/locale.cfg`: `entity-name/description`, `item-name`, `recipe-name` (and any `technology-description`
  update) for `colony-freight-crate`; new `[colony-gui-crate]` keys for role, peer, hint, target dropdown,
  link/unlink buttons and reason messages. The literal-key audit (`tests/locale_test.lua:49`) scans every
  `{"colony-..."}` literal under `mod/scripts` and `mod/prototypes`, so every key must exist.

### Schema / migration
- `mod/scripts/store.lua`: `SCHEMA` 41 → **42**; add `migrations[42]`:
  ```lua
  storage.links = storage.links or {}
  storage.next_link_id = storage.next_link_id or 1
  -- existing crates gain link/role lazily (nil-safe); no per-colony registry changes needed
  ```
  All plain data. Save/load round-trip (`scripts/save-load.sh`) must stay green.

### Tests
- `tests/links_test.lua` (new) — pure rules, §3.1.
- `tests/model_test.lua` — tags round-trip of `link` payload, forged-value rejection.
- `tests/locale_test.lua` — runs unchanged, must stay green.
- `tests/tech_test.lua` — `m1_tech`-style reachability check that the new crate recipe is unlocked by Rail
  Transit and that the vanilla `railway` interlock still holds (no vanilla ingredient changes).

### Spike: `m2_freight` (new, `mod/scripts/spike/m2_freight.lua`)
Follows `s16_links`/`m1_blueprint` patterns (`core.register`, `ctx.check`, `ctx.after`, `MAP_SEED=1234567`):
1. Two halls → two colonies; build one Freight Crate in each; call the **real** `colony.bind_link` adapter
   (the adversarial review has already caught spikes that bypassed the player path — do not write `storage`
   directly).
2. Stock A's hall above its quota target; after enough ticks the export crate is filled and the hall stays
   **at or above** the reserve (§2); a second link from A cannot double-count the surplus.
3. Seed the B import crate (prefer the real `s16_links` rail line + inserters for one full leg, with
   `ctx.after` checks like `s16_links:238-293`) and prove B's haulers empty it into B's hall while B's own
   critical needs are still served first.
4. Blueprint: recreate both crates from tagged ghosts, verify id/role round-trip and the duplicate-id rebind
   rule; copy-paste carries the payload.
5. Destroy one crate → peer unpaired, `storage.links[id]` cleaned, no lingering offers; re-link works.
6. `TICKS` long enough (use 19500 like `s16_links` where the rail leg is exercised).

### Commands / determinism
- `scripts/test.sh`, `scripts/typecheck.sh`, `scripts/lint-determinism.sh`, `luajit -bl` on every changed Lua.
- `scripts/save-load.sh` (schema 42), `scripts/headless-spike.sh m2_freight`, `scripts/headless-spike.sh
  m1_blueprint` (tag cases), `scripts/headless-spike.sh m1_tech`, `scripts/determinism.sh`,
  `scripts/bench-colony.sh` (#22 gate).
- **Checksum:** a new entity/item/recipe prototype changes Factorio's prototype-table hash, so the two-run
  `m1_colony` checksum **will move** (precedent: Patrol Post 713316852 → 1550186985, Armory 3400134649 →
  713316852). Re-baseline it and record the new value on #52 / AGENTS.md Status. The patrol-active gate may
  move too; note it if so. No `math.random`/`os`/`io`, no `pairs()`-ordered output in new rules, no functions
  in storage — behaviour of existing towns must be otherwise unchanged.

---

## 6. Risks and open design questions

1. **"Both as demand crates" vs. the import side's provider role (top question).** The plan keeps the
   demand-crate *filter UI* and demand-*seed* role for the import crate, but makes it a `collect`-band
   **provider** so arriving goods reach B's stock via the normal haul cycle — this is what the issue says
   ("nothing special should be invented there"). A literal reading where the import crate stays a pure
   requester would leave freight stranded in B unless the player belts it into the hall. **Recommendation:
   adopt the provider reading**; confirm with the owner before implementation.
2. **Reserve semantics when `quota_target == 0`.** Treated as "no floor, player opted out"; the per-row cap
   is then the only ceiling. Confirm this is acceptable for exports of unlimited-quota items.
3. **Blueprint duplicate-id rebind** is a new rule; the spike must prove it, including the case where the
   original pair was mined. If pasting both halves of a pair into the *same* colony, they must not silently
   form a self-link (valid_pair rejects same-colony pairs).
4. **Stale peer records** after a colony is deleted / entity replaced: the offer builder cross-checks
   `colony_id`, `un`, kind and force before emitting; a stale slot is inert rather than self-healing.
5. **Spoilage in transit** is the engine's normal behaviour; the Refrigerated Wagon (#45) is not reused in
   this slice. A shipment of perishable goods can arrive spoiled — acceptable, documented.
6. **Multi-link throughput / UPS:** N links add N export + N import offers to `find_haul_task`, which is
   already the dominant cost. The #22 benchmark must stay under 1 ms/tick; if it regresses, cap offers per
   evaluation with a rotating cursor like `needs.wake_batch`.
7. **Locale/typecheck:** strict missing-fields annotations for the new `link`/`role` crate fields must be
   added to `model/types.lua`, and every new literal caption key must be in `locale.cfg` or the audit fails.
8. **What a "per-colony cap" means to the player** beyond the reserve + per-row cap: we expose only the row
   count in the GUI. A global "max export per colony" toggle is **not** built; it is a follow-up if the
   playtest (#54) shows links draining specialized towns too aggressively.
