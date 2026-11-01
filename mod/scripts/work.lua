-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: haul (hall -> house needs), forage (open ground near hall, nothing consumed), chop (tree destroyed -> wood), mine (ore -1 per trip).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work_plan = require("scripts.model.work_plan")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.WORK_TICKS = 480
M.RETRY_TICKS = 300
M.YIELD = {forage = {item = "colony-forage", count = 4}, chop = {item = "wood", count = 4}, mine = {count = 3}}
M.CARRY_CAP = 20
M.ORES = {"iron-ore", "copper-ore", "coal", "stone"}
M.LABELS = {forage = "forager", chop = "woodcutter", mine = "miner", haul = "hauler"}

local function key(e) return e.surface.index .. ":" .. e.position.x .. "," .. e.position.y end

local function job_counts(colony)
  local counts = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.job then counts[st.job] = (counts[st.job] or 0) + 1 end
  end
  return counts
end

-- Floating job label above each colonist (makes the colony legible).
local function set_label(e, text)
  local obj = storage.unit_labels[e.unit_number]
  if obj and obj.valid then obj.text = text; return end
  storage.unit_labels[e.unit_number] = rendering.draw_text{text = text, surface = e.surface, target = {entity = e, offset = {0, -1.4}},
    color = {1, 1, 1}, scale = 0.7, alignment = "center", only_in_alt_mode = true}
end

local function popup(surface, pos, text)
  rendering.draw_text{text = text, surface = surface, target = pos, color = {0.8, 1, 0.8},
    scale = 0.8, time_to_live = 90, alignment = "center"}
end

-- Labour buildings -------------------------------------------------------------------------------
local function hut_list(colony)
  local ids = {}
  for un, h in pairs(colony.huts) do if h.entity.valid then ids[#ids + 1] = un else colony.huts[un] = nil end end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.huts[un] end
  return out
end

local function worker_count(h)
  local n = 0
  for _ in pairs(h.workers) do n = n + 1 end
  return n
end

function M.hut_info(h)
  local def = labour.HUTS[h.entity.name]
  local tools = h.entity.get_item_count(def.tool)
  return def, tools, labour.allowed(def.capacity, tools), worker_count(h)
end

local function free_slots(colony)
  local list = {}
  for _, h in ipairs(hut_list(colony)) do
    local _, _, allowed, workers = M.hut_info(h)
    list[#list + 1] = {job = h.job, allowed = allowed, workers = workers, hut = h}
  end
  return labour.free_slots(list), list
end

local function find_site(colony, e, hut)
  local job = hut.job
  colony.rng = colony.rng or game.create_random_generator(colony.id * 7919)
  if job == "forage" then
    for _, p in ipairs(hut.patches) do
      if p.valid and not colony.claimed[key(p)] then return p end
    end
    return nil
  end
  local filter = {position = hut.entity.position, radius = colony_mod.HUT_RADIUS}
  if job == "mine" then filter.type = "resource"; filter.name = M.ORES else filter.type = "tree" end
  local list = e.surface.find_entities_filtered(filter)
  if #list == 0 then return nil end
  for _ = 1, 8 do
    local t = list[colony.rng(1, #list)]
    if job == "mine" or not colony.claimed[key(t)] then return t end
  end
  return nil
end

local function go(e, pos, radius)
  e.commandable.set_command{type = defines.command.go_to_location, destination = pos,
    radius = radius, distraction = defines.distraction.none}
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
  for _, h in ipairs(hut_list(colony)) do
    local def, tools = M.hut_info(h)
    local want = def.capacity - tools - (h.inflight[def.tool] or 0)
    if want >= 1 then
      local t, item, n = try_target(colony, h, {{item = def.tool, count = want}})
      if t then return t, item, n end
    end
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

local function start_trip(colony, un, hut)
  local e = colony.colonists[un]
  local site = find_site(colony, e, hut)
  if not site then
    hut.workers[un] = nil
    colony.no_site[hut.job] = game.tick + 600
    return false
  end
  if hut.job ~= "mine" then colony.claimed[key(site)] = true end
  storage.unit_state[un] = {colony_id = colony.id, job = hut.job, hut = hut, state = "to_site", site = site}
  set_label(e, M.LABELS[hut.job])
  go(e, site.position, 1.5)
  return true
end

local function idle(colony, un, e)
  storage.unit_state[un] = {colony_id = colony.id, state = "idle"}
  set_label(e, "idle")
  scheduler.after(M.RETRY_TICKS, "work.retry", {un = un})
end

function M.assign(colony, un)
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local st = storage.unit_state[un]
  -- keep an existing labour post while the hut stands and still has tools for us
  if st and st.hut then
    local h = st.hut
    if h.entity.valid and h.workers[un] then
      local _, _, allowed, workers = M.hut_info(h)
      if workers <= allowed and start_trip(colony, un, h) then return end
    end
    h.workers[un] = nil
  end
  local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
  local counts = job_counts(colony)
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local slots, slot_list = free_slots(colony)
  local disabled = {}
  for _, j in ipairs({"forage", "chop", "mine"}) do
    if (slots[j] or 0) <= 0 or (colony.no_site[j] or 0) > game.tick then disabled[j] = true end
  end
  local house, haul_item, haul_n = find_haul_task(colony)
  local collect_m, collect_item, collect_n, collect_q
  if not house then
    collect_m, collect_item, collect_n, collect_q = find_collect_task(colony)
    if not collect_m then disabled.haul = true end
  end
  local job = work_plan.choose(colony_mod.total_food(colony) / target, counts, disabled)
  if not job then idle(colony, un, e); return end
  if job == "haul" then
    if collect_m then
      local removed = collect_m.entity.remove_item{name = collect_item, count = collect_n, quality = collect_q}
      storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "to_hall", carry = {item = collect_item, count = removed}}
      set_label(e, "hauler"); go(e, colony.hall.position, 3)
    else
      colony.hall.remove_item{name = haul_item, count = haul_n}
      house.inflight[haul_item] = (house.inflight[haul_item] or 0) + haul_n
      storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "to_house", house = house,
        carry = {item = haul_item, count = haul_n}}
      set_label(e, "hauler"); go(e, house.entity.position, 2.5)
    end
    return
  end
  for _, sl in ipairs(slot_list) do
    if sl.job == job and sl.allowed > sl.workers then
      sl.hut.workers[un] = true
      if start_trip(colony, un, sl.hut) then return end
      break
    end
  end
  idle(colony, un, e)
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
    if st.hut and st.hut.entity and st.hut.entity.valid then
      local hut = st.hut
      local def = labour.HUTS[hut.entity.name]
      if def then
        local broke
        hut.wear, broke = labour.wear(hut.wear or 0)
        if broke then
          hut.entity.remove_item{name = def.tool, count = 1}
          popup(hut.entity.surface, hut.entity.position, "Tool broke!")
        end
      end
    end
    if st.job == "chop" then
      colony.claimed[key(site)] = nil; site.destroy()
      st.carry = M.YIELD.chop
    elseif st.job == "forage" then
      colony.claimed[key(site)] = nil; site.destroy()
      st.carry = M.YIELD.forage
    elseif st.job == "mine" then
      st.carry = {item = site.name, count = M.YIELD.mine.count}
      site.amount = site.amount - 1
      if site.amount <= 0 then site.destroy() end
    end
  end
  if not st.carry then
    if st.hut and st.hut.workers then st.hut.workers[d.un] = nil end
    M.assign(colony, d.un)
    return
  end
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
  if st then
    if st.hut and st.hut.workers then st.hut.workers[un] = nil end
    M.release(st)
    storage.unit_state[un] = nil
  end
  if un and storage.unit_labels and storage.unit_labels[un] then
    local lbl = storage.unit_labels[un]
    if lbl and lbl.valid then lbl.destroy() end
    storage.unit_labels[un] = nil
  end
end)

return M
