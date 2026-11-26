-- Patrol adapter (M3 defence stack, #57). All route/target/lease rules live in pure model/patrol.lua; this
-- file only resolves live entities, translates neutral command descriptions through the SAME shared
-- engine_command mapping as the Command Whistle, and arms scheduler timers. No per-tick scans: dispatch and
-- engagement are event/timer-driven, and a lease expires on a scheduler timer (attack_area + by_enemy emits
-- no completion while a target survives - s19_defence). Bind via M.bind (no runtime require cycle).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work = require("scripts.work")
local engine_command = require("scripts.engine_command")
local command_model = require("scripts.model.command")
local patrol_model = require("scripts.model.patrol")
local M = {}

-- M.bind stays part of the bind protocol; this adapter needs no colony reference.
function M.bind() end

local militia_mod  -- injected by scripts.colony via M.bind_militia (cycle-safe)
function M.bind_militia(m) militia_mod = m end

M.POST = "colony-patrol-post"
M.DISPATCH_TICKS = 300
M.POST_RANGE = 32              -- dispatch only recruits militia near the post

local function state()
  storage.patrol_ui = storage.patrol_ui or {}
  storage.patrol_ui.selection = storage.patrol_ui.selection or {}
  return storage.patrol_ui
end

local function entity_of(colony, un)
  local e = colony and colony.colonists and colony.colonists[un]
  return e and e.valid and e or nil
end

-- Posts -----------------------------------------------------------------------------------------------------

--- Register a player-built Patrol Post. Waypoints live as plain data in colony.patrol_posts[un]; the active
--- patrols live in colony.patrols[un] (the registry named in PLAN Stage 3). Both are created by migration [41].
function M.register_post(colony, e, dict)
  if not (colony and e and e.valid) then return end
  colony.patrol_posts = colony.patrol_posts or {}
  colony.patrol_posts[e.unit_number] = {entity = e, colony_id = colony.id, waypoints = {}}
  script.register_on_object_destroyed(e)
  if not colony.patrol_dispatch then
    colony.patrol_dispatch = true
    scheduler.after(M.DISPATCH_TICKS, "patrol.dispatch", {colony_id = colony.id})
  end
end

--- Posts sorted by unit number, dead ones pruned. Deterministic for route building and the GUI.
function M.posts(colony)
  local out = {}
  for un, p in pairs(colony and colony.patrol_posts or {}) do
    if p.entity and p.entity.valid then out[#out + 1] = {id = un, colony_id = p.colony_id,
      waypoints = p.waypoints, entity = p.entity, record = p}
    else
      colony.patrol_posts[un] = nil
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.add_waypoint(colony, post_un, pos, before)
  local p = colony and colony.patrol_posts and colony.patrol_posts[post_un]
  if not (p and p.entity and p.entity.valid and pos) then return nil end
  local wp = {x = pos.x, y = pos.y}
  local list = p.waypoints
  local idx = before and math.max(1, math.min(before, #list + 1)) or (#list + 1)
  table.insert(list, idx, wp)
  return idx
end

function M.remove_waypoint(colony, post_un, idx)
  local p = colony and colony.patrol_posts and colony.patrol_posts[post_un]
  if not (p and p.waypoints and p.waypoints[idx]) then return false end
  table.remove(p.waypoints, idx)
  return true
end

function M.clear_waypoints(colony, post_un)
  local p = colony and colony.patrol_posts and colony.patrol_posts[post_un]
  if p then p.waypoints = {} end
end

M.RANGE = patrol_model.RANGE
M.ENGAGE_RADIUS = patrol_model.ENGAGE_RADIUS

-- Patrol lifecycle -------------------------------------------------------------------------------------------

local function waypoint_cmd(wp)
  local cmd = command_model.command_for(command_model.ORDERS.MOVE, {position = {x = wp.x, y = wp.y}})
  cmd.distraction = patrol_model.distraction_for("move")
  return engine_command.to_engine(cmd)
end

local function engage_cmd(target)
  local cmd = command_model.command_for(command_model.ORDERS.ATTACK_MOVE,
    {position = {x = target.position.x, y = target.position.y}, radius = patrol_model.ENGAGE_RADIUS})
  cmd.distraction = patrol_model.distraction_for("attack_area")
  return engine_command.to_engine(cmd)
end

local function valid(rec, colony, un, st, seq)
  return rec and colony and colony.patrols and colony.patrols[un] == rec
    and st and patrol_model.is_patrol(st) and rec.seq == st.patrol_seq
    and (seq == nil or seq == rec.seq)   -- stale timers from a preempted generation are no-ops
end

local function travel_to(rec, colony, un, e)
  local wp = rec.route[rec.idx]
  if not (wp and e and e.valid) then return false end
  local engine = waypoint_cmd(wp)
  if engine then e.commandable.set_command(engine) end
  return true
end

local function resume_travel(colony, un, st, rec, e, keep_target)
  st.state = "patrolling"
  st.target_un, st.site = nil, nil
  -- NB: attempts are PER TARGET and must survive a failed command. Resetting them here (every failed path
  -- calls resume_travel) meant the counter could never reach MAX_PATH_ATTEMPTS and no blacklist ever formed.
  -- The target must also survive a retry: a fail completion carries only the *patroller's* unit number, so
  -- without keep_target the third failure would find target_un already cleared and blacklist nothing.
  -- `rec.target` is the LIVE entity from target_select; enemy units/spawners cannot be re-resolved with
  -- game.get_entity_by_unit_number in 2.1 (they lack the get-by-unit-number flag), so it must ride along.
  if not keep_target then rec.target = nil end
  rec.engage_at = nil
  if e and e.valid then work.set_label(e, "patrol", true) end
  travel_to(rec, colony, un, e)
  scheduler.after(patrol_model.CHECK_TICKS, "patrol.step",
    {un = un, colony_id = colony.id, seq = rec.seq})
end

--- Hand a patrolling militia back to the workforce. `work.release` returns any kill-credit carry to the hall
--- and undoes claims; gear is pure data and is deliberately kept so `command.reassign` re-posts an armed unit
--- (to bed at night, back on duty by day). The follow-up reassign is the SAME handler a whistle lease uses.
function M.end_patrol(colony, un, reason)
  if not (colony and colony.patrols) then return end
  local st = storage.unit_state and storage.unit_state[un]
  colony.patrols[un] = nil
  if not st then return end
  st.target_un, st.until_tick, st.patrol_seq, st.attempts = nil, nil, nil, nil
  local e = entity_of(colony, un)
  work.release(st)            -- carry, site claim, car/trailer; sets state = "idle"; keeps st.gear
  work.clear_label(un)
  if e and e.valid then e.commandable.set_command(engine_command.stop()) end
  if reason == "night" or reason == "lease" then
    scheduler.after(1, "command.reassign", {un = un, colony_id = colony.id})
  end
end

--- Start one militia on a post route. Returns false when there is no route or the unit has no gear.
function M.start(colony, un, e, st)
  if not (colony and e and e.valid and st) then return false end
  if not (st.job == "militia" and e.name == "colony-militia") then return false end
  if not (st.gear and st.gear.weapon) then return false end   -- an unarmed militia cannot clear a nest
  local route = patrol_model.route(M.posts(colony), colony.id)
  if #route == 0 then return false end
  colony.patrols = colony.patrols or {}
  if colony.patrols[un] then return false end
  colony.patrol_seq = (colony.patrol_seq or 0) + 1
  local seq = colony.patrol_seq
  local rec = {post = route[1].post, route = route, idx = 1,
    until_tick = patrol_model.lease_tick(game.tick), target_un = nil, target = nil, attempts = 0,
    blacklist = {}, seq = seq, started = game.tick}
  colony.patrols[un] = rec
  st.state = "patrolling"
  st.colony_id = colony.id
  st.patrol_seq = seq
  st.until_tick = rec.until_tick
  st.target_un, st.site = nil, nil
  work.set_label(e, "patrol", true)
  travel_to(rec, colony, un, e)
  scheduler.after(patrol_model.CHECK_TICKS, "patrol.step", {un = un, colony_id = colony.id, seq = seq})
  scheduler.after(patrol_model.LEASE_TICKS, "patrol.lease", {un = un, colony_id = colony.id, seq = seq})
  return true
end

--- Command Whistle preemption hook (M3 Stage 3): drop the route claim and invalidate every deferred timer by
--- bumping the sequence. Gear is NOT returned here - command.apply carries it into the lease (abort_intents).
function M.abort(un, st)
  local colony = st and storage.colonies and storage.colonies[st.colony_id]
  if not (colony and colony.patrols) then return end
  if colony.patrols[un] then
    colony.patrol_seq = (colony.patrol_seq or 0) + 1
    st.patrol_seq = colony.patrol_seq
    colony.patrols[un] = nil
  end
  st.target_un, st.until_tick = nil, nil
end

-- timers -----------------------------------------------------------------------------------------------------

scheduler.register("patrol.step", function(d)
  local colony = storage.colonies and storage.colonies[d.colony_id]
  local st = storage.unit_state and storage.unit_state[d.un]
  local rec = colony and colony.patrols and colony.patrols[d.un]
  if not valid(rec, colony, d.un, st, d.seq) then return end
  local e = entity_of(colony, d.un)
  if not e then return M.end_patrol(colony, d.un, "gone") end
  if work.is_sleep_time(e.surface) then return M.end_patrol(colony, d.un, "night") end
  if game.tick >= (rec.until_tick or 0) then return M.end_patrol(colony, d.un, "lease") end
  rec.blacklist = patrol_model.expire_blacklist(rec.blacklist, game.tick)

  local pos, r = e.position, patrol_model.RANGE
  local list = {}
  -- Patrols are the nest-clearing job (#57): unlike a posted guard, they also see spawners (never worms or
  -- other non-unit structures). s19_defence proved attack_area + by_enemy works against a live spawner.
  for _, en in ipairs(e.surface.find_entities_filtered{type = {"unit", "unit-spawner"}, force = "enemy",
      area = {{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}}}) do
    if en.valid then list[#list + 1] = {unit_number = en.unit_number, position = en.position, entity = en} end
  end
  local pick = patrol_model.target_select(list, pos, r, rec.blacklist, game.tick)
  if pick then
    st.state, st.target_un = "patrol-engage", pick.unit_number
    -- Keep the LIVE entity from the scan. Enemy `unit`/`unit-spawner` prototypes lack Factorio 2.1's
    -- get-by-unit-number flag, so resolving pick.unit_number later with game.get_entity_by_unit_number
    -- returns nil and the engagement can never strike. This is a transient lease field, exactly like st.site.
    rec.target_un, rec.target, rec.attempts, rec.engage_at = pick.unit_number, pick.entity, 0, game.tick
    local engine = engage_cmd(pick)
    if engine then e.commandable.set_command(engine) end
    work.set_label(e, "patrol ⚔", true)
    scheduler.after(patrol_model.ENGAGE_TICKS, "patrol.engage",
      {un = d.un, colony_id = colony.id, seq = rec.seq})
    return
  end

  local wp = rec.route[rec.idx]
  if wp then
    local dx, dy = wp.x - pos.x, wp.y - pos.y
    if dx * dx + dy * dy <= patrol_model.REACH * patrol_model.REACH then
      local _, next_idx = patrol_model.next_waypoint(rec.route, rec.idx)
      rec.idx = next_idx or 1
    end
  end
  travel_to(rec, colony, d.un, e)
  scheduler.after(patrol_model.CHECK_TICKS, "patrol.step",
    {un = d.un, colony_id = colony.id, seq = rec.seq})
end)

scheduler.register("patrol.engage", function(d)
  local colony = storage.colonies and storage.colonies[d.colony_id]
  local st = storage.unit_state and storage.unit_state[d.un]
  local rec = colony and colony.patrols and colony.patrols[d.un]
  if not valid(rec, colony, d.un, st, d.seq) or st.state ~= "patrol-engage" then return end
  local e = entity_of(colony, d.un)
  if not e then return M.end_patrol(colony, d.un, "gone") end
  -- Night ends the patrol here too (patrol.step is only a 45-tick scan): without this an engagement kept
  -- re-arming itself for the whole ENGAGE_COOLDOWN after nightfall, contradicting "nightfall ends it".
  if work.is_sleep_time(e.surface) then return M.end_patrol(colony, d.un, "night") end
  -- The live entity was captured by target_select in patrol.step. Do NOT look it up by unit number: in 2.1
  -- unit/unit-spawner prototypes lack get-by-unit-number, so game.get_entity_by_unit_number always returns
  -- nil here and should_disengage(nil) would silently skip every strike.
  local target = rec.target
  local hp = target and target.valid and target.health or nil
  local cooldown = (rec.engage_at or game.tick) + patrol_model.ENGAGE_COOLDOWN - game.tick
  if patrol_model.should_disengage(hp, cooldown) then
    if hp and hp > 0 then
      -- Timed out on a live target (a turret-pinned biter / a nest that cannot be reached): skip it a while.
      rec.blacklist[rec.target_un] = game.tick + patrol_model.BLACKLIST_TICKS
    end
    return resume_travel(colony, d.un, st, rec, e)
  end
  -- One scripted strike per engagement tick, using Stage 1's damage + wear rules (no new combat model).
  -- The engine's attack_area keeps walking the unit toward the target while this timer ticks.
  if militia_mod then militia_mod.patrol_strike(colony, d.un, st, target) end
  scheduler.after(patrol_model.ENGAGE_TICKS, "patrol.engage",
    {un = d.un, colony_id = colony.id, seq = rec.seq})
end)

scheduler.register("patrol.lease", function(d)
  local colony = storage.colonies and storage.colonies[d.colony_id]
  local st = storage.unit_state and storage.unit_state[d.un]
  local rec = colony and colony.patrols and colony.patrols[d.un]
  if not valid(rec, colony, d.un, st, d.seq) then return end   -- stale lease: a preemption already bumped the seq
  M.end_patrol(colony, d.un, "lease")
end)

-- Recruit idle militia for posts with waypoints. One staggered timer per colony, armed by register_post and
-- re-armed here; it stops entirely once no post remains (no per-tick scan in towns without posts).
scheduler.register("patrol.dispatch", function(d)
  local colony = storage.colonies and storage.colonies[d.colony_id]
  if not colony then return end
  if not colony.patrol_posts or not next(colony.patrol_posts) then
    colony.patrol_dispatch = nil
    return
  end
  for _, post in ipairs(M.posts(colony)) do
    if post.entity and post.entity.valid and #post.waypoints > 0 then
      local on_route, occupied = 0, {}
      for un, rec in pairs(colony.patrols or {}) do
        if rec.post == post.id then on_route = on_route + 1 end
        occupied[un] = true
      end
      local candidates = {}
      for un, e in pairs(colony.colonists or {}) do
        local st = storage.unit_state and storage.unit_state[un]
        if not occupied[un] and e.valid and e.name == "colony-militia" and st
            and st.job == "militia" and st.state == "militia-hold" then
          local dx = e.position.x - post.entity.position.x
          local dy = e.position.y - post.entity.position.y
          if dx * dx + dy * dy <= M.POST_RANGE * M.POST_RANGE then candidates[#candidates + 1] = un end
        end
      end
      table.sort(candidates)
      for _, un in ipairs(candidates) do
        if on_route >= patrol_model.POST_SQUAD then break end
        local st = storage.unit_state[un]
        local e = entity_of(colony, un)
        if M.start(colony, un, e, st) then on_route = on_route + 1 end
      end
    end
  end
  scheduler.after(M.DISPATCH_TICKS, "patrol.dispatch", d)
end)

-- Completion is only an EARLY-RELEASE hint for a patrol. Lease expiry is always scheduler-driven:
-- attack_area + by_enemy has no completion event while a hostile survives (s19_defence).
local RESULT = {}
RESULT[tostring(defines.behavior_result.success)] = "success"
RESULT[tostring(defines.behavior_result.fail)] = "fail"
RESULT[tostring(defines.behavior_result.in_progress)] = "in_progress"
RESULT[tostring(defines.behavior_result.deleted)] = "deleted"

local function on_command_completed(ev)
  local st = storage.unit_state and storage.unit_state[ev.unit_number]
  if not (st and patrol_model.is_patrol(st)) then return end
  local colony = storage.colonies and storage.colonies[st.colony_id]
  local rec = colony and colony.patrols and colony.patrols[ev.unit_number]
  if not valid(rec, colony, ev.unit_number, st) then return end
  local e = entity_of(colony, ev.unit_number)
  if not e then return end
  local result = RESULT[tostring(ev.result)] or "fail"
  if result == "in_progress" then return end
  -- A path into a nest may fail repeatedly. The engine event names the *patroller*, not its target, so keep
  -- both the unit number AND the live entity across retries; clear them only once the target is blacklisted
  -- or the command succeeded. (The lookup-by-unit-number API cannot see enemy units/spawners in 2.1.)
  local failing, failing_ent = rec.target_un, rec.target
  local keep = false
  if result == "fail" or result == "deleted" then
    rec.attempts = (rec.attempts or 0) + 1
    if rec.attempts >= patrol_model.MAX_PATH_ATTEMPTS then
      if failing then rec.blacklist[failing] = game.tick + patrol_model.BLACKLIST_TICKS end
      local _, next_idx = patrol_model.next_waypoint(rec.route, rec.idx)
      rec.idx, rec.attempts = next_idx or 1, 0
    else
      keep = true   -- keep for the next failed path
    end
  end
  rec.target_un = keep and failing or nil
  rec.target = keep and failing_ent or nil
  -- destroy_when_commands_fail=false keeps the unit alive; this resume is the ONLY place its state changes.
  resume_travel(colony, ev.unit_number, st, rec, e, true)
end
events.on(defines.events.on_ai_command_completed, on_command_completed)
M.on_command_completed = on_command_completed   -- exposed for the m3_patrol failed-path regression

-- A mined post drops its waypoints; active patrols finish their current loop against the cached route (the
-- next dispatch will not re-post them). A DEAD PATROLLER is different: work.lua's on_object_destroyed nils
-- storage.unit_state[un], so every timer path that validates through valid(st) returns early and would leave
-- a stale colony.patrols[un] forever. With POST_SQUAD=2 two such leaks make a post permanently inert. This
-- handler must therefore prune the patrol lease WITHOUT requiring unit_state, using only the unit number.
events.on(defines.events.on_object_destroyed, function(ev)
  local un = ev.useful_id
  if not un then return end
  for _, colony in pairs(storage.colonies or {}) do
    if colony.patrol_posts and colony.patrol_posts[un] then colony.patrol_posts[un] = nil end
    if colony.patrols and colony.patrols[un] then
      colony.patrols[un] = nil
      colony.patrol_seq = (colony.patrol_seq or 0) + 1   -- invalidate any deferred timer for that generation
      work.clear_label(un)
    end
  end
  for _, sel in pairs(state().selection) do
    for i, p in ipairs(sel) do if p == un then table.remove(sel, i) break end end
  end
end)

-- Waypoint placement: a selection tool picks posts (left-drag), then a custom input appends the world point
-- under the cursor to every selected post, in click order. This is the same pattern as scripts/command.lua.
events.on(defines.events.on_player_selected_area, function(ev)
  if ev.item ~= "colony-patrol-marker" then return end
  local ids = {}
  for _, e in ipairs(ev.entities or {}) do
    if e and e.valid and e.name == M.POST then ids[#ids + 1] = e.unit_number end
  end
  table.sort(ids)
  state().selection[ev.player_index] = ids
  local player = game.get_player(ev.player_index)
  if #ids > 0 and player and player.valid and ev.area then
    player.create_local_flying_text{
      text = {"colony-message.patrol-selected", #ids}, position = ev.area.left_top}
  end
end)

local function nearest_post(surface, pos)
  local best, best_d
  for _, e in ipairs(surface.find_entities_filtered{name = M.POST,
      area = {{pos.x - 24, pos.y - 24}, {pos.x + 24, pos.y + 24}}}) do
    if e and e.valid then
      local d = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
      if not best_d or d < best_d or (d == best_d and e.unit_number < best.unit_number) then
        best, best_d = e, d
      end
    end
  end
  return best
end

events.on("colony-patrol-waypoint", function(ev)
  if ev.in_gui then return end
  local player = game.get_player(ev.player_index)
  if not (player and player.valid) then return end
  local stack = player.cursor_stack
  if not (stack and stack.valid_for_read and stack.name == "colony-patrol-marker") then return end
  local pos = ev.cursor_position or player.position
  local posts = state().selection[ev.player_index] or {}
  if #posts == 0 then
    local e = nearest_post(player.surface, pos)
    posts = e and {e.unit_number} or {}
  end
  local added, colony = 0, nil
  for _, un in ipairs(posts) do
    for _, c in pairs(storage.colonies or {}) do
      if c.patrol_posts and c.patrol_posts[un] then colony = c break end
    end
    if colony and M.add_waypoint(colony, un, pos) then added = added + 1 end
  end
  player.create_local_flying_text{text = {"colony-message.patrol-waypoint", added}, position = pos}
end)

events.on("colony-patrol-clear", function(ev)
  if ev.in_gui then return end
  local player = game.get_player(ev.player_index)
  if not (player and player.valid) then return end
  local stack = player.cursor_stack
  if not (stack and stack.valid_for_read and stack.name == "colony-patrol-marker") then return end
  local pos = ev.cursor_position or player.position
  local posts = state().selection[ev.player_index] or {}
  if #posts == 0 then
    local e = nearest_post(player.surface, pos)
    posts = e and {e.unit_number} or {}
  end
  for _, un in ipairs(posts) do
    for _, c in pairs(storage.colonies or {}) do
      if c.patrol_posts and c.patrol_posts[un] then M.clear_waypoints(c, un) break end
    end
  end
end)

return M
