# IMPLEMENTATION.md — Command Whistle (#58), first slice

Branch `agent/rts-tool`, base `ce63efc`. PLAN.md was the specification; this file records what was actually
built, what the spike proved on this build (Factorio **2.1.24**, Steam), every gate's exact output, and the
places an adversarial reviewer should push hardest.

## 1. What shipped

A craftable `selection-tool` whistle and two rebindable custom inputs give an optional RTS micro layer over the
existing colonist state machine. Left-drag selects colonists; right-click at a world point issues a **Move**,
or **Attack** if a live enemy is under the cursor; shift-right-drag issues **Attack-Move**; X (or middle-click),
or alt-shift-right-drag, stops/releases. Orders are **3600-tick leases**: the unit's current trip is aborted
(carry returns to the hall, hut post and site claim freed, sprite/label cleared), the unit is parked in
`state = "commanded"`, and `work.assign` / the alarm sweep refuse to touch it until completion, expiry or
nightfall hands it back to workforce planning. Children, sleepers, shelterers, travellers, commuters, truck
drivers and children never enter the commandable set.

## 2. File-by-file changes

| File | Change |
|---|---|
| `mod/scripts/spike/s18_command.lua` (new) | 18-check engine/proto spike. Pin command replacement, convergence, `attack_area`, target attack, compound, `destructible=false`, unit groups, `set_multi_command`, input-event shapes, proto load, and `set_command` cost. |
| `mod/scripts/spike/loader.lua` | Registered `s18_command`. |
| `mod/prototypes/command.lua` (new) | `colony-command-whistle` `selection-tool` (four gestures, colonist/unit whitelist, distinct border colours), custom inputs `colony-command-order` (`mouse-button-2`) and `colony-command-stop` (`X`, alternative `mouse-button-3`), and a hand recipe (2 iron plate + 1 wood). No vanilla prototype edited. |
| `mod/data.lua` | `require("prototypes.command")` after `buildings.lua`. |
| `mod/prototypes/technology.lua` | Whistle recipe added to the `colony-settlement` milestone unlock list (ergonomics, not a power). |
| `mod/locale/en/locale.cfg` | New `[input-name]` section; `item-name`/`item-description`/`recipe-name` for the whistle; `colony-message.command-{none,ordered,stopped,move,attack,attack-move,protected,disconnected}`. |
| `mod/scripts/model/command.lua` (new) | PURE rules: `ORDERS`, `LEASE_TICKS = 3600`, `MAX_SELECT = 200`, `WATCHDOG_TICKS = 300`, `CLICK_TARGET_RADIUS = 3`; `commandable`, `select`, `abort_intents`, `command_for`, `plan`, `is_commanded`, `expired`, `after_completion`, `label_for`, `drop_player`. No Factorio globals; fresh tables; deterministic sorted iteration. |
| `mod/scripts/command.lua` (new) | Thin adapter. Registers all input events at load time; resolves entities through colony registries; calls `work.release` + hut-slot/sprite/label cleanup; issues engine commands; per-unit completion handler; 300-tick chained watchdog for expiry + nightfall; disconnect cleanup for selection, render objects and leases. |
| `mod/scripts/model/types.lua` | `CommandIntent`, `CommandState`, `CommandInput` EmmyLua annotations. |
| `mod/scripts/model/alarm.lua` | `commanded = true` added to `EXEMPT` so the alarm sweep cannot pull a commanded colonist indoors. |
| `mod/scripts/work.lua` | `M.assign` returns early for `commanded` **before** the shelter check; `on_ai_command_completed` returns early for `commanded` so the command adapter owns the lease. |
| `mod/scripts/store.lua` | **SCHEMA 37 → 38.** Migration seeds `storage.command = {selection, markers, owner, leased}`. |
| `mod/control.lua` | `require("scripts.command")`. |
| `tests/command_test.lua` (new) | 11 pure-model tests (protected/orderable precedence, selection modes/cap/aliasing, abort intents, three order shapes, determinism, expiry/completion, disconnect cleanup, labels). |
| `tests/glue_test.lua` | Schema assertions 37 → 38; asserts the new `storage.command` tables exist. |
| `docs/factorio_colony_mod_design_document.md` | §7.2 whistle bullet replaced with the implemented shape. |

## 3. Spike facts — exact values from `s18_command` (2.1.24)

Run: `scripts/headless-spike.sh s18_command` → `SUMMARY pass=18 fail=0 unknown=0 errors=0`.
Full report: `spike-results/20261117-122358/s18_command.txt` (identical facts on the final
`20261117-123016` run after the adapter landed).

| Fact | Exact observation |
|---|---|
| `defines.command.attack_move` | **nil**; `attack_area = 5`. `stop = 9`, `go_to_location = 2`, `compound = 6`. |
| `set_command` replaces a parked stop | `stop` read back `9`; after `go_to_location` read back `2`; colonist moved from `(-10.00,0.00)` to `(9.00,0.23)`. |
| Completion event | Fired once for the mover, `result = 2` (`success`), `was_distracted = false`. |
| `attack_area` | With a biter at `(13,0)`, command read back `5`; unit ended `(5.56,4.23)`, **completed once with `success`** and killed the biter (`biter_hp=dead`). It is a viable attack-move approximation. |
| Direct `attack` | Fresh biter hp `15 → dead`, one completion with `success`. |
| Compound command | Accepted; read back `6` (no compound chain used in the slice). |
| `destructible = false` | Accepted `go_to_location` (readback `2`), unit moved from `(0,8)` to `(-9.59,9.51)`, stayed `destructible = false`. (We still refuse to order sheltered units.) |
| Labels | A `rendering.draw_text` label survived `set_command`, `valid=true`, `text="⚑ probe"`. |
| Unit groups | A member of a `create_unit_group` issued a group `go_to_location` had **0 per-unit `on_ai_command_completed` events**. **Unit groups are therefore not used**: orders are per-unit. |
| `set_multi_command` | With `stop`: **rejected**, `command has no destination`. With `go_to_location`: returned `3` for `unit_count=3` - force-wide, not a selection. Not used. |
| Prototypes | `prototypes.item["colony-command-whistle"]` exists, `type="selection-tool"`. `prototypes.custom_input` order key `mouse-button-2`, stop key `X`, action `lua`; custom input event ID 227, `on_player_selected_area` ID 58. Selection-tool `select` mode/filter fields are **not exposed at runtime** (`LuaItemPrototype doesn't contain key select`) - data-stage load is the proof. |
| Input events | `script.raise_event("colony-command-order", ...)` → `can't be raised through script`; same for `on_player_selected_area`. `CustomInputEvent.cursor_position` is documented but only a real mouse can produce it here. **[needs in-game]** |
| Cost | `set_command x 200` averaged over 20 passes: **0.238158 ms** (earlier run 0.270400 ms) - an event-driven dispatch is not a tick spike. |

## 4. Gate outputs (final tree)

| Gate | Output |
|---|---|
| `scripts/test.sh` | `465 passed, 0 failed` |
| `scripts/lint-determinism.sh` | `determinism lint ok` |
| `luajit -bl` on every changed `.lua` | all compiled, no errors |
| `scripts/typecheck.sh` | `Diagnosis completed, no problems found` |
| `scripts/determinism.sh` | `SUMMARY pass=116 fail=0 unknown=0 errors=0`; `final checksum: 328728317`; `DETERMINISM: PASS` |
| determinism, second full run | identical `final checksum: 328728317`, `DETERMINISM: PASS` |
| `scripts/save-load.sh` | `SAVE/LOAD: PASS` |
| `scripts/headless-spike.sh s18_command` | `SUMMARY pass=18 fail=0 unknown=0 errors=0` |
| `TICKS=19500 scripts/headless-spike.sh m1_colony` | `SUMMARY pass=116 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_tech` (extra) | `SUMMARY pass=13 fail=0 unknown=0 errors=0` |

**New determinism checksum: `328728317`** (was `2125884680`). Attribution: the new selection-tool item, its
recipe, and two custom-input prototypes change Factorio's prototype-table hash - the same mechanism that moved
`2960604716 → 2125884680` when `colony-gleba-jam` was added. `m1_colony` still passes all 116 checks and no
gameplay rule changed (there is no player in headless, so no whistle event ever fires; the `commanded` guards
only affect a state that never occurs there). Two full `determinism.sh` runs produced the same checksum.

## 5. Deviations from PLAN.md (and why)

1. **Synthetic input raises are impossible** (`can't be raised through script`). The planned `[input] raise synthetic
   CustomInputEvent` check is recorded as a finding; handlers are registered but their payload shapes need a real
   in-game click. Zero-area single-click selection is likewise **[needs in-game]**.
2. **Selection-tool mode fields are not readable at runtime**, so the spike asserts the prototypes load instead of
   reading `select.entity_filters` back.
3. **Unit groups are definitively out**: zero per-unit completion events, proven (PLAN only suspected it).
4. **`set_multi_command` with a `stop` command is rejected**; not used in any case.
5. **STOP only stops leased units.** A stop on a unit mid-`to_pickup`/`to_hut` would make work.lua treat the
   command completion as arrival at the site, corrupting the trip. A stop key therefore releases leases and merely
   deselects ordinary workers.
6. **Watchdog period is 300 ticks, not `LEASE_TICKS/2` (1800).** Sleep yields after at most 5 seconds of real time
   rather than up to 30 game-minutes. It is still one chained scheduler job only while a lease is live.
7. **`plan(selection, kind, target, tick, ctx)` takes an optional `ctx`** (`colonies`, `jobs`, `owner`) so the pure
   model can emit `colony_id`/`job`/`lease_owner` without knowing the registry. `target` may also carry an engine
   entity in `enemy`; the model ignores it, the adapter uses it for `defines.command.attack` (avoids relying on
   `game.get_entity_by_unit_number`'s flag requirement).
8. **`commanded` is itself orderable**, so a second order (or another player) replaces the lease: last writer wins.
9. A **recipe** was added and unlocked by Settlement (PLAN recommended free from the first milestone); the stop
   input's primary key is `X` with middle-click as the alternative; `super_forced_select` and the `m3_command`
   integration spike are deferred, as PLAN allows.
10. No `release_for_command` wrapper was added to `work.lua`; `work.release` is called directly.

## 6. What an adversarial reviewer should scrutinise

- **Order-vs-job precedence.** `work.assign`'s `commanded` early return sits *before* `take_cover`; the
  completion handler's early return sits before work.lua's failure path. Try to find a path that still reassigns
  a leased unit (`shelter.check` sweep, `garrison.scan`, `sleep_check`, `commute`, `transit`, `illness`,
  `mortality`). Check the re-order path: `work.release` runs against the old state table, the hut slot is freed
  *before* it (research-lab recount), then a fresh leased state replaces it. Check that a second order cannot
  leave two `leased`/`owner` entries or lose the old job.
- **Release correctness.** On completion, expiry, nightfall, STOP and disconnect, the unit must end at
  `{colony_id, job, state="idle"}` with the label/sprite/owner/lease removed and `command.reassign` scheduled
  exactly once. The watchdog chain's `s.watchdog` flag and `storage.scheduled` entry must survive save/load; if
  they disagree, the watchdog can stop permanently (the lethal case is a unit stuck in `commanded` forever).
- **Multiplayer.** Selection, render ids, lease owners and the leased set are plain per-player/per-unit data in
  `storage.command`; no LuaPlayer/LuaEntity is stored (render objects are, as with `unit_labels`). Force a
  disconnect mid-order and check both players' markers and leases. Check `on_player_left_game` followed by
  `on_player_removed` is idempotent. Check two players selecting/ordering the same unit.
- **Input layer.** The right-click custom input is global: the guards (`in_gui`, controller type, cursor stack
  name, non-empty selection) are the only thing keeping it from firing everywhere. Right-click also triggers the
  tool's `reverse_select` gesture, so a drag can deliver a click order plus a gesture order (last one wins); the
  fallback gestures exist if that proves annoying. The old 2.0.66 GUI-click bug and zero-area selection still
  need a real in-game test - headless cannot produce mouse input.
- **Prototype/audit.** The whistle recipe is unlocked by `colony-settlement`; `m1_tech` passes, but a future
  tech-audit rule could flag a tool recipe. The `[input-name]` section is new; the locale audit passes.

## 7. Review fixes (`REVIEW.md`, commit after 4062172)

### MAJOR — a commanded hunter's kill credit was thrown away

`work.lua:3360-3368` credits meat into `st.carry` for **any** colonist with `job == "hunt"`, without checking
`state`; a hunter shooting under an Attack-Move order therefore wrote meat into the leased `commanded` state.
`release_lease` replaced that state with a fresh table, so the meat vanished. Fixed in
`mod/scripts/command.lua:release_lease`: the leased state is now funnelled through `work.release(st)` **before**
the fresh idle state is written, exactly as `work.assign` does at `work.lua:2433`. `work.release` returns carry
to the hall (spoilage to the nearest bin), restores cars/trailers and clears site claims, so any goods or claims
acquired during a lease survive the hand-back. `M.release_lease` is exported for the regression case; no new
`require` was added (`scripts.command` already imports `scripts.work` at load time), no function is stored in
`storage`, and `model/command.lua` is untouched — the pure boundary is intact.

**Every carry-producing path traced:**
- *Hunt kill* (`work.lua:3368`) — the actual bug; now released through `work.release`.
- *Harvest / farm / fish / mine / preserve yields* (`work.finish`, `work.lua:2917`) — guarded by
  `st.state == "working"` (`work.lua:2727`); a leased unit is `"commanded"`, so no yield is written while leased.
  If the yield landed in the tick *before* the order, `abort_intents` sees the carry and the order-time
  `work.release` returns it.
- *Haul pickups / construction materials* (`work.lua:2134`, `construct.finish`) — a trip is never started for a
  leased unit (`work.assign` early-returns); a trip started just before the order is released at order time.
  **Correction (re-review):** `construct.finish` had no state guard and could cancel the lease (see §8), even
  though it could not create or lose goods. It is now guarded on `building`/`repairing`.
- *Spoilage to a bin* (`work.lua:3251`) — only reached from work.lua's own completion handler, which now
  early-returns for `commanded`; at order time `work.release` routes spoil to the nearest bin anyway.
- `site_key`, `car` and `trailer` claims are also released by that same call, so no phantom claims remain.

**Regression evidence:**
- Unit (`tests/command_test.lua`): "funnels a commanded hunter's carry through work.release before resetting
  the state" — asserts `work.release` sees `{item="colony-meat", count=3}` on a `commanded`, `job="hunt"` state
  and that the released state is clean.
- Spike (`s18_command`): a minimal real colony/Town Hall, a commanded hunter with 3 meat credited in its carry,
  then `release_lease` → `[integrated] kill credit from a commanded hunter reached the hall - before=0 after=3`
  and a clean idle state.
- **Mutation check:** removing the `work.release(st)` line makes the unit test fail
  (`work.release must see the leased state: expected 1, got 0`) **and** the spike fail
  (`[integrated] ... hall - before=0 after=0`). Restoring the line returns both to green.

### MINORs

- **Tooltip honesty.** `item-description.colony-command-whistle` now says X/middle-click "releases the selection
  and stops colonists that are under a whistle order; ordinary workers just keep their current job and are
  deselected".
- **Per-player selection circles.** Verified on https://lua-api.factorio.com/latest/classes/LuaRendering.html:
  2.1's `draw_circle` takes `players` (an array of `PlayerIdentification`), **not** `for_player`. Circles now
  pass `players = {pi}`, so only the selecting player sees them; `storage.command.markers[pi]` remains per-player
  and is destroyed on selection change and disconnect.

### Issue #58

Posted the in-game gesture checklist (right-click order/attack, global custom-input and GUI guards, four area
gestures, zero-area click, Stop honesty, attack-move caveat, multiplayer) as
https://github.com/alexswan10k/colony-bio-logistics/issues/58#issuecomment-6948524354. **The issue remains OPEN**
(`gh issue view 58` → `state: OPEN`) pending the owner's manual verification.

### Gates after the fixes

| Gate | Output |
|---|---|
| `scripts/test.sh` | `466 passed, 0 failed` (was 465; +1 regression test) |
| `scripts/lint-determinism.sh` | `determinism lint ok` |
| `luajit -bl` on changed Lua (`command.lua`, `s18_command.lua`, `command_test.lua`) | all compiled |
| `scripts/typecheck.sh` | `Diagnosis completed, no problems found` |
| `scripts/determinism.sh` | `final checksum: 328728317`, `DETERMINISM: PASS`, m1_colony 116/116 |
| `scripts/save-load.sh` | `SAVE/LOAD: PASS` |
| `scripts/headless-spike.sh s18_command` | `SUMMARY pass=20 fail=0 unknown=0 errors=0` (was 18; +2 integrated checks) |
| `TICKS=19500 scripts/headless-spike.sh m1_colony` | `SUMMARY pass=116 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_tech` | `SUMMARY pass=13 fail=0 unknown=0 errors=0` |

Checksum **did not move** (`328728317`): the fix touches only the adapter's lease-release path, no headless
run has a player or a lease, and no prototype changed. The integrated spike exercises the release path directly
without altering the deterministic `m1_colony` world.

## 8. Re-review fixes and the deferred-callback audit

### MAJOR — a stale `construct.finish` timer cancelled a live lease

`construct.finish` is scheduled 30 ticks (`construct.WORK_TICKS = 30`) after a builder enters
`building`/`repairing` (`work.lua:3097`, `:3209`). Its only guard was `st.job == "construct"`; a whistle lease
preserves that job while replacing the state with `commanded`, so the timer wrote `state = "idle"`
(`work.lua:3002`) and called `M.assign`, cancelling the order. Fixed at `work.lua:2929`: the handler now requires
`st.state == "building" or st.state == "repairing"` — the only two states that arm the timer. Any stale timer
(commanded, idle, sleeping, sheltered, a new trip) is a no-op. This is the correct guard regardless of the
whistle and does not change normal construction.

**Orphan timer / half-built ghost.** When the order arrives inside the 30-tick window, `work.release(st)`
returns the build materials to the hall and clears `colony.claimed[st.site_key]` (construct is in
`CLAIM_JOB`, `work.lua:763`); the fresh leased state carries no `site`/`kind`, so nothing is half-built. The
one-shot timer is simply consumed by the new guard at +30 and is not re-armed, so no `storage.scheduled` entry
survives. `construct.scan` can later re-discover the untouched ghost. Both are asserted in the spike.

**Regression evidence:**
- Unit test `tests/command_test.lua`: "a stale 30-tick build timer cannot overwrite a commanded state" loads
  the real `work.lua` under the Factorio mock with a capturing scheduler stub, fires the captured
  `construct.finish` handler with a `commanded` construct state and asserts the lease is untouched.
- Spike `s18_command`: a real 30-tick `scheduler.after(..., "construct.finish", ...)` on a leased builder →
  `[integrated] stale construct.finish timer did not end the lease - state=commanded`; plus
  `[integrated] order during build window returns materials and clears the claim - claim=nil wood=2` and
  `[integrated] ghost not half-built and no claim left`.
- **Mutation checks (both):** reverting the guard to `st.job == "construct"` makes the unit test fail
  (`stale timer must not end the lease: expected commanded, got idle`) and the spike fail
  (`[integrated] stale construct.finish timer did not end the lease - state=idle`). Restoring the guard returns
  both to green.

### Systematic audit — every deferred callback that can touch colonist state

Line numbers are from this commit. "Safe" means it cannot end, replace or corrupt a `commanded` lease.

| Callback | Evidence | Verdict |
|---|---|---|
| `construct.scan` | `work.lua:522`; only calls `wake_idle_colonists` (`:500`), which assigns solely `st.state == "idle"` (`:514`). | Safe — a lease is not idle. |
| `work.machine_sweep` | `work.lua:1578`; writes `colony.machines`/badges only, never `unit_state`. | Safe. |
| `garrison.scan` | `work.lua:2659`; guarded `st.job == "guard" and st.state == "guarding"` (`:2661`). | Safe. |
| `work.retry` | `work.lua:2691`; guarded `st.state == "idle"` (`:2695`). | Safe. |
| `farm.ripen` | `work.lua:2705`; writes plot data, then `reassign_workforce` (`colony.lua:837`), which only assigns idle or wakes sleepers (`:842-846`). | Safe. |
| `work.finish` | `work.lua:2725`; guarded `st.state == "working"` (`:2727`) for every yield/carry write. | Safe — already proven in §7. |
| `construct.finish` | `work.lua:2923`; **was job-only, now state-guarded** at `:2929`. | Fixed. |
| `work.sleep_check` | `work.lua:3029`; guarded `sleeping`/`to_bed` (`:3030`). | Safe. |
| `shelter.check` | `shelter.lua:59`; `take_cover` returns early on `alarm.EXEMPT[st.state]` (`:35`), and `commanded` is in that table (`model/alarm.lua:21-23`); all-clear only touches shelter states. | Safe. |
| `colony.evaluate` | `colony.lua:1450`; wakes only `sleeping`/`to_bed` (`:1443`) and calls `wake_idle_colonists` (idle guard above). No direct state writes. | Safe. |
| `gui.refresh_house/hut/info/machine` | `gui.lua:178, 492, 967, 1594`; GUI reads and repaints only; they inspect `unit_state` for labels/rosters but never write state. | Safe. |
| `colony.regrow_patch`, `seed_all`, `rebadge`, `compost` | `colony.lua:1493, 1508, 1513, 2089`; world/registry data only. | Safe. |
| `ledger_signal`, `cold.tick`, `feedback.tick` | `ledger_signal.lua:167`, `cold.lua:60`, `feedback.lua:241`; publish/cold/stats only; `feedback.tick` reads state (`:116`) but never writes it. | Safe. |
| `command.reassign`, `command.watchdog` | `command.lua:93, 98`; reassign only after `release_lease` has written `idle`; watchdog only acts on `is_commanded` states and drops stale lease entries. | Safe by construction. |
| `on_ai_command_completed` | `work.lua:3049`; early-returns for `commanded` at `:3052` before every trip-completion branch. | Safe. |
| `on_entity_died` (hunt credit, coach riders) | `work.lua:3365` (credit at `:3373`) writes carry into the leased state; `release_lease` funnels it through `work.release` (§7). `transit.lua:237` only handles coach groups; leased units are never commuters/riders. | Handled / safe. |
| `on_object_destroyed` | `work.lua:3381` deletes state for a dead colonist; the watchdog later drops the lease because `is_commanded(nil)` is false — no state is resurrected. | Safe. |
| `illness` evaluation | `illness.lua:50-60` counts `heal` doctors with `state == "working"`; kills remove the colonist; no lease mutation. | Safe. |

No callback outside `construct.finish` was keyed on `st.job`/`st.hut` without either a state guard or a proof that
it never writes colonist state. The audit therefore ends the loop rather than patching one symptom.

### Gates after the re-review fixes

| Gate | Output |
|---|---|
| `scripts/test.sh` | `467 passed, 0 failed` (was 466; +1 stale-timer regression) |
| `scripts/lint-determinism.sh` | `determinism lint ok` |
| `luajit -bl` on changed Lua (`work.lua`, `s18_command.lua`, `command_test.lua`) | all compiled |
| `scripts/typecheck.sh` | `Diagnosis completed, no problems found` |
| `scripts/determinism.sh` | `final checksum: 328728317`, `DETERMINISM: PASS`, m1_colony 116/116 |
| `scripts/save-load.sh` | `SAVE/LOAD: PASS` |
| `scripts/headless-spike.sh s18_command` | `SUMMARY pass=23 fail=0 unknown=0 errors=0` (was 20; +3 integrated checks) |
| `TICKS=19500 scripts/headless-spike.sh m1_colony` | `SUMMARY pass=116 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_tech` | `SUMMARY pass=13 fail=0 unknown=0 errors=0` |
| `scripts/headless-spike.sh m1_blueprint` (extra) | `SUMMARY pass=34 fail=0 unknown=0 errors=0` - normal ghost revive/copy-paste unaffected by the new state guard |

Checksum still **328728317**: the guard only affects `commanded` states, which never occur in headless
`m1_colony`, and normal construction still enters `building`/`repairing` exactly as before (the spike's ghost
case and the existing build tests confirm). Issue #58 remains OPEN with the gesture checklist; the minor doc
drift about the old test count in that comment is cosmetic and left untouched.
