-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: haul (hall -> house needs), forage (trees = foraging spots, not consumed), chop (tree destroyed -> wood), mine (ore -1 per trip).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work_plan = require("scripts.model.work_plan")
local housing = require("scripts.model.housing")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.SEARCH_RADIUS = 48
M.WORK_TICKS = 240
M.RETRY_TICKS = 180
M.YIELD = {forage = {item = "colony-forage", count = 3}, chop = {item = "wood", count = 4}, mine = {count = 3}}
M.CARRY_CAP = 20
M.TOOL_USES = 25
M.TOOLS = {chop = {key = "axe", item = "colony-axe"}, mine = {key = "pick", item = "colony-pickaxe"}}
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

-- Tools: per-colonist wear counters; replacements come from the Town Hall or any Tool Rack.
local function tool_sources(colony)
  local list = {colony.hall}
  local ids = {}
  for un, r in pairs(colony.racks) do if r.valid then ids[#ids + 1] = un else colony.racks[un] = nil end end
  table.sort(ids)
  for _, un in ipairs(ids) do list[#list + 1] = colony.racks[un] end
  return list
end

local function tool_available(colony, un, job)
  local t = M.TOOLS[job]
  if not t then return true end
  local u = storage.unit_tools[un]
  if u and (u[t.key] or 0) > 0 then return true end
  for _, src in ipairs(tool_sources(colony)) do
    if src.get_item_count(t.item) > 0 then return true end
  end
  return false
end

local function take_tool(colony, un, job)
  local t = M.TOOLS[job]
  if not t then return end
  local u = storage.unit_tools[un] or {}
  storage.unit_tools[un] = u
  if (u[t.key] or 0) > 0 then return end
  for _, src in ipairs(tool_sources(colony)) do
    if src.remove_item{name = t.item, count = 1} > 0 then u[t.key] = M.TOOL_USES; return end
  end
end

local function wear_tool(un, job)
  local t = M.TOOLS[job]
  local u = t and storage.unit_tools[un]
  if u then u[t.key] = math.max((u[t.key] or 0) - 1, 0) end
end

-- Haul targets: houses (need-driven) and opted-in machines (player requests). Items leave the hall now (inflight-reserved).
local function try_target(colony, target, demands)
  local hall = colony.hall
  for _, d in ipairs(demands) do
    local items = {d.item}
    if d.need == "food" then items = {}; for _, o in ipairs(housing.FOOD) do items[#items + 1] = o.item end end
    for _, item in ipairs(items) do
      local have = hall.get_item_count(item)
      if have > 0 then return target, item, math.min(d.count, have, M.CARRY_CAP) end
    end
  end
end

local function machine_demands(m)
  local out = {}
  for _, req in pairs(m.requests) do
    local want = req.count - m.entity.get_item_count(req.item) - (m.inflight[req.item] or 0)
    if want >= 1 then out[#out + 1] = {item = req.item, count = want} end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

local function find_haul_task(colony)
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local stock = colony_mod.house_stock(h)
    local t, item, n = try_target(colony, h, housing.demand(housing.TIERS[h.kind], stock, h.inflight, colony_mod.is_powered(h)))
    if t then return t, item, n end
  end
  local ids = {}
  for un, m in pairs(colony.machines) do
    if m.entity.valid then if m.enabled then ids[#ids + 1] = un end else colony.machines[un] = nil end
  end
  table.sort(ids)
  for _, un in ipairs(ids) do
    local m = colony.machines[un]
    if (m.blocked_until or 0) <= game.tick then
      local t, item, n = try_target(colony, m, machine_demands(m))
      if t then return t, item, n end
    end
  end
end

-- Collect: first opted-in machine with finished product; items leave the machine now and walk to the hall.
local function find_collect_task(colony)
  local ids = {}
  for un, m in pairs(colony.machines) do
    if m.entity.valid and m.enabled and m.collect then ids[#ids + 1] = un end
  end
  table.sort(ids)
  for _, un in ipairs(ids) do
    local inv = colony.machines[un].entity.get_output_inventory()
    if inv and not inv.is_empty() then
      local contents = inv.get_contents()
      local c = contents[1]
      if c then return colony.machines[un], c.name, math.min(c.count, M.CARRY_CAP), c.quality end
    end
  end
end

function M.assign(colony, un)
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
  local counts = job_counts(colony)
  local st = storage.unit_state[un]
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local disabled = {}
  for j, until_tick in pairs(colony.no_site) do if until_tick > game.tick then disabled[j] = true end end
  for job in pairs(M.TOOLS) do if not tool_available(colony, un, job) then disabled[job] = true end end
  local house, haul_item, haul_n = find_haul_task(colony)
  local collect_m, collect_item, collect_n, collect_q
  if not house then
    collect_m, collect_item, collect_n, collect_q = find_collect_task(colony)
    if not collect_m then disabled.haul = true end
  end
  local job = work_plan.choose(colony_mod.total_food(colony) / target, counts, disabled)
  if job == "haul" and collect_m then
    local removed = collect_m.entity.remove_item{name = collect_item, count = collect_n, quality = collect_q}
    storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "to_hall", carry = {item = collect_item, count = removed}}
    go(e, colony.hall.position, 3)
    return
  end
  if job == "haul" then
    colony.hall.remove_item{name = haul_item, count = haul_n}
    house.inflight[haul_item] = (house.inflight[haul_item] or 0) + haul_n
    storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "to_house", house = house,
      carry = {item = haul_item, count = haul_n}}
    go(e, house.entity.position, 2.5)
    return
  end
  if job then take_tool(colony, un, job) end
  local site = job and find_site(colony, e, job)
  if not site then
    if job then colony.no_site[job] = game.tick + 600 end
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
  if st and st.job == "haul" and st.carry then
    -- trip aborted: release reservation and return goods to the hall
    if st.house then st.house.inflight[st.carry.item] = math.max((st.house.inflight[st.carry.item] or 0) - st.carry.count, 0) end
    local colony = storage.colonies[st.colony_id]
    if colony and colony.hall.valid then colony.hall.insert{name = st.carry.item, count = st.carry.count} end
    st.carry = nil
  elseif st and st.job == "chop" and st.site and st.site.valid then
    local colony = storage.colonies[st.colony_id]
    if colony then colony.claimed[key(st.site)] = nil end
  end
end

scheduler.register("work.retry", function(d)
  local st = storage.unit_state[d.un]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony then
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
    wear_tool(d.un, st.job)
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
  if st.state == "to_house" then
    local h = st.house
    if h and h.entity.valid and st.carry then
      local inserted = h.entity.insert{name = st.carry.item, count = st.carry.count}
      h.inflight[st.carry.item] = math.max((h.inflight[st.carry.item] or 0) - st.carry.count, 0)
      if inserted < st.carry.count then colony.hall.insert{name = st.carry.item, count = st.carry.count - inserted} end
      if inserted == 0 then h.blocked_until = game.tick + 600 end   -- machine refuses this item: stop retrying for a while
      st.carry = nil
    else M.release(st) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_site" then
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
  if un then storage.unit_tools[un] = nil end
end)

return M
