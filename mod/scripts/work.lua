-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: forage (trees = foraging spots, not consumed), chop (tree destroyed -> wood), mine (ore -1 per trip).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work_plan = require("scripts.model.work_plan")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.SEARCH_RADIUS = 48
M.WORK_TICKS = 240
M.RETRY_TICKS = 180
M.YIELD = {forage = {item = "colony-forage", count = 3}, chop = {item = "wood", count = 4}, mine = {count = 3}}
M.ORES = {"iron-ore", "copper-ore", "coal", "stone"}

local function key(e) return e.surface.index .. ":" .. e.position.x .. "," .. e.position.y end

local function job_counts(colony)
  local counts = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.job then counts[st.job] = (counts[st.job] or 0) + 1 end
  end
  return counts
end

local function find_site(colony, e, job)
  local filter
  if job == "mine" then filter = {position = colony.hall.position, radius = M.SEARCH_RADIUS, type = "resource", name = M.ORES}
  else filter = {position = colony.hall.position, radius = M.SEARCH_RADIUS, type = "tree"} end
  local list = e.surface.find_entities_filtered(filter)
  if #list == 0 then return nil end
  colony.rng = colony.rng or game.create_random_generator(colony.id * 7919)
  for _ = 1, 8 do
    local t = list[colony.rng(1, #list)]
    if job == "chop" or job == "mine" then
      if not colony.claimed[key(t)] or job == "mine" then return t end
    else return t end
  end
  return nil
end

local function go(e, pos, radius)
  e.commandable.set_command{type = defines.command.go_to_location, destination = pos,
    radius = radius, distraction = defines.distraction.none}
end

function M.assign(colony, un)
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
  local counts = job_counts(colony)
  local st = storage.unit_state[un]
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local disabled = colony.no_site or {}
  local job = work_plan.choose(colony_mod.food_in(colony) / target, counts, disabled)
  local site = job and find_site(colony, e, job)
  if not site then
    if job then colony.no_site = colony.no_site or {}; colony.no_site[job] = game.tick + 600 end
    storage.unit_state[un] = {colony_id = colony.id, state = "idle"}
    scheduler.after(M.RETRY_TICKS, "work.retry", {un = un})
    return
  end
  local ore
  if job == "mine" then ore = site.name end
  if job == "chop" then colony.claimed[key(site)] = true end
  storage.unit_state[un] = {colony_id = colony.id, job = job, state = "to_site", site = site, ore = ore}
  go(e, site.position, 1.5)
end

function M.release(st)
  if st and st.job == "chop" and st.site and st.site.valid then
    local colony = storage.colonies[st.colony_id]
    if colony then colony.claimed[key(st.site)] = nil end
  end
end

scheduler.register("work.retry", function(d)
  local st = storage.unit_state[d.un]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony then
    -- expire no_site blacklist entries
    for j, until_tick in pairs(colony.no_site or {}) do if until_tick <= game.tick then colony.no_site[j] = nil end end
    M.assign(colony, d.un)
  end
end)

scheduler.register("work.finish", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.state == "working") then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists[d.un]
  if not (e and e.valid and colony.hall.valid) then return end
  local site = st.site
  if site and site.valid then
    if st.job == "chop" then
      colony.claimed[key(site)] = nil; site.destroy()
      st.carry = M.YIELD.chop
    elseif st.job == "forage" then
      st.carry = M.YIELD.forage
    elseif st.job == "mine" then
      st.carry = {item = site.name, count = M.YIELD.mine.count}
      site.amount = site.amount - 1
      if site.amount <= 0 then site.destroy() end
    end
  end
  if not st.carry then M.assign(colony, d.un); return end   -- site vanished
  st.state = "to_hall"
  go(e, colony.hall.position, 3)
end)

events.on(defines.events.on_ai_command_completed, function(ev)
  local st = storage.unit_state[ev.unit_number]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  if ev.result ~= defines.behavior_result.success then
    M.release(st)
    M.assign(colony, ev.unit_number)
    return
  end
  if st.state == "to_site" then
    st.state = "working"
    scheduler.after(M.WORK_TICKS, "work.finish", {un = ev.unit_number})
  elseif st.state == "to_hall" then
    local hall = colony.hall
    if hall.valid and st.carry then
      local inserted = hall.insert{name = st.carry.item, count = st.carry.count}
      if inserted < st.carry.count then
        hall.surface.spill_item_stack{position = hall.position, stack = {name = st.carry.item, count = st.carry.count - inserted}}
      end
    end
    st.carry = nil
    M.assign(colony, ev.unit_number)
  end
end)

events.on(defines.events.on_object_destroyed, function(ev)
  local un = ev.useful_id
  local st = un and storage.unit_state[un]
  if st then M.release(st); storage.unit_state[un] = nil end
end)

return M
