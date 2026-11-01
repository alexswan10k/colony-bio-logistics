-- SPIKE #1: Can ~hundreds of `unit` colonists perform scheduled "work" cheaply?
--
-- Usage in-game (as a player, standing near a forest):
--   /spike_units 300       spawn 300 colonists; each walks to a tree, "works" 5s, destroys it, repeats
--   /spike_report          print stats (completed jobs, path failures, avg Lua time per tick)
--   /spike_clear           kill all spike colonists & reset
-- Biter check: place a few biters/spawner nearby and watch the report's "killed" counter.
--
-- Design: no per-tick polling per unit. Work = go_to_location command -> on_ai_command_completed
-- -> storage.scheduled[tick + WORK_TICKS] -> effect. Only one on_tick handler pops the bucket.

local WORK_TICKS = 300
local SEARCH_RADIUS = 80

local function init()
  storage.spike = storage.spike or {
    units = {},        -- unit_number -> {entity=, tree=}
    claimed = {},      -- tree unit_number/position key -> true
    scheduled = {},    -- tick -> {unit_number,...}
    stats = {done = 0, path_fail = 0, no_tree = 0, killed = 0, spawned = 0},
    prof_ticks = 0, prof_ms = 0,
  }
  return storage.spike
end

local function tree_key(t) return t.position.x .. "," .. t.position.y end

local function assign(s, un)
  local rec = s.units[un]
  if not (rec and rec.entity and rec.entity.valid) then return end
  local e = rec.entity
  local trees = e.surface.find_entities_filtered{position = e.position, radius = SEARCH_RADIUS, type = "tree"}
  local pick
  for _ = 1, 10 do
    local t = trees[math.random(#trees)]   -- spike only; use game.create_random_generator() for real code
    if t and not s.claimed[tree_key(t)] then pick = t break end
  end
  if not pick then
    s.stats.no_tree = s.stats.no_tree + 1
    s.scheduled[game.tick + 120] = s.scheduled[game.tick + 120] or {}
    table.insert(s.scheduled[game.tick + 120], {un = un, retry = true})
    return
  end
  s.claimed[tree_key(pick)] = true
  rec.tree = pick
  rec.phase = "walking"
  e.commandable.set_command{
    type = defines.command.go_to_location,
    destination = pick.position,
    radius = 1.5,
    distraction = defines.distraction.none,
  }
end

local function spawn(player, n)
  local s = init()
  local surface = player.surface
  for _ = 1, n do
    local pos = surface.find_non_colliding_position("colony-colonist", player.position, 20, 0.5)
    if pos then
      local e = surface.create_entity{name = "colony-colonist", position = pos, force = player.force}
      if e then
        s.units[e.unit_number] = {entity = e}
        script.register_on_object_destroyed(e)
        s.stats.spawned = s.stats.spawned + 1
        assign(s, e.unit_number)
      end
    end
  end
end

script.on_event(defines.events.on_ai_command_completed, function(ev)
  local s = storage.spike
  if not s then return end
  local rec = s.units[ev.unit_number]
  if not rec then return end
  if ev.result ~= defines.behavior_result.success then
    s.stats.path_fail = s.stats.path_fail + 1
    if rec.tree and rec.tree.valid then s.claimed[tree_key(rec.tree)] = nil end
    rec.tree = nil
    assign(s, ev.unit_number)
    return
  end
  rec.phase = "working"
  local t = game.tick + WORK_TICKS
  s.scheduled[t] = s.scheduled[t] or {}
  table.insert(s.scheduled[t], {un = ev.unit_number})
end)

script.on_event(defines.events.on_tick, function(ev)
  local s = storage.spike
  if not s then return end
  local prof = game.create_profiler()
  local bucket = s.scheduled[ev.tick]
  if bucket then
    s.scheduled[ev.tick] = nil
    for _, job in ipairs(bucket) do
      local rec = s.units[job.un]
      if rec then
        if rec.tree and rec.tree.valid and not job.retry then
          s.claimed[tree_key(rec.tree)] = nil
          rec.tree.destroy()
          s.stats.done = s.stats.done + 1
        end
        rec.tree = nil
        assign(s, job.un)
      end
    end
  end
  prof.stop()
  -- accumulate coarse timing; profiler objects can only be logged, so log every 600 ticks
  s.prof_ticks = s.prof_ticks + 1
  if s.prof_ticks % 600 == 0 then log{"", "[spike_units] tick ", ev.tick, " handler: ", prof} end
end)

script.on_event(defines.events.on_object_destroyed, function(ev)
  local s = storage.spike
  if s and ev.useful_id and s.units[ev.useful_id] then
    s.units[ev.useful_id] = nil
    s.stats.killed = s.stats.killed + 1
  end
end)

commands.add_command("spike_units", "N - spawn N spike colonists", function(cmd)
  local p = game.get_player(cmd.player_index)
  spawn(p, tonumber(cmd.parameter) or 100)
end)

commands.add_command("spike_report", "print spike stats", function(cmd)
  local s = init()
  local alive = 0
  for _ in pairs(s.units) do alive = alive + 1 end
  game.print(string.format("[spike] alive=%d spawned=%d jobs_done=%d path_fail=%d no_tree=%d killed=%d",
    alive, s.stats.spawned, s.stats.done, s.stats.path_fail, s.stats.no_tree, s.stats.killed))
  game.print("[spike] Lua handler timing is in factorio-current.log ('[spike_units]'); use --benchmark for UPS.")
end)

commands.add_command("spike_clear", "remove spike colonists", function()
  local s = init()
  for _, rec in pairs(s.units) do if rec.entity.valid then rec.entity.destroy() end end
  storage.spike = nil
  init()
end)
