# PLAN — Minimal "Cultural Insights" tourism (#51)

> Planner deliverable for the plan → implement → adversarial-review pipeline.
> Working tree: `colony-worktrees/m2-tourism`. Do not touch the main checkout.
> Issue #51 body is only "Anti-exploit checks"; the mechanics below are this plan's
> concrete definition. #21 (`gh issue view 21 --comments`) decided commuting and
> explicitly left tourism open. Design doc §6.3 / §10.4 are the source inspiration.

---

## 0. Scope, pillars and reuse

Build the smallest slice that produces a **Cultural Insight** while honouring the
opt-in pillar and reusing — not replacing — the landed passenger-rail machinery:

* **Reuse:** `model/transit.lua` + `scripts/transit.lua` (#49) for board/alight and
  `storage.coaches[wagon]` groups; `scripts/work.send_to_platform` (#49) for the walk
  to the platform; `model/commute.lua` + `scripts/commute.lua` (#50) as the exact
  template for "guest colonists whose beds are held at home"; Tavern-style
  evaluation-time desirability (#48); `model/desirability.lua` components.
* **No new item / no new technology tree node / no vanilla prototype edit.** Cultural
  Insights is a **plain per-colony stat** that grants a **desirability bonus** at the
  home town and a small hospitality bonus at the host. (Why not a science-pack
  ingredient: that would pull in M4's #69 second-tier tree and the `m1_tech` audit.
  Wiring insights into science is listed as an open question in §6.)
* No runtime `require` — everything cross-module goes through `M.bind` (AGENTS.md).
  Lua 5.2, no functions in `storage`, all new state keyed by `unit_number` or colony
  id as plain data, no per-tick scans, locale audit green.

---

## 1. Concrete minimal mechanic

### 1.1 Building: the **Spa** (`colony-spa`)

Pick one; I pick the **Spa**, and justify against the alternatives:

* **Spa — chosen.** A single-purpose, worker-free 2×2 amenity. It is a natural
  "destination" without duplicating any existing system: it needs no beds (unlike a
  Hotel, which would overlap housing tiers #43/#96), no job or tool (unlike a theatre
  or tavern), and no vague multi-building footprint (a "Resort" implies houses +
  amenities + scenery). Its water/scenic theme fits design §6.3 for free and it can
  be a simple registry entry like the Tavern/Canteen.
* Hotel: rejected — reimplements housing/occupancy and the `away` bed ledger.
* Resort: rejected — a town, not a building; out of scope for a minimal slice.

Prototype shape: a 2×2 `container`/`chest` clone (exactly the `chest_clone` helper
used for `colony-passenger-platform` and `colony-canteen`, `buildings.lua:109-111`),
minable, built inside colony territory (same `territory.owner_at` guard as every
other colony building). **Unlocked by the existing `colony-rail-transit` technology**
(add an `unlock("colony-spa")` effect) — tourism requires rail, so no new tech
prototype and no `m1_tech` graph change beyond one unlock row. No new art file:
reuse `icon-tavern.png` (see §5.4).

Spa state: `colony.spas[unit_number] = {entity, colony_id}` (plain data). It has
**no worker and no inventory logic** in this slice. Each Spa hosts `SPA_CAPACITY = 2`
visitors; host demand is `2 * #spa_list(host)`.

### 1.2 How a tourist becomes one, and from where

* A tourist is an **idle colonist** (`st.state == "idle"`, no job, no job lock, not a
  child) of a **home colony** that has a Passenger Platform serving a train stop.
* The home only sends tourists while it is **daytime** (`work.is_sleep_time` false)
  and there is a **different** colony on the same surface with (a) a Spa, (b) a
  platform serving a stop, and (c) free visitor capacity after subtracting tourists
  already visiting or riding to it. This is the "host demand" gate.
* Numbers: `HOME_TOURIST_CAP = 2` (concurrent tourists away per home, beds held in
  `colony.away` exactly as commuters do), `SPA_CAPACITY = 2` visitors per Spa,
  `MAX_SEND_PER_EVAL = 1` (one new departure per home per evaluation — keeps the
  effect paced and makes the anti-farm bound easy to reason about).
* Selection is deterministic: sort candidate unit numbers ascending, take the first
  `n` (same idiom as `commute.run_home` / `transit.depart`, `commute.lua:206-216`).
  `work.send_to_platform(colony, un, platform, {tourist = true, tourist_host = host.id},
  "tourist 🚉")` abandons the current trip and walks the colonist to the platform.

### 1.3 The rail trip (the landed coach pattern, end to end)

Four real steps; each step is the same engine path commuters use:

1. **Board at home.** At `on_train_changed_state`/`wait_station` at the home stop,
   waiting tourists (`st.tourist`) board the coach, their entities are destroyed,
   and a group is recorded in `storage.coaches[coach.unit_number].groups`:
   `{kind = "tourist", from = home_id, home = home_id, host = host_id, n, stops = 0}`.
   Home beds are held: `home.away += n`.
2. **Alight at host.** When the train `wait_station`s at the host stop, the
   `"tourist"` group alights **only if `here == group.host`** (pure rule in
   `model/transit.alight`). Entities spawn at the host platform and are registered
   in `storage.tourists[un] = {home = home_id, host = host_id, until = tick + VISIT_TICKS}`.
   **No payout here.** A `"tourist"` group that cannot find its host within
   `RETURN_AFTER = 4` stops is routed home with `visited = false` — still no payout.
3. **Visit.** Tourists are host *visitors*, not residents: `state = "visiting"`
   (so `work.assign` never gives them a job), excluded from host population,
   migration, leave and desirability the same way `commute.here` is excluded today
   (`colony.lua:1488`). The visit ends at nightfall or after `VISIT_TICKS = 6000`
   (half a `commute.SHIFT_TICKS` day), then `work.send_to_platform(host, un, p,
   {tourist_return = true, tourist_home = home_id, tourist_visited = true}, "heading
   home 🚉")`. A host with no platform or a stranded >`STRANDED_TICKS` (7200) walk
   sends them home on foot with **no insight**.
4. **Board at host / alight at home.** At the host stop the returners board as
   `{kind = "tourist_return", from = host_id, home = home_id, host = host_id,
   visited = true, n, stops = 0}`; `storage.tourists[un]` is cleared. At the home
   stop the group alights **only if `here == group.home`**; entities spawn at the
   home platform, `home.away` is released, and the insight is credited **here and
   only here**.

### 1.4 What Cultural Insights yields (numbers)

* **Stat:** `colony.insights` — integer count of *completed round trips* credited to
  the home colony. Shown on the Town Hall panel/ledger.
* **Decaying bonus stat:** `colony.recent_insights`, decayed once per colony
  evaluation by `0.5 ^ (1 / INSIGHT_HALF_LIFE)` with `INSIGHT_HALF_LIFE = 12`
  evaluations (mirrors the death half-life mechanism, `model/desirability.lua:41-46`).
* **Desirability:** two new *bonus-only* components in `model/desirability.compute`:
  * `w_tourism = 0.10` × `clamp(min(recent_insights, 2.0), 0, 1)` at the **home**
    (`tourism_cap = 2.0`) — a completed cultural exchange makes a town more attractive.
  * `w_hospitality = 0.05` × `clamp(current visitors, 0, 2)` at the **host**
    — a Spa with guests is a small pull. No penalty when there are none.
* **Payout throttle:** at most one insight per `INSIGHT_COOLDOWN = 600` ticks per
  home colony (`colony.last_insight_tick`), defence-in-depth on top of the
  group-consumption guard (§2).
* **Output per trip:** exactly **1 insight per rider** on a credited return batch
  (so a 2-person group gives 2), bounded by `HOME_TOURIST_CAP = 2` concurrent trips
  and the 6000-tick visit. There is no item, no currency stack, no lab effect.

---

## 2. ANTI-EXPLOIT section (the issue's entire body)

The payout rule is the spine: **an insight exists only as the consumption of a
`kind = "tourist_return"` coach group that actually alighted at its home after a
verified host visit.** Every guard below is implemented in a pure function in
`model/tourism.lua` / `model/transit.lua` and pinned by a unit test + a spike check.

| Exploit | Specific guard |
|---|---|
| **Teleport loop** — payout without a rider physically moving | Tourists use the identical `work.send_to_platform` → `on_train_changed_state` (`wait_station`) → `storage.coaches` → `spawn_colonist` path as #49/#50. There is no code path that credits an insight from a timer or from a colonist standing at home; credit is raised only in the alight branch of the `wait_station` handler. |
| **Duplicate payout on repeated arrivals** | `model/transit.alight` *removes* the group from `left` and returns it in `offs` only when it actually alights; credit is emitted per `offs` batch inside that same handler. A second `wait_station` at the same stop has no group left to alight, so it pays nothing. `M.earns_insight(group, here)` additionally requires `kind == "tourist_return"`, `group.visited == true`, `group.host ~= nil`, `group.host ~= group.home` and `here == group.home`. |
| **Duplicate payout across save/load** | Groups, visit records and `colony.insights`/`last_insight_tick` are all plain data in `storage` (schema 42). Loading restores the *un-alighted* group; nothing re-fires an engine event on load. The 600-tick `last_insight_tick` cooldown is a second barrier against a re-run of a batch. No "paid" flag is stored that could be duplicated — the group itself is the single source of truth and is destroyed on payout. |
| **Payout without a completed trip** | `visited = true` is set *only* by the host-side return boarding, which only happens after a tourist was actually registered by `tourism.arrive_at_host` at a colony that has a Spa and after the visit timer/night condition. `M.earns_insight` returns false without it. A group diverted before reaching the host (or that reaches a Spa-less colony) carries `visited = false` and pays nothing. |
| **Farming by shuttling one colonist back and forth** | A payout requires a full board→host→visit→board→home cycle with `VISIT_TICKS = 6000` of real time; two outbound tourists max (`HOME_TOURIST_CAP`), one new departure per evaluation, and a 600-tick per-colony payout cooldown. The returning colonist is a *new* unit number, so there is no persistent identity to reuse — every insight still costs a whole physical round trip. |
| **Payout from a colony to itself** | `M.host_ok(home_id, host_id)` rejects `host_id == nil` or `host_id == home_id` at departure; the board handler refuses to set `host` equal to `from`; `M.earns_insight` requires `host ~= home` and `here == home`. A one-colony rail loop can never generate an insight. |
| **Per-tick scan for eligible tourists** | Eligibility is decided once per colony evaluation inside `tourism.evaluate(colony)` (called from `colony.evaluate` next to `commute.evaluate`, `colony.lua:1490`), reading only the small `colony.spas` registry and `storage.tourists`. Boarding/alighting are event-driven on `on_train_changed_state` only. Nothing runs on `on_tick`. |
| **Tourists abusing host/house systems** | While visiting, a tourist is excluded from host residents: `storage.tourists[un]` is checked alongside `commute.is_commuter(un)` in `live_colonists`, desirability, leave and homeless math; `state = "visiting"` keeps `work.assign` from assigning a job; no child is ever sent (`storage.age[un].stage == "child"` guard, as `transit.depart` already does). |
| **Coach destroyed / mined** | `scripts/transit.lua`'s `on_entity_died` / `on_object_destroyed` handlers call `tourism.coach_lost(rec)`: outbound groups release the home's held beds with **no insight**; return groups simply clear their visit record. No `mortality.record` for tourists *unless* a visiting tourist is killed by an actual engine death (then it is the home's death, reusing `commute.died`'s attribution). |
| **Bed leak / stranded tourist** | Beds are held at boarding and released on: alighting home, coach loss, or the 7200-tick stranded walk-home. Same lifecycle as commuters, so a lost tourist cannot permanently shrink home capacity. |

---

## 3. Pure model module and thin adapter wiring

### 3.1 `mod/scripts/model/tourism.lua` — PURE (no `game`/`storage`/`script`/`defines`)

Constants: `SPA_CAPACITY = 2`, `HOME_TOURIST_CAP = 2`, `MAX_SEND_PER_EVAL = 1`,
`VISIT_TICKS = 6000`, `STRANDED_TICKS = 7200`, `INSIGHT_COOLDOWN = 600`,
`INSIGHT_HALF_LIFE = 12`, `W_TOURISM = 0.10`, `W_HOSPITALITY = 0.05`,
`TOURISM_CAP = 2.0`, `HOSPITALITY_CAP = 2`.

Pure functions (all offline-testable, integer/deterministic, no `pairs` over world):

* `M.host_ok(home_id, host_id)` → boolean (§2 self-payout guard).
* `M.departures(idle, want, waiting, cap)` → integer, same shape as `commute.to_send`.
* `M.visit_over(now, ends, night)` → boolean.
* `M.earns_insight(group, here)` → boolean (the exact §2 credit predicate).
* `M.decay(recent, half_life)` → number (one evaluation of half-life decay).
* `M.tourism_bonus(recent, w, cap)` / `M.hospitality_bonus(visitors, w, cap)` → number.

`model/transit.lua` gains the two pure alight cases inside `M.alight`:
`kind == "tourist"` → alight when `here == g.host`; `kind == "tourist_return"` →
alight when `here == g.home`. `offs` entries gain `host`/`visited` fields (additive,
backward compatible).

### 3.2 Thin adapters

* **`mod/scripts/tourism.lua`** (new) — owns all engine-facing work, injected with
  `M.bind(colony_mod, transit_mod)`:
  `M.is_tourist(un)`, `M.here(colony)` (visitors currently at this host),
  `M.evaluate(colony)` (host side: end visits, send returners to platform, stranded
  walk-home; home side: pick idle tourists and send to platform),
  `M.arrive_at_host(colony, spawned)`, `M.arrive_home(colony, batch)`,
  `M.coach_lost(rec)`, `M.died(un)`. All read/write plain `storage` records.
* **`mod/scripts/transit.lua`** — add `M.bind_tourism(t)`; in its single
  `on_train_changed_state` handler: include `st.tourist`/`st.tourist_return` waiters
  in `waiting_at`/the boarding loop (new group kinds, beds held/released at boarding),
  and in the alight loop dispatch `tourism.arrive_at_host` / `tourism.arrive_home`.
  In `each_origin` (coach destroyed/removed) call `tourism.coach_lost`.
* **`mod/scripts/colony.lua`** — `require("scripts.model.tourism")` is not needed
  directly, but the adapter is required and bound; `M.SPA = "colony-spa"`,
  `M.spa_list(colony)` (stable unit-number order, same as `platform_list`),
  `on_built` registration for the Spa, `on_object_destroyed` cleanup, call
  `tourism.evaluate(colony)` beside `commute.evaluate(colony)`, subtract
  `tourism.here(colony)` in the resident math, decay `recent_insights` and feed the
  new desirability inputs, publish `insights` in `stats`, and add `tourism.bind(M,
  transit)` / `transit.bind_tourism(tourism)` at the existing bind site
  (`colony.lua:2087`).
* **`model/desirability.lua`** — add the two bonus components and their defaults.
  Pure, so its unit tests extend naturally.

No module is loaded at runtime with `require` from another adapter (cycles are
broken by `bind`, exactly as today).

---

## 4. Engine facts to verify (official API docs)

All facts below are already exercised in-repo by `m1_rail`/`m1_commute`; the docs
are cited so the implementer re-confirms exact 2.1 signatures before coding.

1. **`on_train_changed_state`** — "Called when a train changes state (started to
   stopped and vice versa)"; the hook carries `ev.train`. The existing handler
   gates on `train.state == defines.train_state.wait_station` and `train.station`.
   URL: <https://lua-api.factorio.com/latest/events.html>
2. **`defines.train_state.wait_station`** — "Waiting at a station." (confirmed in
   the 2.1.25 defines docs). URL: <https://lua-api.factorio.com/latest/defines.html>
3. **`LuaTrain`** members used: `state` (defines.train_state), `station`
   (LuaEntity?), `cargo_wagons` (array[LuaEntity]), `valid`, `id`. Confirmed on
   the 2.1.25 class page. URL: <https://lua-api.factorio.com/latest/classes/LuaTrain.html>
4. **`script.register_on_object_destroyed(entity)` / `on_object_destroyed`** — the
   event has a `useful_id` (uint64) matching the second value returned by
   `register_on_object_destroyed`; this is how coach loss is detected without a
   per-tick scan (used in `scripts/transit.lua:249-260`).
   URLs: <https://lua-api.factorio.com/latest/events.html>,
   <https://lua-api.factorio.com/latest/classes/LuaBootstrap.html>
5. **`LuaEntity.destroy` / `unit_number`, `LuaSurface.create_entity`** — boarding
   destroys the colonist entity and alighting spawns a new one at the platform;
   `game.get_entity_by_unit_number` cannot see units in 2.1 (already learned in
   `m3_patrol`), so the adapter must carry the live entity, never re-look it up.
   URL: <https://lua-api.factorio.com/latest/classes/LuaEntity.html>
6. **No new item**, so `LuaItemStack` / `spoil_percent` verification is *not*
   required for this slice. (If §6's optional science-pack follow-up is later
   chosen, verify <https://lua-api.factorio.com/latest/classes/LuaItemStack.html>
   for `spoil_percent` and the pack's `spoil_ticks`.)

---

## 5. File-by-file changes, schema, locale/art, tests, determinism

### 5.1 New files
* `mod/scripts/model/tourism.lua` — the pure rules (§3.1).
* `mod/scripts/tourism.lua` — the thin adapter (§3.2).
* `mod/scripts/spike/m2_tourism.lua` — headless end-to-end spike (§5.5).
* `tests/tourism_test.lua` — offline unit tests (§5.5).

### 5.2 Modified files
* `mod/scripts/model/transit.lua` — two new alight cases + `offs` fields.
* `mod/scripts/model/desirability.lua` — `w_tourism`/`w_hospitality` defaults + components.
* `mod/scripts/transit.lua` — `bind_tourism`, board/alight branches, coach-loss hook.
* `mod/scripts/colony.lua` — require/bind, `SPA` constant, `spa_list`, `on_built`/
  `on_object_destroyed`, `tourism.evaluate` call, resident exclusions, desirability
  inputs + decay, `stats.insights`, panel row.
* `mod/scripts/store.lua` — migration [42], bump `SCHEMA = 42`.
* `mod/prototypes/buildings.lua` — `colony-spa` container prototype, item, recipe
  (`colony-spa` recipe, wood/stone-brick/iron-plate cost, unlocked by rail transit).
* `mod/prototypes/technology.lua` — add `unlock("colony-spa")` to `colony-rail-transit`.
* `mod/locale/en/locale.cfg` — `entity-name/description`, `item-name/description`,
  `recipe-name`, `colony-message.*` (boarded, arrived at spa, insight earned,
  tourists walked, no host) and any `colony-gui`/`colony-status` row. The locale
  audit (`tests/locale_test.lua`) scans every literal `{"colony-…"}` key in
  `mod/scripts`, `mod/prototypes`, `mod/data.lua`, so **every literal key added must
  be present in the cfg** or `scripts/test.sh` fails.
* `mod/scripts/spike/loader.lua` — add `"m2_tourism"` to the loaded spike list
  (`loader.lua:3-11`); release packaging replaces this file with a stub.
* `tests/runner.lua` — require the new `tourism_test.lua`.
* `docs/factorio_colony_mod_design_document.md` §6.3 and `AGENTS.md` Decisions —
  record that tourism is implemented (per AGENTS.md rule 16), after the spike is green.

### 5.3 Schema / migration
`store.lua` `SCHEMA = 41 → 42`, add:
```lua
[42] = function()
  -- Tourism (#51): colony.spas [unit_number] = {entity, colony_id}; colony.insights,
  -- colony.recent_insights, colony.last_insight_tick; storage.tourists [unit_number] =
  -- {home, host, until}. Coach groups gain kind "tourist"/"tourist_return" plus
  -- host/visited fields, and unit_state gains tourist/tourist_host/tourist_return/
  -- tourist_home/tourist_visited markers. All plain data; LuaEntity refs re-resolve on load.
  storage.tourists = storage.tourists or {}
  for _, c in pairs(storage.colonies or {}) do
    c.spas = c.spas or {}
    c.insights = c.insights or 0
    c.recent_insights = c.recent_insights or 0
    c.last_insight_tick = c.last_insight_tick or 0
  end
end,
```
No functions in `storage`; `sanitize_functions` already guards the rest.

### 5.4 Locale / art
* Art: none required — reuse `graphics/icon-tavern.png` (or `icon-passenger-platform.png`)
  for the Spa icon. If a distinct icon is wanted, add a file + `mod/prototypes/art_manifest.lua`
  entry, but that is explicitly optional and outside the minimal slice.
* Locale: add all keys used; keep messages as native localised strings via
  `force.print({"colony-message.…", ...})`, never concatenated raw text.

### 5.5 Tests + spike
* **`tests/tourism_test.lua`** (target ~20 checks):
  `host_ok` rejects nil/self; `departures` bounds; `visit_over` at night/expiry;
  `earns_insight` true only for a completed, non-self, home-alighting return group
  (and false for: arrival at host, self-host, missing visited, wrong `here`, a
  `"tourist"` outbound group, a diverted group); `decay` half-life; bonus caps;
  `transit.alight` tourist cases (alight only at host/home, `offs` carries host/
  visited, groups survive a non-matching stop).
* **`mod/scripts/spike/m2_tourism.lua`** (~18-22 checks). Mirror `m1_commute`/
  `m1_rail` geometry (rails on odd rows, stops offset from the rail row, loco-coach-
  loco with a 2-stop schedule, day frozen, migration off). House A = home with idle
  colonists + platform; house B = host with a Spa + platform. Assert:
  1. two separate colonies, both platforms serve stops, Spa built inside B's territory;
  2. a home tourist walks to the platform and boards (`storage.coaches` group `kind=="tourist"`);
  3. home `away` increases by the boarding count;
  4. **no insight on arrival at the host**, `storage.tourists` records the visit;
  5. **no second payout when the train waits at the host again**;
  6. after `VISIT_TICKS`, the tourist boards home as `kind=="tourist_return", visited=true`;
  7. **exactly one insight per rider on arrival home**, `away` released, stat + panel agree;
  8. **no insight from the home to itself** (one-colony loop control);
  9. **no insight for a diverted group** (`visited=false`);
  10. **no insight and no bed leak on coach destruction** (`on_entity_died`);
  11. save/load round-trip preserves groups/visits/insights, and a post-load arrival
      still credits exactly once;
  12. tourists are excluded from host pop/desirability and never receive jobs;
  13. no payout at night / for a child / for a job-locked colonist.
  All harnesses pin `MAP_SEED` (default 1234567) for reproducibility.

### 5.6 Verification gates (from AGENTS.md)
`scripts/test.sh` (locale audit green) · `scripts/typecheck.sh` ·
`scripts/lint-determinism.sh` · `luajit -bl` on every changed Lua ·
`TICKS=… scripts/headless-spike.sh m2_tourism` · `scripts/save-load.sh` ·
`scripts/determinism.sh` · `scripts/bench-colony.sh` (#22 <1 ms/tick).
The spike must print no `[FAIL]`/`[ERR]` (bench-colony.sh fails on those).

### 5.7 Determinism / checksum
* **New prototypes move Factorio's prototype-table hash.** Adding `colony-spa`
  entity/item/recipe changes the two-run checksum for `m1_colony` — expected and
  documented (same as Patrol Post → 1550186985, Armory → 713316852, wake rotation
  → 2960604716). Re-baseline with `scripts/determinism.sh` and record the new value
  on #51 / in AGENTS.md Status.
* In the deterministic gate (`m1_colony`, no Spa built) no tourists are sent, so
  town evolution is unchanged apart from the hash. When a Spa + rail loop *is*
  present, tourist decisions are deterministic (sorted unit numbers, tick-based
  timers, no `math.random`, cached host list), so a two-run `m2_tourism` save must
  checksum identically.
* UPS: tourism adds one evaluation per colony (a few registry reads) and board/
  alight work only when trains with tourists stop — no per-tick cost. Re-check the
  #22 gate, which should be unaffected.

---

## 6. Risks and open design questions

1. **Yield vs. design §6.3 "Cultural Insights used in high-tier Colony Science".**
   Chosen minimal yield is a stat + desirability bonus. Open: should `colony.insights`
   become an ingredient in a Civic Treatise recipe variant (would touch `m1_tech`
   and pull in M4 #69)? Left out deliberately to keep the slice small.
2. **Host-side visitor accounting.** Tourists spawn as host colonists to use the
   platform machinery; every resident-facing counter must exclude them (§2). Risk:
   a missed call site in `live_colonists`/desirability/leave. Mitigation: a single
   `tourism.here(colony)` subtraction beside the existing `commute.here` sites,
   and the spike's "excluded from host pop" check.
3. **Group field compatibility.** `model/transit.alight` is shared by migrants,
   commuters and tourists; new `host`/`visited` fields must be additive and
   nil-safe so old saves' groups (#23/#26) keep alighting identically.
4. **Two handlers, one event.** All tourist board/alight logic must live in the
   *existing* `scripts/transit.lua` `on_train_changed_state` handler, never in a
   second registration, or the same group could be processed twice.
5. **"Luxury food/drinks" consumption** (design §6.3) is omitted: no upkeep item,
   just the capacity gate. Open: add a per-visit `colony-water`/ale cost from the
   Spa's chest, gated like the Smokehouse, as a later slice.
6. **Spa limit slider / "Grand Hotel" tiers** — fixed 2-visitor capacity now; a
   player limit and upgraded tiers are follow-ups.
7. **Research-speed "Inspired" half of #48** and Theatres stay untouched (separate
   work); this slice does not grant research speed.
8. **Death attribution** for a tourist killed while visiting is home-based (reuse
   `commute.died`), but this slice's spike only pins coach loss; engine-death of a
   visitor is a nice-to-have check, not a blocker.

---

## Summary (for the orchestrator)

**Mechanic:** a worker-free **Spa** (`colony-spa`, unlocked by Rail Transit, 2
visitors) makes a *different* rail-linked colony send up to 2 idle colonists as
tourists. They physically board a Passenger Coach at home (bed held in `away`),
alight at the host, spend 6000 ticks visiting, board home again, and on alighting
at home credit exactly one **Cultural Insight** per rider to the home's
`colony.insights` stat. Insights decay over 12 evaluations and grant a +0.10
desirability bonus at home (and +0.05 per current visitor at the host). No new
item or technology; Cultural Insights stays a pure stat.

**Anti-exploit guards:** board/alight only via the landed coach path (no teleport);
credit only on consumption of a `tourist_return` group at `here == home` (no repeat
arrival or save/load double-pay); `visited` marker set only after a real host visit
(no payout without a completed trip); 6000-tick visit + 2-tourist cap + 600-tick
payout cooldown (no shuttle farming); `host_ok` rejects self (no self-payout);
eligibility decided once per colony evaluation with no `on_tick` work (no per-tick
scan). Coach loss releases beds with no payout; visitors are excluded from host
resident systems.

**Top open questions:** (1) wire `colony.insights` into high-tier Colony Science
(M4 #69) or keep it a desirability stat? (2) add a luxury-food upkeep per visit?
(3) confirm the exact set of host resident call sites to exclude visitors; (4) new
prototype hash means `scripts/determinism.sh` must be re-baselined.
