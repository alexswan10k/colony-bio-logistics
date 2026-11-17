-- Command Whistle adapter (#58). All rules live in model/command.lua; this file only turns input events into
-- plain data, resolves engine entities, and calls set_command. Events are registered at load time via
-- scripts.events. No per-tick scans: the only recurring work is a 300-tick watchdog while a lease is live.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work = require("scripts.work")
local model = require("scripts.model.command")
local M = {}

M.TOOL = "colony-command-whistle"
M.ORDER_INPUT = "colony-command-order"
M.STOP_INPUT = "colony-command-stop"

local function state()
  storage.command = storage.command or {}
  local s = storage.command
  s.selection, s.markers, s.owner, s.leased = s.selection or {}, s.markers or {}, s.owner or {}, s.leased or {}
  return s
end

-- The live entity for a unit number, through the colony registry (no engine object kept in storage).
local function entity_of(un)
  local st = storage.unit_state and storage.unit_state[un]
  local col = st and st.colony_id and storage.colonies and storage.colonies[st.colony_id]
  local e = col and col.colonists and col.colonists[un]
  return e and e.valid and e or nil
end

local function clear_markers(pi, marks)
  for _, obj in ipairs(marks or {}) do
    if obj and obj.valid then obj.destroy() end
  end
  state().markers[pi] = nil
end

local function draw_markers(pi, units)
  local s = state()
  clear_markers(pi, s.markers[pi])
  local marks = {}
  for _, un in ipairs(units) do
    local e = entity_of(un)
    if e and e.valid then
      -- 2.1's draw_circle takes `players` (not `for_player`): only the selecting player sees this circle,
      -- matching the per-player selection in storage.command.
      marks[#marks + 1] = rendering.draw_circle{surface = e.surface, target = e, radius = 0.85,
        color = {0.2, 0.9, 0.3, 0.9}, width = 2, filled = false, players = {pi}}
    end
  end
  s.markers[pi] = marks
end

local function clear_carry_sprite(un)
  local cur = storage.carry_sprites and storage.carry_sprites[un]
  if cur then
    if cur.obj and cur.obj.valid then cur.obj.destroy() end
    storage.carry_sprites[un] = nil
  end
end

local function arm_watchdog()
  local s = state()
  if not next(s.leased) or s.watchdog then return end
  s.watchdog = true
  scheduler.after(model.WATCHDOG_TICKS, "command.watchdog", {})
end

-- Hand a leased unit back to the workforce. `halt` is true for expiry/disconnect (a command may still be
-- running); completion already halted it, but a stop is harmless and keeps the unit from wandering.
local function release_lease(un, halt)
  local s = state()
  s.leased[un], s.owner[un] = nil, nil
  local st = storage.unit_state and storage.unit_state[un]
  if not model.is_commanded(st) then return end
  local e = entity_of(un)
  -- A commanded colonist can still ACQUIRE goods while leased: work.lua's kill-credit handler
  -- (on_entity_died) keys only on `job == "hunt"`, never on state, so a hunter that shoots under an
  -- Attack-Move order appends meat to the commanded state's `carry`. Same hazard for any future
  -- subsystem that writes carry/car/trailer/site_key into a leased state. Funnel through work.release
  -- exactly as work.assign's normal back-to-work path does (work.lua:2433) so those goods reach the
  -- hall and every claim is undone before the fresh idle state replaces this one.
  work.release(st)
  work.clear_label(un)
  clear_carry_sprite(un)
  storage.unit_state[un] = {colony_id = st.colony_id, job = st.job or "idle", state = "idle"}
  if halt and e and e.valid then
    e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 0,
      distraction = defines.distraction.none}
  end
  if st.colony_id then scheduler.after(1, "command.reassign", {un = un, colony_id = st.colony_id}) end
end
M.release_lease = release_lease   -- exposed for the s18_command regression case; no functions in storage

scheduler.register("command.reassign", function(d)
  local col = storage.colonies and storage.colonies[d.colony_id]
  if col then work.assign(col, d.un) end
end)

scheduler.register("command.watchdog", function()
  local s = state()
  s.watchdog = false
  local units = model.to_list(s.leased)
  for _, un in ipairs(units) do
    local st = storage.unit_state and storage.unit_state[un]
    if not model.is_commanded(st) then
      s.leased[un], s.owner[un] = nil, nil
    else
      local e = entity_of(un)
      local night = e and e.valid and work.is_sleep_time(e.surface)
      if model.expired(st, game.tick) or night then
        release_lease(un, true)   -- orders yield to sleep; nightfall takes the unit back
      end
    end
  end
  arm_watchdog()
end)

local DISTRACTION = {none = defines.distraction.none, by_enemy = defines.distraction.by_enemy}
local function engine_command(cmd)
  if cmd.kind == "go_to_location" then
    return {type = defines.command.go_to_location, destination = cmd.destination,
      radius = cmd.radius, distraction = DISTRACTION[cmd.distraction]}
  elseif cmd.kind == "attack_area" then
    return {type = defines.command.attack_area, destination = cmd.destination,
      radius = cmd.radius, distraction = DISTRACTION[cmd.distraction]}
  elseif cmd.kind == "attack" then
    local target = cmd.target
    if not (target and target.valid) then return nil end
    return {type = defines.command.attack, target = target, distraction = DISTRACTION[cmd.distraction]}
  end
  return {type = defines.command.stop, ticks_to_wait = 0, distraction = defines.distraction.none}
end

local function notify(player, pos, key, a, b)
  if not (player and player.valid) then return end
  player.create_local_flying_text{text = {key, a, b}, position = pos}
end

-- Issue a planned order. Every decision (who is commandable, what to abort, lease length) came from the model.
local function apply(pi, kind, target)
  local s = state()
  local units = model.to_list(s.selection[pi])
  if #units == 0 then
    local player = game.get_player(pi)
    notify(player, player and player.position or {x = 0, y = 0}, "colony-message.command-none")
    return 0
  end
  local pos = target and target.position or (game.get_player(pi) and game.get_player(pi).position) or {x = 0, y = 0}

  if kind == model.ORDERS.STOP then
    -- Only leased units are halted. Stopping a colonist mid-haul would strand its trip state, so a stop on a
    -- normally working colonist merely removes it from the selection and leaves work.lua's state machine alone.
    local stopped = 0
    for _, un in ipairs(units) do
      if model.is_commanded(storage.unit_state and storage.unit_state[un]) then
        local e = entity_of(un)
        if e and e.valid then
          e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 0,
            distraction = defines.distraction.none}
        end
        release_lease(un, false)
        stopped = stopped + 1
      end
    end
    local old_marks = s.markers[pi]
    s.selection[pi], s.markers[pi] = nil, nil
    clear_markers(pi, old_marks)
    notify(game.get_player(pi), pos, "colony-message.command-stopped", stopped)
    return stopped
  end

  local colonies, jobs, candidates = {}, {}, {}
  for _, un in ipairs(units) do
    local st = storage.unit_state and storage.unit_state[un]
    local e = entity_of(un)
    if st and e and e.name == "colony-colonist" then
      local ctx = {
        is_child = storage.age and storage.age[un] and storage.age[un].stage == "child",
        is_truck = storage.trucks and storage.trucks[un] ~= nil,
        is_commuter = storage.commuters and storage.commuters[un] ~= nil,
        driving = st.state == "driving",
      }
      if model.commandable(st, ctx) then
        candidates[#candidates + 1] = un
        colonies[un], jobs[un] = st.colony_id, st.job
      end
    end
  end
  if #candidates == 0 then
    notify(game.get_player(pi), pos, "colony-message.command-protected", #units)
    return 0, #units
  end

  local plan = model.plan(candidates, kind, target, game.tick,
    {colonies = colonies, jobs = jobs, owner = pi})
  local ordered = 0
  for _, un in ipairs(candidates) do
    local st = storage.unit_state[un]
    local e = entity_of(un)
    local cmd = plan.commands[un]
    if cmd.target_un then
      cmd.target = (target and target.enemy and target.enemy.valid and target.enemy)
        or game.get_entity_by_unit_number(cmd.target_un)
    end
    local engine = engine_command(cmd)
    if engine and e and e.valid then
      local intents = model.abort_intents(st)
      -- Free the hut post BEFORE work.release so its research-lab status recount sees the smaller crew.
      if intents.free_hut_slot and st.hut and st.hut.workers then st.hut.workers[un] = nil end
      if intents.clear_carry_sprite then clear_carry_sprite(un) end
      work.release(st)           -- carry, site claim, car/trailer, research status; sets state idle
      work.clear_label(un)
      storage.unit_state[un] = plan.states[un]
      e.commandable.set_command(engine)
      work.set_label(e, model.label_for(kind), true)
      s.leased[un], s.owner[un] = true, pi
      ordered = ordered + 1
    end
  end
  arm_watchdog()
  local noun = kind == model.ORDERS.MOVE and "colony-message.command-move"
    or (kind == model.ORDERS.ATTACK_MOVE and "colony-message.command-attack-move"
      or "colony-message.command-attack")
  notify(game.get_player(pi), pos, "colony-message.command-ordered", ordered, {noun})
  return ordered, #units - #candidates
end

-- Order at the world position carried by a custom-input event (s18_command proved cursor_position exists).
events.on(M.ORDER_INPUT, function(ev)
  if ev.in_gui then return end
  local player = game.get_player(ev.player_index)
  if not (player and player.valid) then return end
  local ct = player.controller_type
  if ct ~= defines.controllers.character and ct ~= defines.controllers.god then return end
  local stack = player.cursor_stack
  if not (stack and stack.valid_for_read and stack.name == M.TOOL) then return end
  local pos = ev.cursor_position or player.position
  local kind, enemy_un, enemy = model.ORDERS.MOVE, nil, nil
  local found = player.surface.find_entities_filtered{position = pos,
    radius = model.CLICK_TARGET_RADIUS, force = "enemy",
    type = {"unit", "turret", "unit-spawner"}}
  local best
  for _, e in ipairs(found or {}) do
    if e and e.valid then
      local dx, dy = e.position.x - pos.x, e.position.y - pos.y
      local d = dx * dx + dy * dy
      if not best or d < best.d or (d == best.d and e.unit_number < best.e.unit_number) then
        best = {d = d, e = e}
      end
    end
  end
  if best then
    kind, enemy, enemy_un = model.ORDERS.ATTACK, best.e, best.e.unit_number
  end
  apply(ev.player_index, kind, {position = {x = pos.x, y = pos.y}, enemy_un = enemy_un, enemy = enemy})
end)

events.on(M.STOP_INPUT, function(ev)
  if ev.in_gui then return end
  local player = game.get_player(ev.player_index)
  if not (player and player.valid) then return end
  local stack = player.cursor_stack
  if not (stack and stack.valid_for_read and stack.name == M.TOOL) then return end
  apply(ev.player_index, model.ORDERS.STOP, nil)
end)

-- Selection gestures. The same event family the logistics marker uses; all four raise ev.entities/ev.area.
local function centre(area)
  local a, b = area and area.left_top, area and area.right_bottom
  if not (a and b) then return {x = 0, y = 0} end
  return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
end

events.on(defines.events.on_player_selected_area, function(ev)
  if ev.item ~= M.TOOL then return end
  local s = state()
  local ids = {}
  for _, e in ipairs(ev.entities or {}) do
    if e and e.valid and e.name == "colony-colonist" then ids[#ids + 1] = e.unit_number end
  end
  local units = model.select(s.selection[ev.player_index], ids, "set")
  s.selection[ev.player_index] = units
  draw_markers(ev.player_index, units)
  if #units == 0 then
    notify(game.get_player(ev.player_index), centre(ev.area), "colony-message.command-none")
  end
end)

events.on(defines.events.on_player_alt_selected_area, function(ev)
  if ev.item ~= M.TOOL then return end
  apply(ev.player_index, model.ORDERS.MOVE, {position = centre(ev.area)})
end)

events.on(defines.events.on_player_reverse_selected_area, function(ev)
  if ev.item ~= M.TOOL then return end
  apply(ev.player_index, model.ORDERS.ATTACK_MOVE, {position = centre(ev.area), radius = 8})
end)

events.on(defines.events.on_player_alt_reverse_selected_area, function(ev)
  if ev.item ~= M.TOOL then return end
  apply(ev.player_index, model.ORDERS.STOP, nil)
end)

-- Completion: work.lua returns early for `commanded` states, so this handler owns the lease.
local RESULT = {}
RESULT[tostring(defines.behavior_result.success)] = "success"
RESULT[tostring(defines.behavior_result.fail)] = "fail"
RESULT[tostring(defines.behavior_result.in_progress)] = "in_progress"
RESULT[tostring(defines.behavior_result.deleted)] = "deleted"

events.on(defines.events.on_ai_command_completed, function(ev)
  local st = storage.unit_state and storage.unit_state[ev.unit_number]
  if not model.is_commanded(st) then return end
  local result = RESULT[tostring(ev.result)] or "fail"
  if model.after_completion(st, result, game.tick) == "release_to_work" then
    release_lease(ev.unit_number, false)
  end
end)

-- Disconnect: drop every render object and lease that player owned, so nobody is stranded in `commanded`.
local function disconnect(ev)
  local pi = ev.player_index
  local s = state()
  local out = model.drop_player(s, pi)
  clear_markers(pi, out.markers_removed)
  s.selection, s.markers, s.owner = out.selection, out.markers, out.owner
  for _, un in ipairs(out.released) do release_lease(un, true) end
  if #out.released > 0 then game.print({"colony-message.command-disconnected"}) end
end
events.on(defines.events.on_player_left_game, disconnect)
events.on(defines.events.on_player_removed, disconnect)

return M
