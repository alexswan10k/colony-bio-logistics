# Stage 2 — Armory building and shared structural protection (#56 remainder)

Branch `agent/defence-stack`. Base: Stage 1 (`8c2d349`) on master `7bd0450`. Schema **38 → 40**.
Determinism re-baselined **3400134649 → 713316852** (two consecutive runs, identical).

Owner decisions honoured: the Armory is a **worker-free depot** (like Well/Salt Pan, not a labour hut);
"manned" = a limit > 0 **and** that many militia actually equipped from its own gear stock, with the aura
scaling with the equipped count; manned Watchtowers grant the same aura through the same pure rule. Stage 2
only — no patrols, nest AI, territory emission, other turret types or vanilla prototype edits.

## File-by-file changes

### New pure models (no Factorio globals, no input mutation)
- `mod/scripts/model/defence.lua` — `RADIUS = 24`, `PER_MILITIA = 0.10`, `MAX_REDUCTION = 0.50`;
  `aura(manning)` (clamped), `coverage(pos, posts, radius)` (nearest covering post wins; string-key tie-break;
  `strength` or `manning` accepted), `covered(...)` (bool form), `apply_incoming(amount, reduction)` (clamped,
  never negative). Posts are plain `{position, strength, key}` records.
- `mod/scripts/model/armour.lua` — `GEAR_PER_MILITIA` / `armory_targets(manning)` (empty at limit 0),
  `draw_gear(counts, wants)` (private copy, want order), `restock_deficit(counts, targets, inflight)`.
  All deterministic and non-mutating, with LuaLS annotations.

### New adapter
- `mod/scripts/armory.lua` — bound via `M.bind` (no runtime `require` cycle). Registry
  `colony.armories[un] = {entity, colony_id, inflight, equipped, limit=0, logistics_enabled, priority}`.
  Owns `register`, `list` (sorted, prunes dead), `contents` (counts + quality strings), `take`/`put` (with hall
  fallback), `gear_source` (nearest stocked Armory in range), `mark_equipped`/`clear_equipped`/`equipped_count`
  (plain unit-number claims, lazily pruned), `posts` (Armories **and** posted Watchtowers), `mitigate`
  (the heal-back), `offer` (the tools-band haul row), `shift_limit` (GUI).
- `mod/scripts/shelter.lua` — one multiplexed `on_entity_damaged`: raises/refreshes #61 alarms and, afterwards,
  calls `armory.mitigate(ev)`. `M.bind_armory` injects the adapter; no second event, no second per-tick pass.

### Integrations
- `mod/scripts/militia.lua` — `issue_gear` draws weapon/armour from a stocked in-range Armory first (`opts`
  still force the hall path for spikes), records `gear.source_armory` and the equipped claim; ammo is spent out
  of the same depot with a hall fallback; `return_gear(colony, st, un)` returns gear to the source Armory and
  clears the claim on demobilisation/death. Weapons are never sourced from a Watchtower's stock room.
- `mod/scripts/colony.lua` — `M.ARMORY`, registry list helper, build registration (territory-gated, alt-mode
  radius circle), object-destroyed cleanup, Armory stock included in `stock_table` / `storage_list` / ledger,
  cursor overlay for the held item, and bind calls for the adapter + shared damage handler.
- `mod/scripts/work.lua` — Armory restock offers in the existing `tools` band (limit 0 emits nothing);
  `armory` added to the target/inflight chains so haulers really deliver and `inflight` is decremented.
- `mod/scripts/gui.lua` — relative panel docked on `colony-armory`: manning limit +/- (0–4), equipped count,
  aura radius + reduction, gear rows (chest / target / on the way), inert hint, 30-tick signature refresh.
- `mod/scripts/store.lua` — `[39]` no-op (Stage 1 deliberately had no migration) and `[40]`
  `colony.armories = {}` for every colony; `SCHEMA = 40`.
- Prototypes/locale/art — `colony-armory` steel-chest clone (16 slots), item/recipe (steel 20 + iron 20 +
  stone-brick 10), `colony-armory` tech (30 Frontier Charters; prerequisites `colony-logistics`,
  `steel-processing`, `military`), new sprite/shadow/icon via `scripts/gen_art.py`, art manifest entry, and
  entity/item/tech/description/GUI locale keys (locale audit green).

### Tests / spikes
- `tests/defence_test.lua` (11 tests) — aura clamping/ties/nearest, coverage bool, damage clamp, target scaling,
  gear draw/deficit determinism and no mutation. `tests/glue_test.lua` updated to schema 40 + armory assertion.
- `mod/scripts/spike/m3_armory.lua` — 26 checks: inert empty armory, gear draw/depletion/restock, measured
  structural mitigation matching the pure model (24 vs 30 damage at 0.20 reduction), stable heal-back (no
  runaway, no revive, no enemy healing), and the same aura from a **real posted guard** on a Watchtower.
- `mod/scripts/spike/m1_persist.lua` — places a manned armory with gear and asserts the registry, limit, entity
  and chest contents survive a save/load round-trip. `docs/TESTING.md` documents the new spike.

## The aura / gear model

- **Aura**: `aura(n) = min(0.50, 0.10*n)`. A post is included in `posts` only when its limit > 0 and it has
  equipped/posted at least one defender (`min(equipped, limit)` for an Armory, `min(guards, 4)` for a tower).
  A damaged structure inside 24 tiles of one or more posts uses the **nearest** post's strength; ties break by
  key, so two runs of the same world always mitigate identically. Reduction is applied only to **enemy**
  damage on a **colony-owned, non-unit, non-character** entity inside that colony's territory: this excludes
  militia units (whose armour is a separate pure-data heal-back) and excludes enemies entirely. Heal-back is
  `applied - apply_incoming(applied, reduction)`, clamped to `[0, max_health - hp]`, skipped at `hp <= 0`.
- **Gear**: `armory_targets(limit)` produces ordered per-militia rows (rifle 1, heavy armour 1, magazine 10,
  arrows 20); a limit of 0 produces no rows and therefore no offer. `draw_gear` hands out only what the chest
  holds (no duplication; two militia draw sequentially from the same live inventory). `restock_deficit`
  subtracts chest stock and in-flight hauls. A militia's weapon/armour and ammo are consumed from its source
  depot; gear returns there on death/demobilisation, falling back to the hall if the depot is gone.

## Gate outputs (exact)

| Gate | Result |
|---|---|
| `scripts/test.sh` | `496 passed, 0 failed` |
| `scripts/lint-determinism.sh` | `determinism lint ok` |
| `luajit -bl` (17 changed `.lua` files) | all `OK` |
| `scripts/typecheck.sh` | `Diagnosis completed, no problems found` |
| `scripts/headless-spike.sh m3_armory` (`TICKS=9000`) | `SUMMARY pass=26 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_garrison` | `SUMMARY pass=18 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m3_militia` | `SUMMARY pass=32 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh s19_defence` | `SUMMARY pass=27 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_colony` (`TICKS=19500`) | `SUMMARY pass=116 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_shelter` (extra) | `SUMMARY pass=14 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_tech` (extra) | `SUMMARY pass=13 fail=0 unknown=0 errors=0` |
| `scripts/save-load.sh` | `SAVE/LOAD: PASS` (schema 40; armory registry/gear asserts pass) |
| `scripts/determinism.sh` run 1 | `DETERMINISM: PASS`, checksum **713316852**, m1_colony 116/116 |
| `scripts/determinism.sh` run 2 | `DETERMINISM: PASS`, checksum **713316852** (stable) |
| `scripts/bench-colony.sh` | worst colony Lua **0.610 ms/tick** (500 colonists, 2000 machines) — **PASS** |

Note: passing several spikes in one `headless-spike.sh` invocation truncates them at tick 120 (all register
`auto = true` and share one `core`); the gate numbers above are from one spike per invocation, as in Stage 1.

## New checksum and attribution

- Old (Stage 1): **3400134649**. New (Stage 2): **713316852**, reproduced on two consecutive two-run checks.
- Attribution: the new `colony-armory` entity/item/recipe plus its technology change Factorio's prototype-table
  hash. Towns with no Armory or militia execute no new behaviour: `m1_colony` passes the same 116 checks, the
  bench is unchanged (~0.57–0.61 ms/tick), and the shared damage handler is a no-op without manned posts.
  (A scripted `on_entity_damaged` subscriber is registered at load time in all towns, but it only reads state
  when an enemy damages a structure inside territory.)

## Deviations from PLAN.md / interpretation calls

- **"Manned" for partial manning.** Owner text says "equipped that many militia"; the aura *scales with equipped
  count*, so an Armory with limit 2 and 1 equipped is treated as one manned post (`aura(1) = 0.10`) rather than
  all-or-nothing. A limit of 0 is fully inert, as specified.
- **Armory strength model is a design choice, not an engine fact.** Stage 0 proved heal-back is the only viable
  lever (no native per-structure reduction flag); the 0.10/post, 0.50 cap and 24-tile radius are new balance
  constants, pinned by unit tests and the in-game ratio check.
- **Tower strength** is `aura(min(posted guards, 4))`, i.e. the same function over a posted-guard count — one
  rule for both structures, as requested.
- **No blueprint-tag persistence for the manning limit.** PLAN only required survival in `storage` and a docked
  GUI; the limit lives in `colony.armories` (plain data, save/load-tested). Ghost/copy-paste persistence of the
  limit would need the #36 tag channel and is a follow-up, not a Stage 2 requirement.
- **New art was generated** (`scripts/gen_art.py armory`, three PNGs + one manifest row) rather than reusing the
  Watchtower sprite; the filtered generator run deliberately leaves the rest of `art_manifest.lua` untouched.

## What the adversarial reviewer should scrutinise

1. **Double mitigation with militia armour.** `armory.mitigate` returns early for `type == "unit"` / `"character"`
   and requires `ev.force.name == "enemy"`; militia armour is healed separately in `scripts/militia.lua` with
   `armour.mitigation`. Check no structure path applies both, and no friendly fire (or enemy on enemy) is healed.
   The spike asserts an enemy inside the aura still loses health.
2. **Heal-back stability.** `e.health = hp + min(healed, max_health - hp)` is applied on `on_entity_damaged`;
   Stage 0/1 proved setting health does not recurse. Check the `hp <= 0` guard really prevents revive (spike
   lethal-hit case), that a damaged-but-alive structure cannot drift upward over hundreds of ticks (spike
   "no runaway healing"), and that the reduction ratio is the pure model's, not double-applied.
3. **Shared handler with #61.** The alarm raise and the aura now live in one `on_entity_damaged` subscriber;
   `m1_shelter` (14/14) is green, but check the order of operations: `M.raise` runs first, `mitigate` second, and
   neither returns early for the other's cases. In particular, an alarm shelters **civilians**, not posted guards
   (`alarm.EXEMPT`), so the tower post check in `m3_armory` cleared test-raised alarms first — a real raid should
   not silently remove the aura because guards do not shelter.
4. **Registry save/load.** Migration `[40]`, `M.register`, `on_object_destroyed` cleanup, `M.list` pruning and
   `m1_persist` (registry + limit + chest) must all agree. Gear drawn from an Armory stores a **unit number**,
   never an entity; if the Armory is mined, `M.put` falls back to the hall and `M.posts` drops the post.
5. **Gear contention / duplication.** Two militia drawing in the same tick must not both claim the same rifle;
   `gear_source` reads the live chest each time and `M.take` removes immediately. A manned Watchtower's rifles
   are still never a militia source, and `haul_plan.match`'s "never source from the requester's own stock"
   prevents an Armory hauling its own restock to itself. `m3_militia` (32/32) covers the tower case.
6. **Determinism of `posts`.** `M.posts` iterates `pairs()` over armories/towers but `defence.coverage` always
   picks nearest + key tie-break, so iteration order cannot change mitigation. The two-run checksum is stable.
