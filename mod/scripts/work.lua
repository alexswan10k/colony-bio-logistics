-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: haul (hall -> houses / tooled huts / opted-in machines, machine output -> hall),
--       forage (natural forage patches in territory), chop (tree destroyed -> wood), mine (ore depleted 1:1).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local work_plan = require("scripts.model.work_plan")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local haul_plan = require("scripts.model.haul_plan")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.WORK_TICKS = 480
M.RETRY_TICKS = 300
M.YIELD = {forage = {item = "colony-forage", count = 4}, chop = {item = "wood", count = 4}}
M.MINE_PER_TRIP = 5         -- resource units mined per trip; each unit becomes exactly one item (design §4.2)
M.MINE_POLLUTION = 2        -- pollution per mining trip: colony industry still feeds the biters
M.CARRY_CAP = 20
M.ORES = {"iron-ore", "copper-ore", "coal", "stone"}
M.LABELS = {forage = "forager", chop = "woodcutter", mine = "miner", haul = "hauler"}

local function key(e) return e.surface.index .. ":" .. e.position.x .. "," .. e.position.y end

function M.job_counts(colony)
  local counts = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.job then counts[st.job] = (counts[st.job] or 0) + 1 end
  end
  return counts
end
local job_counts = M.job_counts

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

-- A ring that lives exactly as long as the work: you can see WHICH tree/patch/ore tile is being worked.
local function work_ring(e, pos)
  rendering.draw_circle{surface = e.surface, target = pos, radius = 0.9, color = {1, 0.85, 0.3, 0.8},
    width = 2, filled = false, time_to_live = M.WORK_TICKS}
end

local function item_name(item)
  if prototypes.item[item] then return {"item-name." .. item} end
  return item
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

local function machine_list(colony)
  local ids = {}
  for un, m in pairs(colony.machines) do
    if m.entity.valid then ids[#ids + 1] = un else colony.machines[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.machines[un] end
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
  return def, tools, labour.allowed(def.capacity, tools, h.limit), worker_count(h)
end

local function job_slots(colony)
  local list = {}
  for _, h in ipairs(hut_list(colony)) do
    local _, _, allowed, workers = M.hut_info(h)
    list[#list + 1] = {job = h.job, allowed = allowed, workers = workers, hut = h}
  end
  local slots = labour.free_slots(list)
  for _, job in ipairs({"forage", "chop", "mine"}) do
    if (colony.no_site[job] or 0) > game.tick then slots[job] = 0 end   -- nothing to harvest: don't thrash
  end
  return slots, labour.capacity_by_job(list), list
end

-- Sites ------------------------------------------------------------------------------------------
local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- Nearest valid candidate, ties broken by unit_number so the choice is deterministic.
local function nearest(list, pos, accept)
  local best, best_d
  for _, e in ipairs(list) do
    if e.valid and (not accept or accept(e)) then
      local d = dist2(e.position, pos)
      if not best_d or d < best_d or (d == best_d and (e.unit_number or 0) < (best.unit_number or 0)) then best, best_d = e, d end
    end
  end
  return best
end

-- Harvest only inside colony territory (design §2.1) and prefer the nearest site, so colonists visibly
-- work the forest / berry patch / ore next to their hut instead of teleporting to a random tree 30 tiles away.
local function find_site(colony, e, hut)
  local s, base, radius = e.surface, hut.entity.position, colony_mod.HUT_RADIUS
  local in_territory = function(t) return territory.owner_at(colony.surface_index, t.position) == colony.id end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  if hut.job == "forage" then
    return nearest(s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}, base, free)
  elseif hut.job == "chop" then
    return nearest(s.find_entities_filtered{position = base, radius = radius, type = "tree"}, base, free)
  elseif hut.job == "mine" then
    return nearest(s.find_entities_filtered{position = base, radius = radius, type = "resource", name = M.ORES}, base, in_territory)
  end
end

-- How many harvestable sites the hut can currently see (GUI feedback for "nothing in range").
function M.site_count(h)
  local colony = storage.colonies[h.colony_id]
  if not (colony and h.entity.valid) then return 0 end
  local s, base, radius = h.entity.surface, h.entity.position, colony_mod.HUT_RADIUS
  local in_territory = function(t) return territory.owner_at(colony.surface_index, t.position) == colony.id end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  local list
  if h.job == "forage" then list = s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}
  elseif h.job == "chop" then list = s.find_entities_filtered{position = base, radius = radius, type = "tree"}
  else list = s.find_entities_filtered{position = base, radius = radius, type = "resource", name = M.ORES} end
  local n = 0
  for _, e in ipairs(list) do if e.valid and free(e) then n = n + 1 end end
  return n
end

local function go(e, dest, radius)
  local cmd = {type = defines.command.go_to_location, radius = radius, distraction = defines.distraction.none}
  if type(dest) == "table" and dest.x then cmd.destination = dest else cmd.destination_entity = dest end
  e.commandable.set_command(cmd)
end

-- Haul planning ----------------------------------------------------------------------------------
-- House demand: critical (already unmet / never evaluated) beats buffering a well-stocked house.
local function house_offer(colony, h)
  local tier = housing.TIERS[h.kind]
  local occupants = h.occupants or 0
  local stock = colony_mod.house_stock(h)
  local demands = housing.demand(tier, stock, h.inflight, colony_mod.is_powered(h), occupants)
  if #demands == 0 then return nil end
  local critical = false
  for _, need in ipairs(tier.needs) do
    if need.critical then
      local ok = h.sat and h.sat[need.id]
      if ok == false or (ok == nil and occupants > 0) then critical = true end
    end
  end
  return {kind = "supply", house = h, priority = critical and haul_plan.PRIORITY.critical or haul_plan.PRIORITY.buffer,
    key = h.entity.unit_number, demands = demands}
end

local function hut_offer(h)
  local def, tools = M.hut_info(h)
  local want = math.min(def.capacity, h.limit or def.capacity) - tools - (h.inflight[def.tool] or 0)
  if want < 1 then return nil end
  return {kind = "supply", hut = h, priority = haul_plan.PRIORITY.tools, key = h.entity.unit_number,
    demands = {{item = def.tool, count = want}}}
end

local function machine_demands(m)
  local out = {}
  for _, req in pairs(m.requests or {}) do
    local want = req.count - m.entity.get_item_count(req.item) - (m.inflight[req.item] or 0)
    if want >= 1 then out[#out + 1] = {item = req.item, count = want} end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

local function machine_offer(m)
  if not m.enabled or (m.blocked_until or 0) > game.tick then return nil end
  local demands = machine_demands(m)
  if #demands == 0 then return nil end
  return {kind = "supply", machine = m, priority = haul_plan.PRIORITY.request, key = m.entity.unit_number, demands = demands}
end

-- Finished products leave the machine now; the load is filled from the machine, not the hall.
local function collect_offer(m)
  if not m.enabled or not m.collect then return nil end
  local inv = m.entity.get_output_inventory()
  if not inv or inv.is_empty() then return nil end
  local demands, available = {}, {}
  for _, c in ipairs(inv.get_contents()) do
    demands[#demands + 1] = {item = c.name, count = c.count}
    available[c.name] = (available[c.name] or 0) + c.count
  end
  return {kind = "collect", machine = m, priority = haul_plan.PRIORITY.collect, key = m.entity.unit_number,
    demands = demands, available = available}
end

-- One destination per trip, possibly several item types. Returns an offer with `.load` filled in.
local function find_haul_task(colony)
  local offers = {}
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local o = house_offer(colony, h); if o then offers[#offers + 1] = o end
  end
  for _, h in ipairs(hut_list(colony)) do
    local o = hut_offer(h); if o then offers[#offers + 1] = o end
  end
  for _, m in ipairs(machine_list(colony)) do
    local o = machine_offer(m); if o then offers[#offers + 1] = o end
    local c = collect_offer(m); if c then offers[#offers + 1] = c end
  end
  if #offers == 0 then return nil end
  haul_plan.order(offers)
  local hall = {}
  for _, o in ipairs(offers) do
    for _, d in ipairs(o.demands) do
      for _, item in ipairs(haul_plan.demand_items(d)) do
        if hall[item] == nil then hall[item] = colony.hall.get_item_count(item) end
      end
    end
  end
  local offer, load = haul_plan.choose(offers, hall, M.CARRY_CAP)
  if not offer then return nil end
  offer.load = load
  return offer
end

-- Take the load out of its source. The returned stacks hold the amounts that really left, so a
-- partially filled request can never duplicate items.
local function take_load(colony, offer)
  local taken = {}
  for _, s in ipairs(offer.load) do
    local n
    if offer.kind == "collect" then n = offer.machine.entity.remove_item{name = s.item, count = s.count}
    else n = colony.hall.remove_item{name = s.item, count = s.count} end
    if n and n > 0 then taken[#taken + 1] = {item = s.item, count = n} end
  end
  if #taken == 0 then return nil end
  if offer.kind == "supply" then
    local target = offer.house or offer.machine or offer.hut
    for _, s in ipairs(taken) do target.inflight[s.item] = (target.inflight[s.item] or 0) + s.count end
    return taken, target
  end
  return taken, nil
end

local function return_to_hall(colony, stacks)
  local hall = colony.hall
  for _, s in ipairs(stacks) do
    if not (hall and hall.valid) then return end
    local n = hall.insert{name = s.item, count = s.count}
    if n < s.count then
      hall.surface.spill_item_stack{position = hall.position, stack = {name = s.item, count = s.count - n}, allow_belts = false}
    end
  end
end

-- Trip start / finish ----------------------------------------------------------------------------
local function start_trip(colony, un, hut)
  local e = colony.colonists[un]
  local site = find_site(colony, e, hut)
  if not site then
    hut.workers[un] = nil
    colony.no_site[hut.job] = game.tick + 600
    return false
  end
  if hut.job ~= "mine" then colony.claimed[key(site)] = true end   -- resources are shared, trees/patches are not
  storage.unit_state[un] = {colony_id = colony.id, job = hut.job, hut = hut, state = "to_site", site = site}
  set_label(e, M.LABELS[hut.job])
  go(e, site, 1.5)
  return true
end

local function idle(colony, un, e)
  storage.unit_state[un] = {colony_id = colony.id, state = "idle"}
  set_label(e, "idle")
  scheduler.after(M.RETRY_TICKS, "work.retry", {un = un})
end

-- Start a haul trip if there is one; returns true when the colonist is on its way.
local function start_haul(colony, un, e, task)
  if not task then return false end
  local taken, inflight_target = take_load(colony, task)
  if not taken then return false end
  local dest
  if task.kind == "collect" then dest = colony.hall.position
  elseif task.house then dest = task.house.entity.position
  elseif task.machine then dest = task.machine.entity.position
  else dest = task.hut.entity.position end
  storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = task.kind == "collect" and "to_hall" or "to_house",
    target = inflight_target or (task.kind == "collect" and task.machine or nil), inflight_target = inflight_target, carry = taken}
  set_label(e, "hauler")
  go(e, dest, 3)
  return true
end

function M.assign(colony, un)
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local st = storage.unit_state[un]
  local lock = colony.locks and colony.locks[un]
  -- keep an existing labour post while the hut stands, still has tools for us and matches the player's lock
  if st and st.hut then
    local h = st.hut
    if h.entity.valid and h.workers[un] and (not lock or lock == h.job) then
      local _, _, allowed, workers = M.hut_info(h)
      if workers <= allowed and start_trip(colony, un, h) then return end
    end
    h.workers[un] = nil
  end
  local counts = job_counts(colony)
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local slots, capacity, slot_list = job_slots(colony)
  local task = find_haul_task(colony)
  -- Player lock (#38): this colonist works only the chosen role, even when the matrix would send it elsewhere.
  local job
  if lock then
    job = lock
  else
    local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
    job = work_plan.choose{food_ratio = colony_mod.total_food(colony) / target, counts = counts,
      slots = slots, capacity = capacity, pop = math.max(colony_mod.live_colonists(colony) - 1, 0), haul = task ~= nil,
      priority = colony.priority}
  end
  if not job then idle(colony, un, e); return end
  if job == "haul" then
    if start_haul(colony, un, e, task) then return end
    idle(colony, un, e); return
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

-- Aborted trip: release reservations, claims and carried goods.
function M.release(st)
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if st.site and st.site.valid and (st.job == "chop" or st.job == "forage") and colony then
    colony.claimed[key(st.site)] = nil
  end
  if st.carry and colony then
    if st.inflight_target and st.inflight_target.inflight then
      for _, s in ipairs(st.carry) do
        st.inflight_target.inflight[s.item] = math.max((st.inflight_target.inflight[s.item] or 0) - s.count, 0)
      end
    end
    return_to_hall(colony, st.carry)
    st.carry = nil
  end
end

scheduler.register("work.retry", function(d)
  local st = storage.unit_state[d.un]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony then M.assign(colony, d.un) end
end)

scheduler.register("work.finish", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.state == "working") then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists[d.un]
  if not (e and e.valid and colony.hall.valid) then return end
  local hut, site = st.hut, st.site
  if not (hut and hut.entity.valid and site and site.valid) then
    -- tree cut by the player, ore exhausted or hut removed while we were working: no yield, retry
    if hut and hut.workers then hut.workers[d.un] = nil end
    M.release(st)
    M.assign(colony, d.un)
    return
  end
  -- one completed trip = one use of the hut's tool
  local def = labour.HUTS[hut.entity.name]
  if def then
    local broke
    hut.wear, broke = labour.wear(hut.wear or 0)
    if broke and hut.entity.remove_item{name = def.tool, count = 1} > 0 then
      popup(hut.entity.surface, hut.entity.position, {"", "Tool broke: ", item_name(def.tool)})
    end
  end
  local pos, k, item, n = site.position, key(site), site.name, 0
  if st.job == "chop" then
    colony.claimed[k] = nil; site.destroy()
    item, n = M.YIELD.chop.item, M.YIELD.chop.count
  elseif st.job == "forage" then
    colony.claimed[k] = nil; site.destroy()
    item, n = M.YIELD.forage.item, M.YIELD.forage.count
    colony_mod.on_forage_harvested(colony, pos)     -- the patch grows back in place, later
  elseif st.job == "mine" then
    n = math.min(M.MINE_PER_TRIP, site.amount or 0)
    if n > 0 then
      site.amount = site.amount - n
      if site.amount <= 0 then site.destroy() end
      e.surface.pollute(pos, M.MINE_POLLUTION)       -- 1:1 depletion, zero electricity, but not zero pollution
    end
  end
  if n <= 0 then
    if hut.workers then hut.workers[d.un] = nil end
    M.release(st)
    M.assign(colony, d.un)
    return
  end
  popup(e.surface, pos, {"", "+" .. n .. " ", item_name(item)})
  st.carry = {{item = item, count = n}}
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
    local target = st.target
    if target and target.entity.valid and st.carry then
      local inserted, refused = 0, {}
      for _, s in ipairs(st.carry) do
        local n = target.entity.insert{name = s.item, count = s.count}
        inserted = inserted + n
        if n < s.count then refused[#refused + 1] = {item = s.item, count = s.count - n} end
      end
      if st.inflight_target and st.inflight_target.inflight then
        for _, s in ipairs(st.carry) do
          st.inflight_target.inflight[s.item] = math.max((st.inflight_target.inflight[s.item] or 0) - s.count, 0)
        end
      end
      if #refused > 0 then return_to_hall(colony, refused) end
      if inserted == 0 then target.blocked_until = game.tick + 600 end   -- machine refuses these items: stop retrying for a while
      st.carry = nil
    else M.release(st) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_site" then
    st.state = "working"
    local e = colony.colonists[ev.unit_number]
    if e and e.valid and st.site.valid then work_ring(e, st.site.position) end
    scheduler.after(M.WORK_TICKS, "work.finish", {un = ev.unit_number})
  elseif st.state == "to_hall" then
    if st.carry then return_to_hall(colony, st.carry) end
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
