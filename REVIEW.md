# Adversarial review — #51 Cultural Insights (M2 tourism)

**Date:** 2026-11-18
**Target:** branch `agent/m2-tourism`, commit `8c65928`, based on `1fe97bc`
**Reviewer verdict:** **CHANGES REQUESTED** (one MAJOR, several MINOR/hardening items)

## Scope of verification performed

Read `AGENTS.md`, `PLAN.md`, `STAGE.md`, issue #51 (body is only "Anti-exploit checks." — PLAN §2 is
therefore the contract), and `git diff 1fe97bc..8c65928`. All gates were re-run in the worktree:

| Gate | Result |
|---|---|
| `scripts/test.sh` | 523 passed, 0 failed |
| `scripts/lint-determinism.sh` | determinism lint ok |
| `scripts/typecheck.sh` | "Diagnosis completed, no problems found" |
| `luajit -bl` on all changed Lua | PASS |
| `TICKS=17500 scripts/headless-spike.sh m2_tourism` | 24/24, no FAIL/ERR |
| `scripts/determinism.sh` | checksum **362019531**, PASS twice |
| `scripts/save-load.sh` | PASS |
| `TICKS=19500 m1_colony` (inside determinism) | 116/116 |

The claimed numbers are accurate. The round trip in `m2_tourism` is **real**: checks 12–17 drive
`work.send_to_platform` → `on_train_changed_state/wait_station` → `storage.coaches` → `spawn_colonist`
for both legs (spike `m2_tourism.lua:70-101`, `scripts/transit.lua:123-236`). The "insight at first visit
= 0" and "first insight at t=9600, away=0" lines confirm no early payout and bed release. The first
insight is observed as `0.94387431268169`, exactly `0.5^(1/12)`, confirming evaluation-cadence decay.
The self-host / diverted / genuine-2-rider batches in checks 7–8 are injected script groups, but they
exercise the real alight handler, and check 16 covers the genuine engine trip; that split is acceptable.

## Anti-exploit audit (PLAN §2) — all guards present

- Payout only on real alight: sole credit site `scripts/tourism.lua:94-104`, reached only from the
  `offs` loop at `scripts/transit.lua:154-158`. No timer credits.
- Group consumed on payout: `rec.groups = left` at `scripts/transit.lua:143` precedes dispatch;
  `tests/tourism_test.lua:117-123` pins "second arrival pays nothing".
- `visited` marker: set only by `run_host` after `visit_over` (`scripts/tourism.lua:184-188`) and carried
  through boarding (`scripts/transit.lua:205`); `earns_insight` requires it (`model/tourism.lua:58-62`).
- 600-tick cooldown: `scripts/tourism.lua:98`.
- 2-tourist cap: `away_from` + `HOME_TOURIST_CAP` (`scripts/tourism.lua:146-165,216`).
- Self-link rejection: `host_ok` at `scripts/transit.lua:200`, `model/tourism.lua:28-30`, and again in
  `earns_insight` (`host ~= home`).
- No per-tick scan: no `events.on(on_tick)` anywhere in the new code; all work is evaluation/event driven.
- Coach loss: `each_origin` → `tourism.coach_lost` (`scripts/transit.lua:246-255`), beds released, no payout
  (spike check 22).
- Visitors excluded from jobs/beds/leave: `state="visiting"`, `colonist_ids`/`leave_one` guards
  (`colony.lua:295-308,1185`), spike checks 19–20.
- Save/load: schema 42 migration is plain data (`store.lua:315-329`); no functions or entity refs added
  by the migration.

I tried and failed to construct a duplicate payout, a self-payout, a payout after coach destruction,
or a payout on load — all are blocked by the group-consumption + `earns_insight` predicate. The admitted
script-forged-group path is the same trust boundary as `storage.coaches`/`storage.commuters` (players
cannot write `storage` without a mod); **acceptable**.

---

## MAJOR — visitors are double-subtracted from the host's homeless count

**Evidence:** `mod/scripts/colony.lua:286` and `mod/scripts/colony.lua:1512`.

`M.live_colonists` was changed in this commit to *exclude* visitors:

```lua
elseif not tourism.is_visitor(id) then
  n = n + 1   -- #51: a guest at a Spa is not a resident of the host town
```

but the homeless calculation was *also* changed to subtract them again:

```lua
local homeless = M.live_colonists(colony) - #commute.here(colony) - #tourism.here(colony)
  - M.capacity(colony) - transit.waiting_count(colony)
```

In contrast, commuters are still *counted* in `live_colonists` and then subtracted explicitly — that
is the (correct) pre-existing pattern from master `1fe97bc:1488`. Visitors are the only population
excluded twice.

**Reproduction (arithmetic, line 1512):** a Spa host with 3 residents, capacity 2, 1 visitor, no
commuters/waiters. `live_colonists = 3` (visitor excluded), `#tourism.here = 1`, so
`homeless = 3 - 0 - 1 - 2 - 0 = 0`, but the true figure is `3 - 2 = 1`. The genuinely homeless
resident is therefore **not** sent to another colony by `transit.depart(colony, 0, homeless)` at
line 1513. With two visitors the undercount is 2, and so on up to `SPA_CAPACITY`.

**Impact:** a real behavioural regression of the #49 rail-departure path on any host town that has
both visitors and homeless residents. It does not affect insights, desirability or the anti-exploit
guards, and the spike does not catch it because host B has zero residents.

**Fix:** remove `- #tourism.here(colony)` from line 1512; the exclusion at line 286 already does the
job. (Alternatively revert the exclusion at 286 and keep the subtraction, but then visitors would
be counted as host residents in desirability/population.)

## MINOR — cooldown silently discards a second legitimate return batch

`mod/scripts/tourism.lua:96-102` releases beds, then checks `last_insight_tick`, then credits. Two
`tourist_return` batches from the same home that alight within 600 ticks (possible when nightfall
ends two staggered visits together, since `visit_over` returns true on night regardless of
`VISIT_TICKS`) pay only once; the second group is consumed with no insight. STAGE §Deviation 2
documents this as intentional defence-in-depth, but it conflicts with PLAN §1.4's "exactly one
insight per rider on a credited return batch" and is user-visible. Recommend either carrying the
cooldown credit over to the next batch or documenting the loss in the panel tooltip.

## MINOR — host over-send within one evaluation

`mod/scripts/tourism.lua:231` passes `0` as the `waiting` argument of `host_capacity`, so the
"tourists waiting at *another* home for this host" are not subtracted. Several homes evaluating in
the same tick all see the full 2 slots and can each send one tourist to the same Spa in that tick
(`HOME_TOURIST_CAP` still bounds each home). STAGE line 92 acknowledges this; it is a soft-cap
quality issue, not an exploit, but worth a shared per-host reservation if #51 is extended beyond
the minimal slice.

## MINOR — save/load anti-exploit path is not covered end-to-end

PLAN §5.5 item 11 asks for "save/load round-trip preserves groups/visits/insights, and a post-load
arrival still credits exactly once". The spike's check 21 (`m2_tourism.lua:164-175,295`) only walks
the tables for functions, and `scripts/save-load.sh` runs `m1_persist`, which builds no Spa/rail and
has no tourist groups. The "no duplicate payout on load" guard is therefore verified by code
inspection only. A two-process save/load of a save with a pending `tourist_return` group would close
this gap; the code itself looks correct (no event re-fires on load, group is the single source of
truth).

## MINOR — dead/overrideable visit-time hook

`mod/scripts/tourism.lua:79` uses `storage.visit_override or tourism.VISIT_TICKS`, but
`visit_override` is never set anywhere in the codebase (single grep hit). It is an untested external
hook that a script could set to 0 to eliminate the 6000-tick visit. Same storage trust boundary as
the forged-group caveat, but there is no reason to leave the surface in production code — remove it
or route it through a documented test-only injection.

## Non-findings (checked and rejected)

- **Return groups with no `RETURN_AFTER` fallback** (`model/transit.lua:60-62`): initially suspected
  as a bed leak if the home stop disappears. Rejected — the legacy `kind="return"` commuter group
  behaves identically (`model/transit.lua:47-48`); this is pre-existing design, not a tourism
  regression. Coach loss still releases beds.
- **Stat correctness:** `w_tourism=0.10` saturating at 1 insight and `w_hospitality=0.05` per visitor
  to cap 2 match the owner decision; `insights_total` is incremented only at the payout site and is
  display-only (`gui.lua:870-873`, `colony.lua:2566`). No double count.
- **STALE `spawn_colonist` work claim:** `arrive_at_host` clears the hut seat, calls `work.release`
  (which drops site claims and carried goods) and replaces `unit_state` before the visit starts
  (`tourism.lua:82-89`); spike check 20 confirms no visitor takes a host job or bed.
- **PURE/constraints:** `model/tourism.lua` has no Factorio globals; transit changes are additive;
  no runtime `require` across adapters (`tourism.bind(M, transit)` at `colony.lua:2129-2130`); Lua 5.2;
  no vanilla prototype edits; locale audit green; new Spa prototypes explain the checksum move.

## Recommendation

Fix the MAJOR one-line double subtraction at `colony.lua:1512`, add a regression assertion that a
host with visitors still sends its homeless residents, and re-run `test.sh`, `m2_tourism`,
`m1_rail`, `m1_commute` (the homeless line is in the shared evaluation path) plus determinism. The
MINOR items can be scheduled as follow-ups; none of them is a blocker for the slice's core mechanic.
