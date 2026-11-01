-- SPIKE #1: Can ~hundreds of `unit` colonists do scheduled "work" cheaply, and how do biters treat them?
-- /spike run s01_units [N=100] [seconds=60] [biters=0]
-- Stand near a forest. Colonists walk to a tree, "work" 300 ticks, destroy it, repeat. No per-tick polling per unit.
-- Run twice: default, and with startup setting "colony-spike-no-attack" ticked (does a unit load w/o attack_parameters?).
local core = require("scripts.spike.core")
local events = require("scripts.events")

local WORK_TICKS, SEARCH_RADIUS = 300, 80
local S  -- module-local state (spike only)

local function key(t) return t.position.x .. "," .. t.position.y end

local function assign(un)
  local rec = S.units[un]
  if not (rec and rec.entity.valid) then return end
  local e = rec.entity
  local trees = e.surface.find_entities_filtered{position = e.position, radius = SEARCH_RADIUS, type = "tree"}
  local pick
  for _ = 1, 10 do
    local t = trees[S.rng(1, math.max(#trees, 1))]
    if t and not S.claimed[key(t)] then pick = t break end
  end
  if not pick then
    S.stats.no_tree = S.stats.no_tree + 1
    local t = game.tick + 120
    S.sched[t] = S.sched[t] or {}; table.insert(S.sched[t], {un = un, retry = true})
    return
  end
  S.claimed[key(pick)] = true
  rec.tree = pick
  e.commandable.set_command{type = defines.command.go_to_location, destination = pick.position,
    radius = 1.5, distraction = defines.distraction.none}
end

events.on(defines.events.on_ai_command_completed, function(ev)
  if not S then return end
  local rec = S.units[ev.unit_number]
  if not rec then return end
  if ev.result ~= defines.behavior_result.success then
    S.stats.path_fail = S.stats.path_fail + 1
    if rec.tree and rec.tree.valid then S.claimed[key(rec.tree)] = nil end
    rec.tree = nil
    assign(ev.unit_number)
    return
  end
  local t = game.tick + WORK_TICKS
  S.sched[t] = S.sched[t] or {}; table.insert(S.sched[t], {un = ev.unit_number})
end)

events.on(defines.events.on_tick, function(ev)
  if not S or S.done then return end
  local p = core.mkprof()
  local bucket = S.sched[ev.tick]
  if bucket then
    S.sched[ev.tick] = nil
    for _, job in ipairs(bucket) do
      local rec = S.units[job.un]
      if rec then
        if rec.tree and rec.tree.valid and not job.retry then
          S.claimed[key(rec.tree)] = nil
          rec.tree.destroy()
          S.stats.done = S.stats.done + 1
        end
        rec.tree = nil
        assign(job.un)
      end
    end
  end
  p.stop(); S.acc.add(p); S.ticks = S.ticks + 1
  if ev.tick >= S.end_tick then
    S.done = true
    local ctx = S.ctx
    local alive = 0
    for _ in pairs(S.units) do alive = alive + 1 end
    S.acc.divide(S.ticks)
    ctx.log({"", "[PROF] work-dispatch handler avg per tick over ", S.ticks, " ticks: ", S.acc})
    ctx.log(string.format("alive=%d spawned=%d jobs_done=%d path_fail=%d no_tree=%d killed=%d",
      alive, S.stats.spawned, S.stats.done, S.stats.path_fail, S.stats.no_tree, S.stats.killed))
    ctx.check("colonists complete work loop", S.stats.done > 0, S.stats.done .. " jobs")
    ctx.check("path failure rate < 10%", S.stats.path_fail < 0.1 * math.max(S.stats.done, 1), S.stats.path_fail .. " fails")
    ctx.check("no unexpected deaths (biters=0 runs)", S.biters > 0 or S.stats.killed == 0, S.stats.killed .. " killed")
    if S.biters > 0 then ctx.log("biter run: colonists killed=" .. S.stats.killed .. " (colonists are attackable if >0)") end
    ctx.log("NEXT: measure UPS with scripts/benchmark.sh; also look for stuck units (alive but no jobs_done growth) and wandering.")
    ctx.finish()
  end
end)

events.on(defines.events.on_object_destroyed, function(ev)
  if S and ev.useful_id and S.units[ev.useful_id] then
    S.units[ev.useful_id] = nil
    S.stats.killed = S.stats.killed + 1
  end
end)

core.register("s01_units", {
  issue = 1, auto = false, desc = "unit colonists: scale, scheduled work, biter aggro",
  usage = "[N=100] [seconds=60] [biters=0]",
  run = function(ctx)
    local n, secs, biters = tonumber(ctx.args[1]) or 100, tonumber(ctx.args[2]) or 60, tonumber(ctx.args[3]) or 0
    local trees = ctx.surface.count_entities_filtered{position = ctx.position, radius = SEARCH_RADIUS, type = "tree"}
    ctx.check("trees nearby for test", trees > 50, trees .. " trees in radius")
    S = {units = {}, claimed = {}, sched = {}, stats = {done = 0, path_fail = 0, no_tree = 0, killed = 0, spawned = 0},
         rng = game.create_random_generator(1), acc = core.mkprof(), ticks = 0, ctx = ctx, biters = biters,
         end_tick = game.tick + secs * 60}
    S.acc.stop()
    for _ = 1, n do
      local pos = ctx.surface.find_non_colliding_position("colony-colonist", ctx.position, 20, 0.5)
      if pos then
        local e = ctx.surface.create_entity{name = "colony-colonist", position = pos, force = "player"}
        if e then
          S.units[e.unit_number] = {entity = e}
          script.register_on_object_destroyed(e)
          S.stats.spawned = S.stats.spawned + 1
          assign(e.unit_number)
        end
      end
    end
    ctx.check("spawned requested colonists", S.stats.spawned == n, S.stats.spawned .. "/" .. n)
    ctx.probe("entity.commandable exists", function() return next(S.units) and S.units[next(S.units)].entity.commandable ~= nil end)
    for _ = 1, biters do
      local b = ctx.surface.create_entity{name = "small-biter", force = "enemy",
        position = {ctx.position.x + 30, ctx.position.y + math.random(-5, 5)}}
      if b then b.commandable.set_command{type = defines.command.attack_area, destination = ctx.position,
        radius = 40, distraction = defines.distraction.by_enemy} end
    end
    ctx.log("running for " .. secs .. "s ...")
  end,
})
