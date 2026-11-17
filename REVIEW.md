# Adversarial review — Command Whistle #58

## Re-review 2026-11-17 — fix commit 6e733ff (branch head; base ce63efc): **CHANGES REQUESTED**

I re-inspected `git diff ce63efc..HEAD` and `git show 6e733ff`, read §7 of IMPLEMENTATION.md,
re-ran the gates, and checked issue #58 with `gh`. **Three of my four prior findings are genuinely
resolved. One new MAJOR regression is present** in an area the fix itself touches indirectly:
a stale `construct.finish` timer can stomp a live lease back to `idle` and reassign the colonist,
defeating the central ORDER-vs-JOB guarantee. Details below; the original (4062172) review is
retained underneath for the record.

### Resolved findings

| Prior finding | Status | Evidence |
|---|---|---|
| **MAJOR** — commanded hunt credit lost | **RESOLVED** | `command.lua:75-78` now calls `work.release(st)` on the leased state before writing the fresh idle table — the same path as `work.assign` at `work.lua:2433`. `work.release` returns carry to the hall (spoilage to a bin), restores car/trailer and clears site claims. No function or entity ref is added to storage; `M.release_lease` is only exported on the module. `model/command.lua` is untouched, so the pure boundary is intact (the adapter already imported `scripts.work`). |
| Regression test / spike genuinely fail on old code | **VERIFIED BY INSPECTION** | `tests/command_test.lua` asserts `eq(#released, 1, "work.release must see the leased state")` against a mock `work.release`; without the call `released` is empty, so this assertion fails. The fresh idle table would make the later `carry==nil` check pass either way, so `#released` is the real guard. The spike asserts `hall.get_item_count("colony-meat") - before == 3`; without the call the hall stays at 0. Both are genuine. I did not mutate tracked files to run the mutation myself, per instruction. |
| **MINOR** — Stop tooltip overpromised | **RESOLVED** | `locale.cfg:176` now reads "releases the selection and stops colonists that are under a whistle order; ordinary workers just keep their current job and are deselected". |
| **MINOR** — selection circles global | **RESOLVED** | `command.lua:43-45` passes `players = {pi}`. Verified against the 2.1.25 LuaRendering docs: `draw_circle` takes `players` (array of `PlayerIdentification`), not `for_player`; `pi` (player index) is a valid identification. |
| Issue #58 gesture checklist / left open | **DONE** | `gh issue view 58 --json state,comments` returns `state: OPEN` with comment `6948524354` containing the 9-point in-game checklist. |

### Double-release / double-return: checked, safe

`release_lease` clears `s.leased[un]`/`s.owner[un]` first, then guards on
`if not model.is_commanded(st) then return end` (`command.lua:68-71`). `work.release(st)` sets
`st.state = "idle"` and the state is then replaced with a fresh idle table, so a second call from
completion + disconnect, completion + watchdog, or the `stop`-completion event sees `state ~=
"commanded"` and returns before `work.release`. Disconnect's `drop_player` only lists units still
in `s.owner`, which the first release already cleared. No double hall insert. Traced the other
carry producers: `work.finish` is state-guarded (`work.lua:2727`), the completion handler early-
returns for `commanded` (`work.lua:3047`, covering spoil-to-bin), and `work.assign` early-returns
for `commanded` (`work.lua:2412`) so no haul/build trip starts while leased. **Except** for the
finding below.

### NEW — MAJOR: stale `construct.finish` timer breaks a live lease

This is the one carry-path claim in IMPLEMENTATION.md §7 that is incomplete: it says
`construct.finish` "cannot create or lose goods", which is true, but it can **end the lease**.

**Evidence:**
- `model/command.lua:26-33` makes `building` and `repairing` orderable, and `:131` preserves
  `job = "construct"` in the leased state.
- `work.lua:3204` schedules `construct.finish` with `{un = ev.unit_number}` (the colonist) 30
  ticks (`construct.WORK_TICKS`) after it enters `building`/`repairing`.
- `work.lua:2923-2925` — the handler's **only** guard is `st.job == "construct"`; there is no
  `state` guard. The leased state passes it.
- `work.lua:2983-3003` — with no `site`/`kind`/repair packs on the leased state it falls into the
  repair branch (`packs = 0`, `st.carry = nil`), then at `:2997` does **`st.state = "idle"`** on the
  live leased state and at `:3003` calls **`M.assign(colony, d.un)`**. `M.assign` now sees `idle`
  (not `commanded`, and past the `:2426` protected-state check), picks a job and issues a fresh
  engine command that replaces the whistle order. `s.leased[un]` is only cleaned up later by the
  watchdog, which sees `is_commanded(st) == false` and silently drops the entry.

**Concrete reproduction:**
1. Have a builder with construction materials revive a ghost; it enters `state = "building"` and
   `construct.finish` is scheduled for tick B+30.
2. At tick B+5, hold the whistle and order that colonist elsewhere (MOVE). `apply` releases the
   build carry to the hall, writes `state = "commanded", job = "construct"`, issues
   `go_to_location`, and records the lease.
3. At tick B+30, `construct.finish` fires on the commanded state, sets it to `idle`, and calls
   `M.assign`. The colonist is reassigned; the whistle move is cancelled. The player sees the
   order ignored and the ⚑ label replaced by a work label while the lease is still nominally live.

**Impact:** the central promise — "an async reassignment never wipes a live order" — is false for
this path. Materials are not lost (they were already returned at order time), but the order is.

**Fix:** add `if model.is_commanded(st) then return end`-equivalent to `construct.finish`
(`work.lua:2925`), e.g. `if st.state ~= "building" and st.state ~= "repairing" then return end`.
That is the correct guard regardless of the whistle: the handler should only finish a construction
the unit actually reached. Consider the same guard audit for any future job-only timer. Add a
regression (a `construct.finish` job scheduled while the unit is `commanded` must leave the lease
intact), and re-run determinism — this guard changes no headless behaviour, so the checksum should
stay `328728317`.

### Gates re-run on 6e733ff

`scripts/test.sh` 466/0 · `s18_command` 20/20 (both `[integrated]` checks PASS, before=0 after=3)
· `lint-determinism.sh` ok · `determinism.sh` m1_colony 116/116, checksum **328728317 unchanged**,
PASS. (Prior review's typecheck, save/load and m1_tech results still stand; the fix touches none of
their inputs except one adapter call and two locale/spike lines.)

### What would make me approve

1. Guard `construct.finish` on `building`/`repairing` state (or `not commanded`) so a stale timer
   cannot end a lease; add the regression test.
2. Re-run the gates, especially determinism (checksum must stay `328728317`).
3. Fix the trivial doc drift in the #58 comment ("465 unit tests" vs final 466) if desired — not
   blocking.

---

# Original review — 4062172 (for the record)

## Verdict: CHANGES REQUESTED

The slice is well-engineered: the pure model is genuinely pure, the adapter is thin, the
input layer registers **both** the custom-input path and all four `on_player_*_selected_area`
gestures, the watchdog/scheduler design is save/load-safe by inspection, and every recorded
gate reproduces. I could not find a way for a lease to strand a haul trip, close a guard post,
break a coach group, or double-fire the watchdog. **But I found a concrete, reproducible
item-loss path** in which a leased hunter's kill credit is written into the `commanded` state
and then silently discarded on lease release. That is a correctness bug introduced by this
change and it needs a fix before merge.

---

## What I re-ran (all green)

| Gate | Result |
|---|---|
| `scripts/test.sh` | 465 passed, 0 failed |
| `scripts/lint-determinism.sh` | determinism lint ok |
| `scripts/typecheck.sh` | Diagnosis completed, no problems found |
| `luajit -bl` on all 7 changed Lua files | all compiled |
| `scripts/headless-spike.sh s18_command` | pass=18 fail=0 unknown=0 errors=0 (checksum of facts identical to IMPLEMENTATION) |
| `scripts/determinism.sh` (full, twice was claimed; I ran once) | `final checksum: 328728317`, m1_colony 116/116, DETERMINISM: PASS |
| `scripts/save-load.sh` | SAVE/LOAD: PASS |
| `scripts/headless-spike.sh m1_tech` | 13/13 |

I also verified `mod/scripts/model/command.lua` contains **no** Factorio globals and **no**
`require` (only comments mention `storage`/`defines`); no vanilla prototype is edited (all new
prototypes are `colony-*`); no runtime `require` was added (control.lua requires `scripts.command`
at load time, matching the existing pattern).

---

## Findings

### MAJOR — 1. A leased hunter's kill credit is credited to the commanded state, then thrown away

This is the concrete bad state the brief asked me to construct. It loses carried items (meat)
and is reachable with the new ATTACK_MOVE gesture, not only a narrow race.

**Evidence:**

- `mod/scripts/model/command.lua:131` — the lease preserves the old job:
  `job = ctx.jobs and ctx.jobs[un] or "idle"`. A leased hunter therefore has
  `state = "commanded", job = "hunt"`.
- `mod/scripts/work.lua:3360-3368` — the animal kill-credit handler keys **only on the job**,
  never on the state:
  ```lua
  events.on(defines.events.on_entity_died, function(ev)
    if ev.entity.name ~= wildlife.ANIMAL then return end
    local cause = ev.cause
    local un = cause and cause.valid and cause.unit_number
    local st = un and storage.unit_state[un]
    if not (st and st.job == "hunt") then return end
    ...
    st.carry[#st.carry + 1] = {item = "colony-meat", count = n}
  ```
  So any animal a `job == "hunt"` colonist kills while `state == "commanded"` deposits meat into
  the commanded state's `carry`.
- `mod/scripts/command.lua:67-81` — `release_lease` replaces the state with a **fresh table that
  has no `carry`**, and never calls `work.release(st)` first:
  ```lua
  storage.unit_state[un] = {colony_id = st.colony_id, job = st.job or "idle", state = "idle"}
  ```
  In the base code every "hand back to work" path funnels through `work.assign`, which does
  `if st and st.carry then M.release(st) end` (work.lua:2433) — that returns carry to the hall.
  `release_lease` is the **only** path that discards the whole state without a `work.release`,
  so the whistle introduces this loss.

**Concrete reproduction (no race needed):**
1. Staff a Hunting Lodge; a hunter has `job = "hunt"`.
2. Select it and issue **shift-right-drag Attack-Move** (`on_player_reverse_selected_area` →
   `ATTACK_MOVE` → `attack_area` with `distraction.by_enemy`, command.lua:283-286). The hunter
   is now `state = "commanded", job = "hunt"`.
3. The commanded hunter shoots and kills a boar inside the attack area. `on_entity_died`
   (work.lua:3360) sees `st.job == "hunt"` and appends meat to the commanded state's `carry`.
   For comparison, the spike already proves a commanded colonist attacks and kills targets
   (`[engine] attack_area ... biter_hp=dead`).
4. The `attack_area` command completes → `on_ai_command_completed` → `release_lease` replaces
   the state with `{colony_id, job="hunt", state="idle"}`. **The meat vanishes** — no ledger
   entry, no hall insert, no popup accounting.

A second, race-y variant: order a hunter mid-`hunting`; a parting hitscan kill after the order
lands credits meat into the commanded state that is then discarded.

**Impact:** lost food from every hunt conducted under a whistle order, and a general hazard —
any future subsystem that writes `carry`/`car`/`trailer`/`site_key` into a commanded state will
have it silently dropped.

**Suggested fix:** in `release_lease`, call `work.release(st)` on the commanded state before
replacing it (as work.lua:2433 does), so any kill-credit carry is returned to the hall. Guard
the call so it only runs when the state is actually commanded (it already early-returns
otherwise). Optionally harden the kill-credit handler with `st.state == "hunting"` — but that
is a behaviour change beyond this slice, so the adapter fix is the right one here. Add a unit
or integration test that credits a kill to a commanded hunter and asserts the meat reaches the
hall.

---

### MINOR — 2. "STOP only halts leased units" is safe and honestly documented, but is a real UX deviation

`mod/scripts/command.lua:139-158` and IMPLEMENTATION §5 item 5: pressing X on a selection of
ordinary workers does **not** issue an engine `stop`; it only deselects them. This is the correct
call — a scripted stop mid-`to_pickup` would make work.lua treat the completion as arrival and
corrupt the trip (work.lua:3104-3109). It is documented in both places. The only residual is
expectation management: a player pressing Stop on walking workers will see them keep walking. I
would not block on this, but the in-game tooltip should say so (the current item description at
locale.cfg:176 says "X (or middle-click) stops and releases the selection", which implies the
workers halt).

### MINOR — 3. Selection render circles are global, not per-player

`mod/scripts/command.lua:43-45` calls `rendering.draw_circle` with no `for_player`, so in MP every
player sees every other player's selection circles. Consistent with the mod's always-visible
labels, so cosmetic only. If MP polish matters, pass `for_player = pi`.

### OBSERVATION — 4. Input gestures remain unverified (owner must test in-game)

The spike correctly labels these **[needs in-game]**: synthetic raises of both custom inputs
and `on_player_selected_area` are rejected (`can't be raised through script`), and the
selection-tool `select` fields are not readable at runtime (data-stage load is the only proof).
The adapter registers every path, and the fallback gestures exist, so the design is sound — but
the owner **must** confirm in-game: (a) right-click with the whistle issues Move/Attack;
(b) the global `mouse-button-2` input with `consuming="none"` does not fire when the whistle is
not held or over a GUI (the 2.0.66 GUI-click fix); (c) left-drag selects and the four area
gestures deliver their orders; (d) zero-area single-click behaviour; (e) right-click does not
fight vanilla rotate/select while the whistle is held. The right-click + `reverse_select`
double-fire is acknowledged in IMPLEMENTATION §6 and last-writer-wins, so it is not a bug.

### OBSERVATION — 5. `attack_area` is a defensible but imperfect attack-move

API facts check out against the 2.1.25 docs: `defines.command` has no `attack_move`;
`attack_area{destination,radius,distraction}` is "go to the area and attack what you see";
`set_command` replaces the current command; `set_multi_command` is force-wide and rejects a bare
`stop` — all consistent with the spike's 18/18. The spike shows the unit completing with
`success` after killing one biter; a true continuous attack-move that keeps fighting in the area
is not guaranteed, so ATTACK_MOVE may complete early with enemies still alive. Acceptable for a
first slice, but worth recording on the issue.

---

## What would make me approve

1. Fix the item-loss bug: make `release_lease` release the commanded state's `carry` (and any
   other claims) through `work.release(st)` before replacing the table, with a test that a kill
   credited while commanded ends up in the hall ledger.
2. Either align the whistle's Stop tooltip with the actual "deselect only for ordinary workers"
   behaviour, or (better) leave the behaviour and just correct the wording.
3. Re-run the gates (465 tests, m1_colony 116/116, determinism, save/load) — the fix touches
   `command.lua` only and should not move the checksum (no headless lease occurs), but confirm.
4. Record the in-game gesture checklist on issue #58 as the remaining manual verification.

Everything else — precedence guards in `work.assign`/`on_ai_command_completed`/`alarm.EXEMPT`,
per-player plain-data storage and schema-38 migration, idempotent disconnect cleanup (including
a selection unit that died first — `is_commanded(nil)` is false so no state is resurrected), the
single chained watchdog keyed by `s.watchdog` with jobs in `storage.scheduled` (which the
existing save-load gate proves persist), and the two-run checksum — I checked and found sound.
