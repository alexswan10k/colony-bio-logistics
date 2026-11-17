# PLAN.md — Command Whistle (issue #58), minimal first slice

Planner output for the plan → implement → adversarial-review pipeline. **No code changed.**
All paths are relative to the worktree `colony-worktrees/rts-tool`.

## 0. What the issue actually asks for, and what the engine allows

Issue #58: *“LuaCommandable + custom-input mouse hooks; multiplayer-safe selection state.”*
Design doc §7.2 (line 334): *“Command Whistle (`selection-tool`): Optional RTS drag-select tool to
issue temporary AoE-style Move / Attack-Move orders when clearing nests.”* Milestone **M3**.

### 0.1 Verified engine facts (Factorio 2.1.25 docs)

| Fact | Exact source |
|---|---|
| `LuaEntity.commandable` → `LuaCommandable`: `set_command(command)`, `command`, `has_command`, `is_unit_group`, `parent_group`. A `set_command` on a unit **replaces** its current command. | https://lua-api.factorio.com/latest/classes/LuaCommandable.html#set_command |
| `defines.command` has **no `attack_move`**. The full set is: `attack`, `go_to_location`, `compound`, `group`, `attack_area`, `wander`, `flee`, `stop`, `build_base`. | https://lua-api.factorio.com/latest/defines.html#defines.command |
| `attack_area` is the engine's built-in attack-move approximation: *“Go to a place and attack what you see”*; fields `destination`, `radius`, `distraction` (default `by_enemy`). | https://lua-api.factorio.com/latest/concepts/Command.html#defines.command.attack_area |
| `go_to_location`: `destination`/`destination_entity`, `radius` (default 3), `distraction` (default `by_enemy`), `pathfind_flags`. `attack`: `target`, `distraction`. `stop`: `ticks_to_wait`, `distraction`. `compound`: `structure_type`, `commands`. | https://lua-api.factorio.com/latest/concepts/Command.html |
| `on_ai_command_completed` gives `unit_number` **and** `result` (`defines.behavior_result`: in_progress/fail/success/deleted) and `was_distracted`. | https://lua-api.factorio.com/latest/events.html#on_ai_command_completed |
| `LuaSurface.create_unit_group{position, force?}` → `LuaCommandable`; `add_member(member)`, `commandable_members`, `set_autonomous()`, `start_moving()`, `destroy()` (unlinks members, does **not** destroy them). Group commands fire `on_unit_group_finished_gathering`. | https://lua-api.factorio.com/latest/classes/LuaCommandable.html#add_member , https://lua-api.factorio.com/latest/events.html#on_unit_group_finished_gathering |
| `LuaSurface.set_multi_command{command, unit_count, force?, unit_search_distance?}` → count (broad “command nearby units” API, not a selection). | https://lua-api.factorio.com/latest/classes/LuaSurface.html#set_multi_command |
| `SelectionToolPrototype`: `select`, `alt_select`, `super_forced_select`, `reverse_select` (right mouse), `alt_reverse_select` (shift+right mouse), `send_pre_selection_events`, `always_include_tiles`, `skip_fog_of_war`. | https://lua-api.factorio.com/latest/prototypes/SelectionToolPrototype.html |
| `SelectionModeData`: `mode` (flags), `entity_filters` (array of entity **names**), `entity_type_filters`, `entity_filter_mode`, `cursor_box_type`, `draw_selection_counts`. Flags include `any-entity`, `same-force`, `nothing`, `any-tile`, `entity-with-health`. **There is no `unit` flag** — restrict with `entity_filters = {"colony-colonist"}` / `entity_type_filters = {"unit"}`. | https://lua-api.factorio.com/latest/types/SelectionModeData.html , https://lua-api.factorio.com/latest/types/SelectionModeFlags.html |
| Drag-select **is** scriptable: `on_player_selected_area` / `on_player_alt_selected_area` / `on_player_reverse_selected_area` / `on_player_alt_reverse_selected_area` / `on_player_super_forced_selected_area`, plus pre-events when `send_pre_selection_events=true`. The existing `mod/scripts/marker.lua` already proves the `ev.item` / `ev.entities` / `ev.area` / `ev.player_index` shape for the left-drag case. | https://lua-api.factorio.com/latest/events.html#on_player_selected_area |
| **Mouse-button custom inputs are scriptable and carry a world position.** `CustomInputEvent`: `player_index`, `input_name`, **`cursor_position` (MapPosition)**, `cursor_direction`, `cursor_display_location`, `selected_prototype?`, `element?`, `in_gui`. | https://lua-api.factorio.com/latest/events.html#CustomInputEvent |
| `custom-input` accepts mouse buttons as `key_sequence`: `mouse-button-1` (left), `mouse-button-2` (right), `mouse-button-3` (middle), … `mouse-wheel-*`; modifiers `CONTROL`/`SHIFT`/`ALT`/`COMMAND`; `action="lua"` raises the event; `consuming` and `block_modifiers` control interference; `enabled_while_*`, `include_selected_prototype`. | https://lua-api.factorio.com/latest/prototypes/CustomInputPrototype.html#key_sequence |
| `LuaControl.selected` is a **single** `LuaEntity` (RW) with `on_selected_entity_changed`. It cannot hold a multi-unit selection — hence our own per-player selection set in `storage`. | https://lua-api.factorio.com/latest/classes/LuaControl.html#selected |
| `on_player_left_game` / `on_player_removed` exist for selection cleanup. | https://lua-api.factorio.com/latest/events.html#on_player_left_game |
| `defines.distraction.none` = perform command even if attacked; `by_enemy` = attack closer enemy units; `by_anything`, `by_damage`. | https://lua-api.factorio.com/latest/defines.html#defines.distraction |

### 0.2 The critical verdicts

1. **Right-click orders ARE scriptable** via a `custom-input` bound to `mouse-button-2`: the Lua event
   supplies `cursor_position`. The issue's “custom-input mouse hooks” is therefore *mostly* possible,
   contrary to the initial suspicion. Caveat: a right-click custom-input is **global** (fires even when
   the whistle is not held), so the adapter must guard on `in_gui`, the held cursor stack, and a
   non-empty selection. A 2.0.66 bug where mouse-button custom inputs did not fire over GUIs was
   confirmed fixed by Factorio staff for a later release; **verify on the owner's 2.1.x in-game**.
2. **Drag-select is scriptable only through a `selection-tool` + `on_player_*_selected_area` events**;
   there is no `on_selection_changed` (multi-select) and no raw mouse-move/drag event exposed to Lua.
   `player.selected` is one entity, not a set.
3. **There is no `attack_move` command.** Emulate with `defines.command.attack_area` (destination +
   radius + `distraction.by_enemy`), which is literally “go there, fight what you see”. Keep
   `go_to_location` + `distraction.none` for a pure Move that never gets distracted.
4. **Fallback if the mouse-button custom input proves unusable** (conflicts, GUI bug on the owner's
   build, or owner preference): the same `selection-tool` gets a second gesture: `alt_select`
   (alt-drag) = Move to the *centre of the dragged area*; `reverse_select` (shift+right-drag) =
   Attack-Move to the area centre; `alt_reverse_select` = Stop/release selection. This still delivers
   full RTS orders using only the already-proven `on_player_*_selected_area` family, with zero raw
   mouse hooks. The model and state machine are identical; only the adapter's input layer changes.
   The spike must verify that a zero-area (single click) still raises `on_player_selected_area`.

## 1. ENGINE SPIKE FIRST — `s18_command`

New headless spike `mod/scripts/spike/s18_command.lua`, registered in `mod/scripts/spike/loader.lua`
(list around line 3-10), run with `scripts/headless-spike.sh s18_command` (optionally `TICKS=...`).
Style: copy the `ctx.check` / `ctx.probe` / `ctx.after` idiom from `s14_circuit.lua` and `s01_units.lua`.
Headless has no player, so label checks as **[engine]** (actually executed on spawned units) vs
**[proto]** (prototype fields only) vs **[needs in-game]** (input gestures that cannot be simulated).

Checks to pin (target ~20 checks):

**A. Commands on our colonist unit [engine]**
1. Spawn 3 `colony-colonist` units on the player force on flat ground; `e.commandable` is non-nil.
2. `set_command{type=defines.command.go_to_location, destination=..., radius=1.5, distraction=defines.distraction.none}` → position converges; `on_ai_command_completed` fires with our `unit_number` and `result=success`.
3. `set_command{type=defines.command.stop, ticks_to_wait=4294967295, distraction=none}` then a new `go_to_location` **overrides** the stop (critical: guards/sleepers are parked under a huge stop).
4. `set_command{type=defines.command.attack_area, destination=..., radius=8, distraction=by_enemy}` with a boar/biter nearby → the unit moves toward the area and damages the target; record whether completion fires while targets remain.
5. `set_command{type=defines.command.attack, target=<entity>}` (proven by `work.lua` hunting) still works after a move command.
6. `set_command{type=defines.command.compound, structure_type=defines.compound_command.logical_or, commands={go_to_location, attack_area}}` → accepted or rejected (decide whether compound is worth using; likely NOT for slice 1).
7. `commandable.has_command`, `commandable.command.type` read back; `defines.command.attack_move == nil` (explicit assert).
8. `set_command` on a unit with `destructible=false` (mirrors a sheltered colonist) → accepted or error (we refuse anyway, but know the failure mode).
9. A unit joined to a `create_unit_group` still fires per-unit `on_ai_command_completed`? If not, **do not use unit groups in slice 1**.
10. `surface.set_multi_command{command=..., unit_count=3, force=...}` → how many of our colonists get commanded; confirm it is force-wide and unsuitable.

**B. Selection tool / custom-input prototypes [proto]**
11. `prototypes.item["colony-command-whistle"]` exists with `type="selection-tool"`, `select.entity_filters={"colony-colonist"}`, `alt_select`, `reverse_select`, `alt_reverse_select`, `send_pre_selection_events=false`, `mouse_cursor="selection-tool-cursor"`.
12. `prototypes.custom_input[...]` (or `data.raw["custom-input"]`) contains `colony-command-order` with `key_sequence="mouse-button-2"`, `action="lua"`, and the alternate `colony-command-stop` (`mouse-button-3` or a keyboard key). Assert `key_sequence` string is accepted at load time (load failure is itself a finding).
13. `script.raise_event` of a synthetic `CustomInputEvent` (with `cursor_position`, `in_gui=false`, `input_name`) reaches our handler if possible; otherwise log **[needs in-game]** that real button presses must be tested by the owner.
14. Zero-area selection: **[needs in-game]** note that single-click → `on_player_selected_area` is assumed, with the area-centre fallback in §4.

**C. Interaction facts [engine]**
15. `set_command` on a colonist that is `destructible=false` does not silently re-enable it.
16. Ordering a colonist that has a label does not clear the label (we manage labels ourselves).
17. Rough cost: `ctx.profile("set_command x 200", ..., 50)` to confirm a 200-unit order is not a tick spike.

Record the outcomes on issue #58 (comment + close per AGENTS.md) and update design doc §7.2 once landed.

## 2. PURE MODEL — `mod/scripts/model/command.lua` (new)

All rules here; **no `game`/`storage`/`script`/`defines`/`surface` globals**. Adaptor passes plain
data (state records, positions, order kind) and reads back data. Follow the `model/turret.lua` style
(`---@diagnostic enable: undefined-field, missing-fields`, `local M = {}`, fresh tables per call).

Proposed API (names finalisable at implementation):

```lua
M.ORDERS = {MOVE = "move", ATTACK_MOVE = "attack_move", ATTACK = "attack", STOP = "stop"}
M.LEASE_TICKS = 3600          -- ~1 min; a temporary order, not a career change
M.MAX_SELECT = 200            -- deterministic cap and a guard against absurd orders

-- Which colonist states may be ordered. PROTECTED (never commandable):
--   child, to_bed, sleeping, to_shelter, sheltered (while alarm covers fled_from),
--   to_platform, waiting_train, driving, to_park, travel/commute states,
--   and any truck entry in storage.trucks.
-- COMMANDABLE (with slot release): idle, all work trip states, to_tower/on guard duty,
--   hunting, and haul states. Guards/hunters must have their hut slot freed by the adapter.
function M.commandable(st, ctx) -- ctx = {is_child, is_truck, alarm_covers}, st = unit_state record
  --> boolean
end

-- Deterministic selection merge: sorted unit numbers, dedupe, cap, no engine objects.
-- mode "set"|"add"|"remove"|"clear".
function M.select(current, candidates, mode) --> sorted array of unit_numbers
end

-- What an order must clean up before the engine command is issued. Pure intent data;
-- the adapter performs the actual engine calls.
function M.abort_intents(st)
  --> {release_carry=bool, free_hut_slot=bool, free_site_claim=bool|key,
  --     restore_destructible=bool, old_job=string|nil}
end

-- Build a leased commanded state + a deterministic per-unit command list.
-- `target` = {position={x,y}, radius=?, enemy_un=?}. Attack if enemy_un present and kind is
-- auto; otherwise ATTACK_MOVE -> attack_area; MOVE -> go_to_location distraction.none.
function M.plan(selection, kind, target, tick)
  --> {states = {[un] = {colony_id=..., job=old_job, state="commanded", order=kind,
  --                     until_tick=tick+LEASE_TICKS}}, commands = {[un] = {kind=..., ...}}}
end

function M.expired(st, tick) --> boolean end
function M.after_completion(st, result) --> "release_to_work" | "keep"   -- keep only if lease live and result==in_progress
function M.clear_player(sel_state, player_index) --> new selection table (no player objects)
```

Determinism rules: iterate sorted arrays, never `pairs()` over a selection; all randomness-free.
The model returns **intent data**, so the adapter is the only place touching engine objects.

State-machine safety rules encoded here (mirrors `work.lua:2423-2429`):
- An ordered colonist gets `state = "commanded"` and keeps `colony_id`, `job` (previous job), and
  a `until_tick`. `work.assign` must treat `"commanded"` like the other protected trip states.
- The order **aborts** the current trip: carried goods go back to the hall, the hut worker slot and
  the claimed site (`site_key`) are released, the old tool wear is not charged again. The model emits
  those cleanup intents; `scripts/command.lua` calls the existing `work.release(st)` and clears the
  carry sprite (`storage.carry_sprites[un]`) / site claim (`colony.claimed`).
- At completion/expiry the state resets to `{colony_id, state="idle", job=old_job}` and the adapter
  schedules `work.assign` for the next evaluation; normal workforce planning then resumes.
- Ordering never changes `colony.locks` or job priorities — it is a temporary lease on the unit.

## 3. ADAPTER — `mod/scripts/command.lua` (new)

Thin; all decisions come from `model/command.lua`. Register every event at file scope via
`scripts.events.on` (AGENTS: load-time only).

**Input layer (primary, mouse hooks):**
- `custom-input` `colony-command-order` → `mouse-button-2` (right click). Handler:
  ignore if `ev.in_gui`, if player controller is not character/god, if cursor stack is not the
  whistle, or if the player's selection is empty. Use `ev.cursor_position` as the destination.
  If a live enemy military entity is within `M.CLICK_TARGET_RADIUS` (e.g. 3 tiles) of the cursor, choose
  `ATTACK` with its `unit_number`; else choose `MOVE` (or `ATTACK_MOVE` when the player holds the
  “force attack-move” modifier custom input / uses `alt_select`). Call `model.plan`, then apply.
- `custom-input` `colony-command-stop` → `mouse-button-3` (middle) or `X`: send `stop` to all
  selected colonists, release their lease, clear the selection.
- `on_player_selected_area` (filtered to `ev.item == "colony-command-whistle"`): call
  `model.select(current, colonists from ev.entities, "set")`, draw a selection circle per unit with
  `rendering.draw_circle`, store **render object ids** in `storage.command.markers[player_index]`
  (we already store rendering ids in `storage.unit_labels`, so this is the established pattern).
- `on_player_alt_selected_area` → Move to area centre; `on_player_reverse_selected_area` →
  Attack-Move to area centre; `on_player_alt_reverse_selected_area` → Stop/clear. These double as
  the fallback if mouse-button custom inputs are disabled.

**Applying an order (per unit, sorted):**
1. Look up the real entity from `colony.colonists[un]`; verify `valid`, `name=="colony-colonist"`,
   its force is a colony force, and `storage.unit_state[un]` exists.
2. Execute the `model.abort_intents` via existing helpers: `work.release`, clear hut `workers[un]`,
   clear `colony.claimed[site_key]`, clear label/carry sprite, keep `destructible` as-is.
3. Write the leased `unit_state` from `model.plan`.
4. `e.commandable.set_command(cmd)` with the exact table from the model.
5. Feedback: always-visible label “⚑ moving” / “⚑ attacking” via `work.set_label`; a local flying
   text “N colonists ordered” using a new `colony-message.command-*` locale key.

**Completion / watchdog:**
- `on_ai_command_completed`: if `storage.unit_state[ev.unit_number].state == "commanded"`, call
  `model.after_completion`; on release, reset state, restore label, and `scheduler.after(1, ...)` a
  `work.assign` (avoid reentrancy inside the event).
- `scheduler` watchdog every `LEASE_TICKS/2`: expire leased states whose `until_tick` passed so a
  distracted/never-completing order cannot pin a colonist forever.

**Multiplayer-safe selection state:**
- `storage.command = {selection = {[player_index] = {units = {[un]=true}, order = kind}}, markers = {[player_index] = {render_ids...}}}`.
  Plain data only; no functions, no LuaEntity/LuaPlayer references (only `unit_number`s and render ids).
- `on_player_left_game` / `on_player_removed`: destroy that player's render objects, clear both
  tables, and release any leases their pending orders held (so a disconnect never strands colonists
  in `commanded` state). This closes the gap that `cursor_overlays` currently has (it is per-player
  but never cleaned up on disconnect).
- Two players commanding the same unit: last writer wins, but the model inserts the unit into a
  per-unit `command_owner[un] = player_index` map so only the owning player's completion/expiry
  handler releases it.

## 4. FILE-BY-FILE CHANGES

| File | Change |
|---|---|
| `mod/prototypes/command.lua` (new) | `selection-tool` `colony-command-whistle` (icon reuse `icon-town-hall.png` or new art from `scripts/gen_art.py`); `select.mode={"any-entity","same-force"}`, `entity_filters={"colony-colonist"}`, `entity_type_filters={"unit"}`, cursor boxes, `alt_select`/`reverse_select`/`alt_reverse_select` with distinct border colours, `stack_size=1`, flags `not-stackable`, `spawnable`. Two/three `custom-input` prototypes for order/stop/attack-mode with rebindable key sequences. |
| `mod/data.lua` | `require("prototypes.command")` after `buildings.lua` (regular prototype, not spike-only). |
| `mod/locale/en/locale.cfg` | `item-name.colony-command-whistle`, `item-description.*`, `input-name.colony-command-*`, `colony-message.command-{ordered,stopped,none,disconnected}`, command labels. Must satisfy the locale audit in `tests/locale_test.lua`. |
| `mod/scripts/model/command.lua` (new) | Pure rules from §2; annotate in `mod/scripts/model/types.lua` if typecheck requires. |
| `mod/scripts/model/types.lua` | Optional `CommandSelection`/`CommandIntent` annotations for `scripts/typecheck.sh`. |
| `mod/scripts/command.lua` (new) | Adapter from §3; register events at load time. |
| `mod/control.lua` | `require("scripts.command")` among the other adapter requires. |
| `mod/scripts/work.lua` | Extend the protected-state list in `M.assign` (lines ~2423-2429) with `"commanded"` so an async reassignment never wipes a live order; expose a tiny `M.release_for_command(st)` wrapper if needed (delegates to existing `M.release`). |
| `mod/scripts/store.lua` | Bump `SCHEMA` 37 → **38**; migration `[38]` seeds `storage.command = {selection={}, markers={}, owner={}}`. |
| `mod/scripts/spike/s18_command.lua` (new) | Spike from §1. |
| `mod/scripts/spike/loader.lua` | Add `"s18_command"` to the required list. |
| `tests/command_test.lua` (new) | Unit tests from §5. |
| `docs/factorio_colony_mod_design_document.md` | After landing, replace the single §7.2 whistle bullet with the implemented 2–3 sentence shape and record the decision on issue #58 (comment + close). `docs/SPIKES.md` if the repo keeps per-spike notes there. |
| `spike-results/`, `PLAN.md` | Generated at run time / this document. |

No vanilla prototype edits (opt-in pillar). No new terrain scan; selection uses engine-provided
`ev.entities`, orders use the existing registries. No per-tick scans when no player has an active order.

## 5. TESTS AND GATES

**Unit (`scripts/test.sh command`) — `tests/command_test.lua`:**
- `commandable()` is false for child/sleeping/to_bed/to_shelter+sheltered/to_platform/waiting_train/
  driving/truck; true for idle, haul states, guard, hunt; guard/hunt intents include `free_hut_slot`.
- `select()` sorts, dedupes, respects "set"/"add"/"remove"/"clear", caps at `MAX_SELECT`, returns
  fresh tables; two different players' selections do not alias.
- `abort_intents()` returns the right cleanup flags for each trip state and never mutates its input.
- `plan()` produces deterministic ordered command lists; MOVE → go_to_location + `distraction.none`;
  ATTACK_MOVE → attack_area + `distraction.by_enemy`; ATTACK → attack with target; STOP → stop;
  leased `until_tick = tick + LEASE_TICKS`.
- `expired()` / `after_completion()` release exactly when expected; `clear_player()` empties a
  player's selection without touching another's.
- Locale audit still passes (`scripts/test.sh locale`).

**Spike (`scripts/headless-spike.sh s18_command`)**: §1 checks; treat `[ERR]` as a finding, not a
crash. Record the report in `spike-results/<timestamp>/`.

**Other gates:**
- `scripts/typecheck.sh` (new model + annotations).
- `scripts/lint-determinism.sh` and `luajit -bl` on every changed Lua.
- `scripts/save-load.sh` — schema 38 migration round-trip.
- `scripts/determinism.sh` — **the checksum WILL move, not stay unchanged.** Reason: the two new
  prototypes (selection-tool item + custom-inputs) change Factorio's prototype-table hash, exactly as
  `colony-gleba-jam` moved it 2960604716 → 2125884680 (AGENTS §Status). Gameplay in `m1_colony` is
  unchanged (no player in headless, no whistle, protected-state addition affects states that never
  occur there), so a *behaviour* diff would be a bug; re-baseline the new checksum and record it.
- `scripts/bench-colony.sh` / `bench-once.sh` — expect no measurable cost with zero orders; order
  dispatch is event-driven, not per-tick.
- Optional: a `m3_command` integration spike later, proving a commanded colonist actually reaches a
  destination and returns to work after completion (build on `s18_command`, not required for slice 1).

## 6. RISKS, OPEN QUESTIONS, RECOMMENDED SLICE

**Risks**
- Right-click custom input is **global**; must guard on `in_gui`, held cursor item, controller type,
  and a non-empty selection. 2.0.66 had a GUI-click bug (fixed upstream); verify on the owner's build.
- `attack_area` is not a true continuous attack-move; it may complete early or ignore distant enemies.
  Decide from the spike whether a `compound` chain is worth it (recommended: not for slice 1).
- Unit groups may offer nicer squad cohesion but risk breaking per-unit `on_ai_command_completed`
  and our state machine. Use per-unit commands in slice 1; re-evaluate later.
- Aborting a trip must release **all** claims (hut slot, site, carry, car/trailer if applicable).
  A missed claim leaves a phantom worker or an un-harvestable site. Model intents + a focused test
  mitigate this; consider refusing to command haulers that are mid-truck-trip outright.
- Night/sleep vs. a long order: decide which wins. Recommendation: orders are leased for 3600 ticks
  **and** are released at nightfall so sleep can take over (enforced by the watchdog + `work.assign`).
- Selecting hundreds of units draws hundreds of render circles: cap `MAX_SELECT` and consider one
  aggregate box instead of per-unit circles if perf shows an issue.

**Open questions for the owner**
1. Is right-click the desired order key, or should orders be `alt+left-drag` to avoid conflicts with
   vanilla rotation/selection? (Fallback design in §0.2 covers both.)
2. Should guards on duty be commandable (releasing their tower post), or strictly exempt like
   shelterers and sleepers?
3. Should a whistle order override nightfall sleep, or yield to it? (Recommended: yield.)
4. Should the whistle be research-gated (e.g. behind Colony Logistics / a new M3 tech) or available
   from Settlement as the design's “optional micro” pillar implies? (Recommended: free from the
   first milestone — it is an ergonomics tool, not a power.)
5. Confirm the release target Factorio version (2.1.x) so the GUI-click fix is present.

**Recommended minimal first slice (scope for the implementer)**
- One `selection-tool` whistle + one right-click `custom-input` (order) + one Stop key.
- Left-drag selects colonists; right-click at a point issues Move, or Attack when an enemy is under
  the cursor, or Attack-Move (`attack_area`) when the alternate modifier/gesture is used.
- Per-player selection + render ids + lease ownership in `storage.command` with disconnect cleanup.
- Pure `model/command.lua` with commandable predicate, deterministic selection, abort intents,
  leased plan, completion/expiry; `work.assign` protects `"commanded"`.
- Spike `s18_command` first, then adapter/model, then tests/gates. Defer unit groups, compound
  commands, squad formations, patrol waypoints, and a dedicated `m3_command` integration spike to a
  follow-up issue.

## 7. Things I could NOT fully verify (flagged)

- **Mouse hooks are scriptable, but I could not exercise real mouse input headlessly.** The docs prove
  `CustomInputEvent.cursor_position` and `mouse-button-2`, and a 2.0.66 GUI-click bug was fixed
  upstream, but only the owner's in-game test can confirm the gesture feels right and does not
  conflict with vanilla. The selection-tool fallback (§0.2 point 4) is the safety net.
- **`attack_move` genuinely does not exist** in 2.1; `attack_area` is the documented substitute and
  its exact “return on completion” behaviour must be observed in `s18_command`.
- **Zero-area single-click selection** raising `on_player_selected_area` (needed if we use area centres
  for the fallback) is an assumption; spike logs it as **[needs in-game]** if the prototype-only check
  cannot prove it.
- I did not run the game or any tests while planning (per instructions: write only `PLAN.md`); all
  file/line references were read from the worktree at the time of planning.
