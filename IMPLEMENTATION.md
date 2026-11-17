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
