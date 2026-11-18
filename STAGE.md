# STAGE — #52 M2 freight-link slice (crate pair)

Branch `agent/m2-freight`, base `master 1fe97bc`. Worker owner decisions followed verbatim: crate-pair link,
Rail Transit gate, `kind = "link"`, tags round-trip, player-built train, destination import crate is a
**provider in the collect band** whose filters seed B's demand graph and whose contents B's haulers empty.
No new vehicle, AI, per-tick scan or ledger.

## File-by-file changes

**New pure model — `mod/scripts/model/links.lua`** (no `game`/`storage`/`script`/`defines`/surface, only
`require("scripts.model.crates")`): `EXPORT/IMPORT`, `MAX_LINKS = 32`, `validate_id`, `validate_role`,
`peer`, `slot`, `valid_pair`, `export_wants`, `import_wants`, `mirror`, `candidates`. Every list is sorted by
item name (or colony id + un for GUI candidates) so offers and panels are deterministic. `export_wants`
applies the `crates.demands` 50%/10 hysteresis to the surplus table and clamps a row to
`min(target − contents − inflight, surplus[item])`. `import_wants` offers only filtered items actually in the
crate and returns `(demands, available)` like `crates.supply`.

**`mod/scripts/model/crates.lua`** — added `M.LINK = "link"`.

**`mod/scripts/model/tags.lua`** — `tags.crate` emits `link = {id, role}` only for a link crate, through the
validators; `tags.decode` validates/rejects the payload (positive integer id, exact role word) and always
returns `crate.link` (nil for ordinary crates). Dense filter rows unchanged.

**`mod/scripts/model/types.lua`** — `LinkSlot`, `LinkRecord`, `CrateLinkFields` annotations for strict
missing-fields checking.

**`mod/scripts/store.lua`** — schema 41 → **43**; `migrations[43]` creates `storage.links = {}` and
`storage.next_link_id = 1`. All plain data; no schema field is added to existing crate records (link/role are
nil-safe). **42 is deliberately left unassigned on this branch** (the parallel tourism branch owns it);
`M.migrate()` now skips an absent slot, so an old save upgrades cleanly here and a merge keeps both bodies
instead of silently dropping one. Review finding 4.

**`mod/scripts/colony.lua`** (thin adapter):
- `M.LINK_CRATE = "colony-freight-crate"` added to `M.CRATES`.
- `link_crate_list(colony, role)`; `link_record`, `link_slot_live`, `link_peer` (the trust boundary:
  cross-checks both slots against live registry records, roles, force, surface, kind); `link_candidates`.
- `validate_link_pair(a, b)` is the single validity gate (kind, live entity, territory, self-link, force,
  surface) shared by `bind_link` and the blueprint rebind path — no path mutates slots without it.
  `bind_link` additionally refuses already-paired halves and >32 links; it assigns a monotonic id, writes both
  slots and roles, invalidates B's demand, wakes both workforces and returns `(false, reason_key)` for flying
  text. `unbind_link(un)` **always clears the caller's own link/role first** (even when no registry entry
  contains that unit number), then clears the peer and deletes the record.
- `on_object_destroyed` calls `unbind_link(un)` unconditionally at the top of the handler, independent of
  whether `colony.crates[un]` still exists — the deferred event can lose the race against `crate_list` pruning.
- `mirror_link_filters(c)` copies filter rows to the peer on panel edits.
- `restore_link_fields` — the blueprint/copy rebind rule: a ghost carries id/role in tags until revival; a
  LIVE crate with an id that has no `storage.links` record stays fully unpaired (no dangling id); a duplicate
  paste of an intact pair is unpaired; a free slot is rebound into **only through `validate_link_pair`**.
- `demand_table` seeds only **paired** import LINK crates (`crate.link ~= nil`); export crates and stray
  unpaired import-role pastes never seed demand.
- `apply_tags`, `copy_settings`, `find_record`, `entity_tags` plumbing extended; crate destruction unlinks.

**`mod/scripts/work.lua`** — `link_export_surplus(colony, exports)` computes
`stock − quota_target − claimed` once per assignment (same `stock_table`/`quota_target` as `supply_capped`);
`link_export_offer` is an ordinary `kind="supply"` requester at `PRIORITY.request` and `link_import_offer` an
ordinary `kind="collect"` provider at `PRIORITY.collect`, both with `crate = c` and `key = unit_number`, so
`haul_plan.match`, `take_load`, `inflight` and the material-priority tie-break need no changes.
`find_haul_task` adds one bounded loop over LINK crates; no new event, timer or world scan. Both builders are
exported for the spike.

**`mod/scripts/gui.lua`** — the crate panel now opens for freight crates; a `crates.LINK` branch shows the
filter rows, role, peer, a `colony_link_target` drop-down of unpaired crates in other colonies on the same
force/surface, and Link/Unlink buttons. Filter edits mirror to the peer. All captions are locale keys.

**Prototypes/locale** — `colony-freight-crate` chest clone (16 slots, reuses demand-crate art with a TODO),
item and recipe (wood 10 + iron-plate 10 + steel-plate 2), unlocked by `colony-rail-transit` alongside
passenger rail and canteens; entity/item/description/technology/GUI/message locale keys added.

**Tests** — new `tests/links_test.lua` (23 checks: id/role validation, peer resolution, valid_pair
rejections, surplus clamp, claimed/inflight, contents, hysteresis, sort, import filtering, mirror, GUI
candidates), extended `tests/model_test.lua` tag cases (link round-trip, forged values, dense rows),
`tests/glue_test.lua` schema 43 + registry checks (its schema-6 → 43 migration also exercises the skipped
slot 42). `tests/locale_test.lua` unchanged and green.

**Spikes** — new `mod/scripts/spike/m2_link.lua` (**44 checks**), added to `spike/loader.lua`; `m1_persist`
records and re-checks `storage.links`/`next_link_id` across the save/load round-trip.

## Engine facts verified against https://lua-api.factorio.com/latest/

- `LuaEntity.tags` — "The tags associated with this entity ghost. **nil if this is not an entity ghost** or
  when the ghost has no tags." Live pair state must live in `storage`; ghosts carry the payload.
  https://lua-api.factorio.com/latest/classes/LuaEntity.html
- `Tags :: dictionary[string → AnyBasic]`, modifications must be written back wholesale, and non-sequence
  numeric keys are stringified — hence the single namespaced key and dense `{row,item,count}` lists.
  https://lua-api.factorio.com/latest/concepts/Tags.html
- `LuaItemCommon.get_blueprint_entity_tags(index)` / `set_blueprint_entity_tags(index, tags)` are the
  blueprint write channel used by `M.tag_blueprint`.
  https://lua-api.factorio.com/latest/classes/LuaItemCommon.html
- Events used (all already registered at load time): `on_built_entity`, `on_robot_built_entity`,
  `script_raised_revive`, `on_player_setup_blueprint`, `on_blueprint_settings_pasted`,
  `on_entity_settings_pasted`, `on_entity_cloned`, `on_object_destroyed`. No new train handler is needed:
  `on_train_changed_state` was already proven by `s16_links`.
  https://lua-api.factorio.com/latest/events.html
- **`on_object_destroyed` is deferred**: "Depending on when a given object is destroyed, this event will be
  fired at the end of the current tick or at the end of the next tick. The event's timing is independent of
  the in-world object being destroyed." `useful_id` is the second value returned by
  `register_on_object_destroyed` (the unit number for entities). This is why the spike asserts unlink in a
  later deferred step, not immediately after `destroy()`.
  https://lua-api.factorio.com/latest/events.html#on_object_destroyed
- In-repo engine evidence reused, not re-derived: `s16_links` (rail + inserters carry cargo with zero
  colonists, `wait_station` fires at both stops) and `m1_blueprint` (tag/copy/revive plumbing).

## Trust-boundary proof

Physical flow: `A hall --A haulers--> A export crate --player inserters/train--> B import crate --B haulers-->
B hall`. Only the explicitly bound peer is consulted (`storage.links[id]`), never proximity. `bind_link`
rejects same-colony, cross-force, cross-surface, already-paired and >32 cases; `link_peer` re-validates both
live slots on every offer, so a stale/replaced crate emits nothing. Export surplus =
`stock − quota_target − claimed`, where `quota_target` is the same #90 demand-aware reserve used by
`work.supply_capped`; `claimed` is summed over *all* of A's export crates, so two links cannot count the same
surplus; `contents + inflight` in the crate prevent overfilling. Priority is the normal `request` band
(4). Import-crate contents are a `collect`-band provider (5), filtered-only, at B with no ration ledger.
The `m2_link` spike proves reserve behaviour at offer time (surplus 5 → offer 5, below reserve → no offer),
real hauling (export crate got 10, A stock stayed 90 ≥ 40; B hall got 20 coal, crate 0, unfiltered junk
untouched), self-link rejection, duplicate paste, and destruction cleanup/re-link.

## Review fixes (REVIEW.md, verdict CHANGES REQUESTED)

1. **MAJOR — stale blueprint id bricks a crate.** `restore_link_fields` no longer commits a tag id to a live
   crate unless `storage.links[id]` exists; such a paste is fully unpaired (`link = nil`, `role = nil`).
   `unbind_link` now clears the caller's `link`/`role` **before** looking for a registry record, so Unlink is
   never a no-op. Mutation check in `m2_link`: after the pair is destroyed, paste the saved blueprint tag onto
   a new live crate → `link=nil`; fault-inject `link=999` and call `unbind_link` → both fields cleared; the
   same crate then binds successfully with a new id. Without the fix both checks fail.
2. **MAJOR — destruction cleanup race.** `on_object_destroyed` calls `unbind_link(un)` unconditionally at the
   top, before any `colony.crates[un]` lookup, so a `crate_list` prune in the one-tick window cannot orphan the
   link. Mutation check in `m2_link`: after `crateA.destroy()` the spike calls `colony.crate_list(A)` to prune
   the record **before** the deferred event, asserts the record is gone, and then asserts at +10 ticks that
   the link record is deleted and the peer is inert. Without the fix the link record survives.
3. **MINOR — rebind bypassed guards.** The new `validate_link_pair` is shared by `bind_link` and
   `restore_link_fields`; a fault-injected stale record whose free slot is in the same colony is refused by
   the rebind path (spike check "blueprint rebind refuses a same-colony pair").
4. **MINOR — schema collision.** Freight links migrate at **43**, not 42; slot 42 is left for tourism and
   `M.migrate()` skips absent slots. `AGENTS.md` was deliberately **not** edited in this follow-up per the
   reviewer's instruction (it still mentions schema 42 from the previous commit).
5. **MINOR — untested corners.** `m2_link` now checks a machine sink raising the reserve from 40 to 70 and
   shrinking surplus from 60 to 30 (with the row cap still bounding the offer), a paired import crate seeding
   B's demand by 20, and `quota_target = 0` exposing all 100 stock with only the row count as ceiling.
   Design note: for directly-eaten food items with no quota (`colony-bread`, `colony-water`,
   preserved/canned), `quota_target` is 0 by design (#54 "0 = unlimited"), so a freight link can ship such an
   item down to zero reserve. That is the owner-approved reserve definition, not a new food floor; if a
   playtest (#54) shows specialized towns are drained too aggressively, the fix belongs in per-item quotas,
   not in the link rule.
6. **MINOR — unpaired import-role pastes seeding demand.** Demand seeding now requires `crate.link ~= nil`,
   and unpaired pastes carry no role at all. Spike check "an unpaired import-role paste does not seed demand"
   reports 0 (was 500 with the old rule).

Residual (not requested by the follow-up): save/load proves the new registry survives but with zero active
links, since `m1_persist` intentionally keeps one colony; an active-pair round-trip is exercised by the tag
checks in `m2_link` rather than by `m1_persist`.

## Gate outputs (exact)

- `scripts/test.sh` → `531 passed, 0 failed`
- `scripts/lint-determinism.sh` → `determinism lint ok`
- `luajit -bl` on every changed Lua file → no output except `bytecode check done` (all compiled)
- `scripts/typecheck.sh` → `Diagnosis completed, no problems found`
- `TICKS=3600 scripts/headless-spike.sh m2_link` → `SUMMARY pass=44 fail=0 unknown=0 errors=0`
- `TICKS=19500 scripts/headless-spike.sh m1_colony` → `SUMMARY pass=116 fail=0 unknown=0 errors=0`
- `TICKS=400 scripts/headless-spike.sh m1_blueprint` → `SUMMARY pass=34 fail=0 unknown=0 errors=0`
- `TICKS=400 scripts/headless-spike.sh m1_tech` → `SUMMARY pass=13 fail=0 unknown=0 errors=0`
- `TICKS=19500 scripts/headless-spike.sh s16_links` → `SUMMARY pass=18 fail=0 unknown=0 errors=0`
- `scripts/determinism.sh` (m1_colony, two runs, executed twice AFTER the fixes) → `final checksum: 1885879558`,
  `DETERMINISM: PASS` both times — the checksum did **not** move: the fixes touch only link-crate paths and
  storage migration bookkeeping, and no existing town has a link crate.
- `scripts/save-load.sh` → `SAVE/LOAD: PASS`, `schema unchanged - 43`,
  `freight link registry survived the round-trip - 1`.
- `scripts/bench-colony.sh` (500 colonists, 2000 machines, 3600 ticks) → PASS:
  `vanilla, mod disabled: 0.098 total`, `mod on, no colony: 0.099 total 0.002 script`,
  `inert control: 0.273 total 0.058 script`, `colony, working town: 8.257 total 0.643 script`,
  `colony, working town, ore demand: 5.580 total 0.631 script`,
  `worst colony Lua: 0.643 ms/tick for 500 colonists (1286 us/colonist), budget <1.00`, `budget (#22): -> PASS`.

## New checksum

`1550186985` → **`1885879558`** (new freight-crate entity/item/recipe prototypes change Factorio's
prototype-table hash). Existing-town behaviour is otherwise unchanged: `m1_colony` still 116/116 and its
report is byte-identical between the two determinism runs. The review-fix pass did **not** move the checksum
(two fresh two-run gates both returned `1885879558`), and the schema moved 42 → 43 to avoid the tourism
collision.

## Deviations from PLAN.md

1. Spike is named **`m2_link`** (the task's explicit gate name), not `m2_freight`.
2. The spike seeds B's import crate directly instead of running a full train leg. `s16_links` is run as a
   separate gate and already proves the engine rail leg; this keeps `m2_link` focused on the crate-pair
   rules and avoids a second 19500-tick rail simulation.
3. The single-link "claimed" guard is conservative: `take_load` already removes in-flight items from stock
   and invalidates the stock cache, so subtracting `claimed` as well can only *reduce* exports, never leak.
4. `restore_link_fields` rebinds into a free slot adopting that slot's role (the peer is fixed), but only after
   `validate_link_pair`; a paste whose original pair is both live, whose id has no record, or whose rebind
   would be a self/cross-force/cross-surface pair is left fully unpaired with no role.

## Reviewer scrutiny points

- **Is the export reserve really the #90 target?** Yes: `link_export_surplus` calls
  `colony_mod.quota_target`, the same function `work.supply_capped` uses; the spike pins `surplus = 5` for
  stock 45 / quota 40.
- **Can two links drain the same surplus?** `claimed` sums in-flight over all export crates before any
  offer is emitted; unit tests pin the arithmetic and the spike checks `link-taken` on a second partner.
- **Does the import crate strand goods?** No: it is a `collect` provider and B's own haul cycle empties it;
  the spike shows B hall coal 20, crate 0.
- **Can a forged/stale tag bind a pair?** `tags.decode` validates id/role; `restore_link_fields` re-checks the
  link record, the live slots and `validate_link_pair`; a stale-id, duplicate or self-link paste is fully
  unpaired and emits no offer (three spike checks).
- **Destruction cleanup timing** relies on the engine's deferred `on_object_destroyed`; the spike forces the
  prune race, checks at tick +10, and proves the link is deleted, the peer inert and a stale-tag paste can be
  linked again with a fresh id.
- **UPS:** one extra `crate_list` pass per assignment, skipped behaviourally when no link crates exist; no
  new scheduler entry, no world scan, no per-tick work. Bench result below.
