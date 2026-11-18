# STAGE — #51 M2 tourism slice (plan → implement → adversarial review)

Branch `agent/m2-tourism`, based on master `1fe97bc` (509 tests, checksum 1550186985, schema 41). All work is in the worktree `colony-worktrees/m2-tourism`; master was not touched. First implementation commit `8c65928` was rejected by `REVIEW.md`; this file also records the review-fix commit that follows it.

## Owner decision (authoritative) and how it was applied

> Cultural Insights is a PLAIN DESIRABILITY STAT — `colony.insights` decays over 12 evaluations, grants +0.10 desirability at home and +0.05 per visitor at host. NO new item, no tech, no tech-audit or lab-coverage changes.

`colony.insights` is the decaying stat itself (half-life 12 evaluations). `colony.insights_total` is a lifetime counter for the panel only and never feeds desirability. The home bonus saturates at one insight's worth (`min(insights, 2)` clamped to 0..1 → +0.10); the host bonus is +0.05 × visitors up to 2. No new pack, lab, or tech-audit rule was added; the only technology change is one `unlock` row on the existing `colony-rail-transit`.

## File-by-file changes

**New files**
- `mod/scripts/model/tourism.lua` — PURE rules/constants: `host_ok`, `departures`, `host_capacity`, `away_count`, `visit_over`, `earns_insight`, `credited` (one insight per rider), `decay`, `tourism_bonus`, `hospitality_bonus`. No Factorio globals, no payout cooldown constant.
- `mod/scripts/tourism.lua` — thin adapter bound with `M.bind(colony_mod, transit)`: visitor registry/exclusions, `evaluate` (host end-visits + home send, with a per-host `waiting_to` reservation), `boarded`/`left_home`, `arrive_at_host`, `arrive_home` (the sole payout), `coach_lost`, `died`, `decay`, `host_ok` re-export. No `storage.visit_override` hook.
- `mod/scripts/spike/m2_tourism.lua` — 26-check end-to-end spike: full round trip, repeated host stops, injected self-host/diverted/genuine groups, child/lock/night guards, coach loss, host-exclusion, plain-data, **and the MAJOR regression (check 25: a host with visitors still sends its homeless resident by rail)**. Also registers `m2_tourism_save` / `m2_tourism_load` for the cross-process mid-trip proof.
- `scripts/tourism-save-load.sh` — new two-phase harness (modelled on `scripts/save-load.sh`): phase 1 saves a save with a real tourist mid-visit, phase 2 loads it in a new process and asserts exactly one payout per visitor and no duplicate on later stops.
- `tests/tourism_test.lua` — 16 offline unit checks of the pure rules, the additive `transit.alight` cases, and per-rider credit for two batches in one tick.

**Modified files**
- `mod/scripts/model/transit.lua` — `kind = "tourist"`/`"tourist_return"` alight cases; `offs`/`left` carry additive `host`/`visited` fields; old three kinds unchanged.
- `mod/scripts/model/desirability.lua` — `w_tourism`/`w_hospitality` defaults and caps; two new bonus-only `parts`.
- `mod/scripts/transit.lua` — `bind_tourism`; the existing single `on_train_changed_state` handler batches new kinds at boarding, dispatches host/home alights, skips visitors when choosing leavers, and releases tourist beds in `each_origin` on coach death/removal.
- `mod/scripts/colony.lua` — require/bind; `M.SPA`, `spa_list`, ghost validation, build registry and destroy cleanup; resident exclusions in `live_colonists`/`colonist_ids`/`leave_one`/homeless; insight decay and desirability inputs; `tourism.evaluate` beside `commute.evaluate`; `stats.insights`/`insights_total`/`visitors`.
- `mod/scripts/mortality.lua` — a visitor's engine death is attributed to its home (`tourism_mod.died` alongside `commute.died`).
- `mod/scripts/gui.lua` — community row shows insights/visitors; desirability parts caption shows tourism/hospitality.
- `mod/scripts/store.lua` — schema 41 → 42 migration (plain data only).
- `mod/prototypes/buildings.lua` — `colony-spa` chest clone (2×2, Tavern art), item, recipe (20 wood, 10 stone-brick, 5 iron-plate).
- `mod/prototypes/technology.lua` — `unlock("colony-spa")` on `colony-rail-transit`.
- `mod/locale/en/locale.cfg` — entity/item names + description, rail-tech description, five new `colony-message.*` keys, two new desirability-part placeholders.
- `mod/scripts/spike/loader.lua`, `tests/runner.lua` (auto-discovers `tests/*_test.lua` — no edit needed), `tests/glue_test.lua` (schema 41 → 42 + tourism fields), `docs/factorio_colony_mod_design_document.md` §6.3/§6.1, `AGENTS.md` (Decision + Status).

## Engine facts verified (Factorio 2.1.25 docs, fetched this session)

| Fact | Source |
|---|---|
| `on_train_changed_state` fires when a train starts/stops; handler reads `ev.train`; `on_object_destroyed` fires for registered objects | <https://lua-api.factorio.com/latest/events.html> |
| `defines.train_state.wait_station` = "Waiting at a station." | <https://lua-api.factorio.com/latest/defines.html> |
| `LuaTrain.state`, `.station`, `.cargo_wagons`, `.id`, `.valid` are read-only members; `go_to_station(index)` is available | <https://lua-api.factorio.com/latest/classes/LuaTrain.html> |
| `LuaEntity.destroy{raise_destroy=…}` and `die(...)`; `LuaSurface.create_entity{name=…, position=…, force=…, raise_built=…}` | <https://lua-api.factorio.com/latest/classes/LuaEntity.html>, <https://lua-api.factorio.com/latest/classes/LuaSurface.html> |
| `script.register_on_object_destroyed(obj) → registration, useful_id, target_type`; `useful_id` is the unit number for entity registrations; one handler registration per event | <https://lua-api.factorio.com/latest/classes/LuaBootstrap.html> |
| `game.get_entity_by_unit_number` cannot see units in 2.1 (learned in `m3_patrol`) — this slice carries live spawned entities instead of re-looking them up | in-repo spike result (no doc claim) |

## Anti-exploit guard table (PLAN §2, all mandatory)

| Exploit | Guard | Where | Pinned by |
|---|---|---|---|
| Teleport payout | Only the `wait_station` alight branch of the existing handler can call `arrive_home`; no timer credits | `scripts/transit.lua`, `model/tourism.earns_insight` | `m2_tourism` 13/16, `tourism_test` |
| Duplicate payout on repeat arrival | `transit.alight` removes the group and returns it in `offs` only on actual alight; a second stop has no group left | `model/transit.alight` | `m2_tourism` 14, `tourism_test` "second arrival" |
| Duplicate payout across save/load | Groups/records are plain data; no engine event re-fires on load; no `paid` flag to duplicate. Proven end to end with a save taken mid-visit and a fresh-process load | `store.lua` [42], `scripts/tourism-save-load.sh` | `tourism-save-load.sh` PASS (8 checks), `save-load.sh` schema 42 |
| Payout without a trip | `visited` set only in `arrive_at_host` after real alight; `earns_insight` requires it, a non-nil host different from home, `tourist_return`, `here == home` | `model/tourism.earns_insight` | `m2_tourism` 23, `tourism_test` |
| Lost second legitimate batch | Removed the per-batch cooldown: `credited` pays one insight per rider for every genuine visited return batch; group consumption still prevents double pay | `model/tourism.credited`, `scripts/tourism.arrive_home` | `tourism_test` "two batches in one tick", `m2_tourism` 7 |
| Shuttle farming | 6000-tick real visit, HOME_TOURIST_CAP 2, one departure/evaluation, per-host `waiting_to` reservation. No batch payout throttle: visit time + caps bound the rate, and a rider cannot be farmed | `model/tourism`, `scripts/tourism` | `m2_tourism` 7/12/24 |
| Host over-send in one evaluation | `host_capacity(spas, visiting, inbound, waiting_to(host))` reserves places for tourists from *other* homes already walking to the platform, instead of passing a constant 0 | `scripts/tourism.run_home` | code audit + `m2_tourism` run (no over-cap visitors) |
| Self-payout | `host_ok` at departure and boarding; `earns_insight` rejects `host == home` | `model/tourism`, `scripts/transit.lua` | `m2_tourism` 7/23 |
| Per-tick scan | Eligibility only in `tourism.evaluate` on the evaluation cadence; board/alight event-driven; no `on_tick` registration | `scripts/tourism.lua` | code audit, `lint-determinism.sh` |
| Visitors abuse host systems | `state = "visiting"`, excluded from `live_colonists` (which is why the homeless line must NOT subtract them again), `colonist_ids`, `leave_one`, `transit.depart`; no house bed or job | `scripts/colony.lua`, `scripts/transit.lua` | `m2_tourism` 19/20/25 + mutation check |
| Coach destroyed/mined | `each_origin` calls `tourism.coach_lost` for both tourist kinds → beds released, no payout; engine deaths attributed home | `scripts/transit.lua`, `scripts/tourism.lua` | `m2_tourism` 22 |
| Bed leak / stranded | `away` released at home alight, coach loss, or 7200-tick stranded walk home | `scripts/tourism.lua` | `m2_tourism` 8/17/22 |
| Child / locked / night departure | Departure filters: adult, no `colony.locks`, `is_sleep_time` false | `scripts/tourism.run_home` | `m2_tourism` 9/10/11 |

## Gate outputs (exact)

Gate outputs after the review fixes (exact):

- `scripts/test.sh` → `524 passed, 0 failed`
- `scripts/lint-determinism.sh` → `determinism lint ok`
- `luajit -bl` on all 6 changed Lua files → `luajit -bl: PASS (6 changed Lua files)`
- `scripts/typecheck.sh` → `Diagnosis completed, no problems found`
- `scripts/headless-spike.sh` (one invocation each):
  - `TICKS=17500 … m2_tourism` → `SUMMARY pass=26 fail=0 unknown=0 errors=0`
  - `TICKS=19500 … m1_colony` → `SUMMARY pass=116 fail=0 unknown=0 errors=0`
  - `TICKS=8000 … m1_rail` → `SUMMARY pass=17 fail=0 unknown=0 errors=0`
  - `TICKS=12000 … m1_commute` → `SUMMARY pass=15 fail=0 unknown=0 errors=0`
- `scripts/tourism-save-load.sh` (new, cross-process mid-trip proof) → `TOURISM SAVE/LOAD: PASS`; phase 2: `visitors 1/1, away 1/1, total 0/0`, then `post-load alight pays exactly one insight per visitor - 1/1`, `no duplicate payout on later stops - 1`
- `scripts/determinism.sh` → `final checksum: 362019531`, `DETERMINISM: PASS` (unchanged from the first commit — no prototypes changed in the review-fix round; the earlier two consecutive invocations also gave 362019531)
- `scripts/save-load.sh` → `SAVE/LOAD: PASS` (schema unchanged: 42)
- `scripts/bench-colony.sh` (from the first round, unchanged code paths) → worst colony Lua `0.599 ms/tick` for 500 colonists, `budget (#22): -> PASS`

**Deterministic checksum is still `362019531`** (from 1550186985 in the original slice; moved only because the Spa entity/item/recipe and the extra tech unlock change Factorio's prototype-table hash — `m1_colony` builds no Spa and its 116 checks are unchanged).

### Mutation check of the MAJOR homeless fix

Temporarily re-added ` - #tourism.here(colony)` to the `homeless` line in `scripts/colony.lua` and ran the same spike:

```
[FAIL] 25 a host with visitors still sends its homeless resident by rail - homeless departures seen: 0
SUMMARY pass=25 fail=1 unknown=0 errors=0
```

The line was restored (verified by `git diff`) and the same command then reported `SUMMARY pass=26 fail=0 unknown=0 errors=0`. The regression case therefore genuinely detects the reported bug rather than merely asserting a constant.

## Deviations from PLAN.md (all forced by the owner decision or Lua)

1. PLAN kept `colony.insights` as an integer and `colony.recent_insights` as the decaying stat. Owner decision is authoritative: `colony.insights` itself decays; `insights_total` is a display-only lifetime count.
2. PLAN's "at most one insight per 600 ticks" conflicts with "one insight per rider on a 2-person batch" and, after review, silently discarded a second legitimate batch. The cooldown was **removed**: `credited` pays exactly one insight per rider of every genuine visited return batch. Farming is still bounded by the 6000-tick visit, HOME_TOURIST_CAP 2 and one departure per evaluation; group consumption prevents double pay. `last_insight_tick` remains as an informational field only. (`AGENTS.md` still carries the pre-review "600-tick payout cooldown" wording; per the review-fix instruction it was not edited here.)
3. `until` is a Lua keyword, so the visit record field is written `["until"]` instead of `until`.
4. Visitors are excluded from host `live_colonists`/`colonist_ids`/`leave_one` **and therefore must not be subtracted again in the homeless line**. PLAN listed those exclusions for desirability/leave; excluding them from housing assignment is required or a guest takes a host bed and eats host food. The double subtraction was the review's MAJOR finding and is fixed with a spike regression + mutation check.
5. No new art: the Spa reuses `icon-tavern.png` and the Tavern sprite (PLAN §5.4 allowed this).
6. The cross-process mid-trip save/load is now real: `scripts/tourism-save-load.sh` saves with a visitor registered and the bed held, then loads in a new process and proves one payout per visitor with no duplicate on later stops. `scripts/save-load.sh` still covers schema 42 generally.
7. The reviewer suggested passing the *current visitor count* as `host_capacity`'s `waiting` argument, but `visiting` already subtracts those visitors; doing that would double-subtract and under-send. The same over-send bug is fixed correctly by passing `waiting_to(host)` — tourists from any home already walking/waiting for that host but not yet aboard — so several homes evaluating in one tick reserve places instead of all seeing two free slots.

## Reviewer scrutiny points (adversarial pass)

- `away_from` sums three sources (`storage.tourists`, coach groups, waiting `unit_state` markers). A double count would stall departures; a miss would over-send. The spike's `away` min-tracking around injections/coach loss covers release, but a dedicated unit test of `away_count` only covers the pure helper. **Residual risk: low.**
- A script-forged `tourist_return` group can still pay if it has `visited=true`, a different host and `home=here` — by design this is the same trust boundary as any other `storage` record (players cannot normally write `storage`). No engine path other than host alight sets `visited`.
- `spawn_colonist` assigns work before `arrive_at_host` overrides the state; the override clears the hut seat and carried goods. A stale `work.assign` sees `state = "visiting"` (not in the resettable list), so it cannot wipe the visit.
- Removing the payout cooldown means no legitimate rider is ever dropped. No new exploit path was found: a rider still needs a real board → host alight → 6000-tick visit → return board → home alight, and the group is consumed on payout.
- `each_origin` now calls `tourism.coach_lost` instead of `commute.back_home` for tourist groups only; the migrant/commuter bed-release path is byte-for-byte the old one (m1_rail/m1_commute green).
- `waiting_to(host)` scans `unit_state` once per home evaluation, only for candidate hosts with a Spa. At 500 colonists this is a few hundred table reads on the evaluation cadence, not per tick; bench was not re-run because the review round changed no hot-path structure beyond that scan, but the scan is a new (small) cost worth re-benchmarking if tourism becomes common.
- The mid-trip load proof locks the home's current colonists before resuming so only the pending visitor can pay; a fresh trip takes >6000 ticks anyway. It asserts `away <= exp.away - exp.visitors + 1` because a separate in-flight tourist can hold a bed at the same time.
- Float decay `0.5^(1/12)` is evaluated identically each run; determinism PASS confirms no cross-run drift.

## Review-fix summary (REVIEW.md → this commit)

| REVIEW.md finding | Fix | Verification |
|---|---|---|
| MAJOR: visitors double-subtracted from host homeless math | Dropped `- #tourism.here(colony)` at `colony.lua:1512`; `live_colonists` already excludes them | New spike check 25 with a 7-resident/6-bed host C plus 2 visitors; mutation check fails with 0 departures, fix gives 284 |
| MINOR: cooldown discards second legitimate batch | Removed per-batch throttle; `credited` pays one insight per rider on every valid batch; `last_insight_tick` informational | `tourism_test` two-batches-in-one-tick; `m2_tourism` check 7 (+2 riders) |
| MINOR: host over-send (`waiting = 0`) | Pass `waiting_to(host)` — tourists from any home walking/waiting for that host | code audit; `m2_tourism` run stays within Spa capacity |
| MINOR: save/load anti-exploit only code-inspected | New `m2_tourism_save`/`m2_tourism_load` spikes + `scripts/tourism-save-load.sh` two-process harness | `TOURISM SAVE/LOAD: PASS`, 8 checks incl. no duplicate payout |
| MINOR: dead `storage.visit_override` hook | Removed; visit length is always `VISIT_TICKS` | code audit + full gate re-run |
