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
local farm = require("scripts.model.farm")
local mine_plan = require("scripts.model.mine_plan")
local crates = require("scripts.model.crates")
local compost = require("scripts.model.compost")
local construct = require("scripts.model.construct")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.WORK_TICKS = 480
M.RETRY_TICKS = 300
M.YIELD = {forage = {item = "colony-forage", count = 4}, chop = {item = "wood", count = 4}}
M.MINE_PER_TRIP = 5         -- resource units mined per trip; each unit becomes exactly one item (design §4.2)
M.MINE_POLLUTION = 2        -- pollution per mining trip: colony industry still feeds the biters
M.CARRY_CAP = 20
M.ORES = mine_plan.ORES   -- every ore a Miner's Hut can be pointed at
M.LABELS = {forage = "forager", chop = "woodcutter", mine = "miner", farm = "farmer", haul = "hauler",
  construct = "builder"}

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
  if item and prototypes.item[item] then return {"item-name." .. item} end
  return item or "?"
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

-- Machine index (#75) ------------------------------------------------------------------------------
-- find_haul_task used to walk every opted-in machine on every assignment and read its output inventory.
-- At 2000 machines that was ~3.9 of the ~5 ms/tick the #39 benchmark measured, and nearly all of it was
-- spent asking machines that had nothing to give. Machines are now swept in slices on a timer and the
-- sweep records `has_output`; assignment only visits machines with a request or with output.
M.MACHINE_SWEEP_TICKS = 30
M.MACHINE_SWEEP_SHARE = 10   -- 1/N of the registry per sweep, so each machine is checked every 300 ticks
M.MACHINE_OFFERS_PER_ASSIGN = 16   -- machines considered per trip; the cursor rotates through all of them

-- Sorted unit numbers plus the two working sets, rebuilt only when the registry changes (or a sweep
-- flips has_output). Everything downstream iterates the cached arrays, so the cost is per change rather
-- than per assignment. Returned tables are read-only for callers.
local function machine_ids(colony)
  if colony.machine_ids_cache and not colony.machine_dirty then return colony.machine_ids_cache end
  local ids = {}
  for un, m in pairs(colony.machines) do
    if m.entity.valid then ids[#ids + 1] = un else colony.machines[un] = nil end
  end
  table.sort(ids)
  local demand, output, damaged = {}, {}, {}
  for _, un in ipairs(ids) do
    local m = colony.machines[un]
    if m.enabled then
      if m.need and #m.need > 0 then demand[#demand + 1] = m end   -- refreshed by the sweep
      if m.has_output then output[#output + 1] = m end
      if m.damaged then damaged[#damaged + 1] = m end
    end
  end
  colony.machine_ids_cache, colony.machine_demand, colony.machine_output = ids, demand, output
  colony.machine_damaged = damaged
  colony.machine_dirty = false
  return ids
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

-- Construction (#37) ------------------------------------------------------------------------------
-- Ghosts and damage are not event-delivered (a player blueprint does not fire on_built_entity), so on a
-- timer each colony re-scans its own claimed area once and keeps a small registry. Assignment then reads
-- the registry instead of scanning the surface per trip.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function construct_open(colony)
  local ghosts, repairs = 0, 0
  for _, k in ipairs(sorted_keys(colony.ghosts or {})) do
    local g = colony.ghosts[k]
    if g.valid then
      if not colony.claimed[k] then ghosts = ghosts + 1 end
    else colony.ghosts[k] = nil end
  end
  for _, k in ipairs(sorted_keys(colony.repairs or {})) do
    local t = colony.repairs[k]
    if t.valid and construct.needs_repair(t.health, t.max_health) then
      if not colony.claimed[k] then repairs = repairs + 1 end
    else colony.repairs[k] = nil end
  end
  return ghosts + repairs
end

local function colony_area(colony)
  local cols = storage.colony_chunks[colony.surface_index] or {}
  local minx, miny, maxx, maxy
  for cx, col in pairs(cols) do
    for cy, owner in pairs(col) do
      if owner == colony.id then
        minx = math.min(minx or cx, cx); maxx = math.max(maxx or cx, cx)
        miny = math.min(miny or cy, cy); maxy = math.max(maxy or cy, cy)
      end
    end
  end
  if not minx then return nil end
  return {{minx * 32, miny * 32}, {(maxx + 1) * 32, (maxy + 1) * 32}}
end

-- Damaged things the colony owns. Bounded: it reads its own registries, never the whole surface.
local function repair_candidates(colony)
  local out = {}
  local function add(e)
    if e and e.valid and construct.needs_repair(e.health, e.max_health) then out[#out + 1] = e end
  end
  add(colony.hall)
  for _, h in ipairs(colony_mod.house_list(colony)) do add(h.entity) end
  for _, h in ipairs(hut_list(colony)) do add(h.entity) end
  machine_ids(colony)   -- refreshes machine_damaged if the registry changed
  for _, m in ipairs(colony.machine_damaged or {}) do add(m.entity) end
  for _, c in ipairs(colony_mod.crate_list(colony)) do add(c.entity) end
  for _, t in pairs(colony.towers or {}) do add(t) end
  for _, p in pairs(colony.plots or {}) do add(p.entity) end
  return out
end

local function construct_scan(colony)
  colony.ghosts, colony.repairs = {}, {}
  local hall = colony.hall
  local area = colony_area(colony)
  if not (hall and hall.valid and area) then return 0, 0 end
  local ghosts = 0
  for _, g in ipairs(hall.surface.find_entities_filtered{type = "entity-ghost", area = area, force = hall.force}) do
    if g.valid and #construct.cost(g.ghost_prototype.items_to_place_this) > 0
      and territory.owner_at(colony.surface_index, g.position) == colony.id then
      colony.ghosts[key(g)] = g
      ghosts = ghosts + 1
    end
  end
  local repairs = 0
  for _, e in ipairs(repair_candidates(colony)) do
    colony.repairs[key(e)] = e
    repairs = repairs + 1
  end
  return ghosts, repairs
end

scheduler.register("construct.scan", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  construct_scan(colony)
  scheduler.after(construct.SCAN_TICKS, "construct.scan", {colony_id = colony.id})
end)

local function job_slots(colony)
  local list = {}
  for _, h in ipairs(hut_list(colony)) do
    local _, _, allowed, workers = M.hut_info(h)
    list[#list + 1] = {job = h.job, allowed = allowed, workers = workers, hut = h}
  end
  local slots = labour.free_slots(list)
  local capacity = labour.capacity_by_job(list)
  for _, job in ipairs({"forage", "chop", "mine", "farm"}) do
    if (colony.no_site[job] or 0) > game.tick then slots[job] = 0 end   -- nothing to harvest: don't thrash
  end
  -- Construction has no hut: its slots are the open ghosts/repairs in the registry, minus current builders.
  capacity.construct = construct_open(colony)
  slots.construct = math.max(capacity.construct - (job_counts(colony).construct or 0), 0)
  return slots, capacity, list
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
    -- Ore priority: work the best-ranked ore that is actually in range, so a hut does not walk past iron
    -- to grab the nearest stone. Ores sharing a rank fall back to distance (the old behaviour).
    for _, ore in ipairs(mine_plan.order(hut.ores)) do
      local site = nearest(s.find_entities_filtered{position = base, radius = radius, type = "resource", name = ore}, base, in_territory)
      if site then return site end
    end
    return nil
  elseif hut.job == "farm" then
    -- Ripe plots first (food now), then fallow plots (plant for later); nearest wins, ties by unit_number.
    local best, best_ripe, best_d, r2 = nil, false, nil, radius * radius
    for un, plot in pairs(colony.plots or {}) do
      local pe = plot.entity
      if not pe.valid then
        colony.plots[un] = nil
      elseif (plot.stage == farm.FALLOW or plot.stage == farm.RIPE) and not colony.claimed[key(pe)]
          and in_territory(pe) and dist2(pe.position, base) <= r2 then
        local ripe, d = plot.stage == farm.RIPE, dist2(pe.position, base)
        if not best or (ripe and not best_ripe) or (ripe == best_ripe and
            (d < best_d or (d == best_d and un < best.unit_number))) then
          best, best_ripe, best_d = pe, ripe, d
        end
      end
    end
    return best
  end
end

-- How many harvestable sites the hut can currently see (GUI feedback for "nothing in range").
function M.site_count(h)
  local colony = storage.colonies[h.colony_id]
  if not (colony and h.entity.valid) then return 0 end
  local s, base, radius = h.entity.surface, h.entity.position, colony_mod.HUT_RADIUS
  local in_territory = function(t) return territory.owner_at(colony.surface_index, t.position) == colony.id end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  if h.job == "farm" then
    local n = 0
    for _, plot in pairs(colony.plots or {}) do
      if plot.entity.valid and (plot.stage == farm.FALLOW or plot.stage == farm.RIPE) and free(plot.entity) then n = n + 1 end
    end
    return n
  end
  if h.job == "mine" then
    local n = 0
    for _, ore in ipairs(mine_plan.order(h.ores)) do
      for _, e in ipairs(s.find_entities_filtered{position = base, radius = radius, type = "resource", name = ore}) do
        if e.valid and free(e) then n = n + 1 end
      end
    end
    return n
  end
  local list
  if h.job == "forage" then list = s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}
  else list = s.find_entities_filtered{position = base, radius = radius, type = "tree"} end
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

-- Finished goods sit in the hut until a hauler clears them, so the hut is the local stockpile and the
-- colonist never walks every load home. Everything except the hut's own tool is fair game.
local function hut_collect_offer(h)
  local def = labour.HUTS[h.entity.name]
  local inv = h.entity.get_inventory(defines.inventory.chest)
  if not (def and inv and not inv.is_empty()) then return nil end
  local demands, available = {}, {}
  for _, c in ipairs(inv.get_contents()) do
    if c.name ~= def.tool then
      demands[#demands + 1] = {item = c.name, count = c.count}
      available[c.name] = c.count
    end
  end
  if #demands == 0 then return nil end
  return {kind = "collect", hut = h, priority = haul_plan.PRIORITY.hut_output, key = h.entity.unit_number,
    demands = demands, available = available}
end

-- Crates (#33): a supply crate is a provider (empty it into stock), a demand crate is a requester (fill it
-- to the player's filters). A warehouse needs no offer of its own: colony.stock_count/take_stock/put_stock
-- already treat it as colony storage, both as a source and as overflow.
local function crate_contents(c)
  local inv = c.entity.get_inventory(defines.inventory.chest)
  if not (inv and not inv.is_empty()) then return nil end
  local out = {}
  for _, item in ipairs(inv.get_contents()) do out[item.name] = item.count end
  return out
end

-- A bin's finished fertilizer, offered like a supply crate's contents.
local function bin_offer(b)
  local n = b.entity.get_item_count(compost.PRODUCT)
  if n < 1 then return nil end
  return {kind = "collect", bin = b, priority = haul_plan.PRIORITY.collect, key = b.entity.unit_number,
    demands = {{item = compost.PRODUCT, count = n}}, available = {[compost.PRODUCT] = n}}
end

local function crate_supply_offer(c)
  local contents = crate_contents(c)
  if not contents then return nil end
  local demands = crates.supply(contents)
  if #demands == 0 then return nil end
  return {kind = "collect", crate = c, priority = haul_plan.PRIORITY.collect, key = c.entity.unit_number,
    demands = demands, available = contents}
end

local function crate_demand_offer(c)
  local contents = crate_contents(c) or {}
  local demands = crates.demands(c.filters, contents, c.inflight)
  if #demands == 0 then return nil end
  return {kind = "supply", crate = c, priority = haul_plan.PRIORITY.request, key = c.entity.unit_number,
    demands = demands}
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

-- Offers use the need list the sweep cached, so an assignment never touches a machine inventory. In-flight
-- loads are subtracted here because they change between sweeps.
local function machine_offer(m)
  if not m.entity.valid or not m.enabled or (m.blocked_until or 0) > game.tick then return nil end
  local need = m.need
  if not need then return nil end
  local demands, any = {}, false
  for _, d in ipairs(need) do
    local n = d.count - (m.inflight[d.item] or 0)
    if n >= 1 then demands[#demands + 1] = {item = d.item, count = n}; any = true end
  end
  if not any then return nil end
  return {kind = "supply", machine = m, priority = haul_plan.PRIORITY.request, key = m.entity.unit_number, demands = demands}
end

-- Finished products leave the machine now; the load is filled from the machine, not the hall.
local function collect_offer(colony, m)
  if not m.entity.valid or not m.enabled or not m.collect then return nil end
  local inv = m.entity.get_output_inventory()
  if not inv or inv.is_empty() then
    if m.has_output then m.has_output, colony.machine_dirty = false, true end   -- emptied since the sweep
    return nil
  end
  local demands, available = {}, {}
  for _, c in ipairs(inv.get_contents()) do
    demands[#demands + 1] = {item = c.name, count = c.count}
    available[c.name] = (available[c.name] or 0) + c.count
  end
  return {kind = "collect", machine = m, priority = haul_plan.PRIORITY.collect, key = m.entity.unit_number,
    demands = demands, available = available}
end

-- Slice sweep (#75): the only place that touches machine inventories when nobody is asking for a haul.
-- Each machine is visited every MACHINE_SWEEP_TICKS * MACHINE_SWEEP_SHARE ticks; the sweep records what
-- it saw (has_output, need) and assignment reads those flags. A machine's own request therefore lags by
-- at most one sweep, which is invisible next to the time a colonist spends walking.
scheduler.register("work.machine_sweep", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  local ids = machine_ids(colony)
  local n = #ids
  if n > 0 then
    local step = math.max(1, math.ceil(n / M.MACHINE_SWEEP_SHARE))
    local cursor = colony.machine_cursor or 1
    local changed = false
    for i = 0, step - 1 do
      local m = colony.machines[ids[(cursor - 1 + i) % n + 1]]
      if m and m.entity.valid then
        local has, need = false, nil
        if m.enabled then
          if m.collect then
            local inv = m.entity.get_output_inventory()
            has = inv ~= nil and not inv.is_empty()
          end
          if next(m.requests or {}) then
            need = machine_demands(m)
            if #need == 0 then need = nil end
          end
        end
        if has ~= (m.has_output or false) then m.has_output, changed = has, true end
        -- Health is read here too: construct.scan used to read it for every machine every 300 ticks,
        -- which was a 13 ms tick at 2000 machines (#75).
        local hurt = m.entity.health < m.entity.max_health
        if hurt ~= (m.damaged or false) then m.damaged, changed = hurt, true end
        if need and not m.need then m.need, changed = need, true
        elseif not need and m.need then m.need, changed = nil, true
        else m.need = need end
      end
    end
    colony.machine_cursor = (cursor - 1 + step) % n + 1
    if changed then colony.machine_dirty = true end
  end
  scheduler.after(M.MACHINE_SWEEP_TICKS, "work.machine_sweep", d)
end)

-- One destination per trip, possibly several item types. Returns an offer with `.load` filled in.
local function find_haul_task(colony)
  local offers = {}
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local o = house_offer(colony, h); if o then offers[#offers + 1] = o end
  end
  for _, h in ipairs(hut_list(colony)) do
    local o = hut_offer(h); if o then offers[#offers + 1] = o end
    local c = hut_collect_offer(h); if c then offers[#offers + 1] = c end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.SUPPLY)) do
    local o = crate_supply_offer(c); if o then offers[#offers + 1] = o end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.DEMAND)) do
    local o = crate_demand_offer(c); if o then offers[#offers + 1] = o end
  end
  -- Compost (#78): carry the bin's fertilizer out to colony stock, and carry stock spoilage in to it.
  local bins = colony_mod.bin_list(colony)
  for _, b in ipairs(bins) do
    local o = bin_offer(b); if o then offers[#offers + 1] = o end
  end
  if #bins > 0 then
    local spoil = colony_mod.stock_count(colony, compost.SOURCE)
    if spoil > 0 then
      local bin = bins[1]
      offers[#offers + 1] = {kind = "compost", bin = bin, priority = haul_plan.PRIORITY.compost,
        key = bin.entity.unit_number, demands = {{item = compost.SOURCE, count = spoil}},
        available = {[compost.SOURCE] = spoil}}
    end
  end
  machine_ids(colony)   -- refresh the working sets if the registry changed
  -- A big town has thousands of machines wanting the same ore; building an offer for every one of them on
  -- every trip is what made the demand case 17 ms/tick in the #39 benchmark. Take a bounded slice instead:
  -- any machine wanting an item we hold is a valid destination, and the cursor means every machine is still
  -- looked at regularly (2000 machines / 16 per trip is a full pass every ~120 assignments).
  local demand = colony.machine_demand or {}
  local n = #demand
  if n > 0 then
    local take = math.min(n, M.MACHINE_OFFERS_PER_ASSIGN)
    local cursor = colony.machine_offer_cursor or 1
    for i = 0, take - 1 do
      local o = machine_offer(demand[(cursor - 1 + i) % n + 1])
      if o then offers[#offers + 1] = o end
    end
    colony.machine_offer_cursor = (cursor - 1 + take) % n + 1
  end
  local output = colony.machine_output or {}
  local no, ocursor = #output, colony.collect_offer_cursor or 1
  if no > 0 then
    local take = math.min(no, M.MACHINE_OFFERS_PER_ASSIGN)
    for i = 0, take - 1 do
      local c = collect_offer(colony, output[(ocursor - 1 + i) % no + 1])
      if c then offers[#offers + 1] = c end
    end
    colony.collect_offer_cursor = (ocursor - 1 + take) % no + 1
  end
  if #offers == 0 then return nil end
  haul_plan.order(offers)
  local hall = colony_mod.stock_table(colony)
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
    if offer.kind == "collect" then
      local src = offer.machine and offer.machine.entity or (offer.hut and offer.hut.entity)
        or (offer.crate and offer.crate.entity) or offer.bin.entity
      n = src.remove_item{name = s.item, count = s.count}
    else
      n = colony_mod.take_stock(colony, s.item, s.count)
    end
    if n and n > 0 then taken[#taken + 1] = {item = s.item, count = n} end
  end
  if #taken == 0 then return nil end
  if offer.kind == "supply" then
    local target = offer.house or offer.machine or offer.hut or offer.crate
    for _, s in ipairs(taken) do target.inflight[s.item] = (target.inflight[s.item] or 0) + s.count end
    return taken, target
  end
  return taken, nil
end

local function return_to_hall(colony, stacks)
  local hall = colony.hall
  if not (hall and hall.valid) then return end
  for _, s in ipairs(stacks) do
    local n = colony_mod.put_stock(colony, s.item, s.count)   -- hall first, then warehouses
    if n < s.count then
      hall.surface.spill_item_stack{position = hall.position, stack = {name = s.item, count = s.count - n}, allow_belts = false}
    end
  end
end

-- Trip start / finish ----------------------------------------------------------------------------
local function stock_map(colony, cost)
  local m = {}
  for _, s in ipairs(cost) do m[s.item] = colony_mod.stock_count(colony, s.item) end
  return m
end

-- Nearest open construction job: repairs first (keep what is already built), then ghosts the colony can pay for.
local function find_construct_site(colony, pos)
  local best, best_d, best_kind, best_cost
  for _, k in ipairs(sorted_keys(colony.repairs or {})) do
    local t = colony.repairs[k]
    if t.valid then
      if not colony.claimed[k] and construct.needs_repair(t.health, t.max_health)
        and colony_mod.stock_count(colony, construct.REPAIR_PACK) > 0 then
        local d = dist2(t.position, pos)
        if not best_d or d < best_d then best, best_d, best_kind = t, d, "repair" end
      end
    else colony.repairs[k] = nil end
  end
  if best then return {kind = best_kind, target = best, key = key(best)} end
  for _, k in ipairs(sorted_keys(colony.ghosts or {})) do
    local g = colony.ghosts[k]
    if g.valid then
      if not colony.claimed[k] and (colony.ghost_blocked[k] or 0) <= game.tick then
        local cost = construct.cost(g.ghost_prototype.items_to_place_this)
        if #cost > 0 and construct.affordable(cost, stock_map(colony, cost)) then
          local d = dist2(g.position, pos)
          if not best_d or d < best_d then best, best_d, best_kind, best_cost = g, d, "build", cost end
        end
      end
    else colony.ghosts[k] = nil end
  end
  if not best then return nil end
  return {kind = "build", target = best, key = key(best), cost = best_cost}
end

-- Pay for the job up front (like a hauler taking a load), then walk there and work. Paying first means a
-- ghost is never half-built by two colonists who both counted the same stock.
local function start_construct(colony, un, e)
  local site = find_construct_site(colony, e.position)
  if not site then return false end
  local carry, got = {}, 0
  if site.kind == "build" then
    for _, s in ipairs(site.cost) do
      local n = colony_mod.take_stock(colony, s.item, s.count)
      if n < s.count then                      -- someone else bought it first: put ours back and wait
        if n > 0 then colony_mod.put_stock(colony, s.item, n) end
        if #carry > 0 and colony.hall.valid then return_to_hall(colony, carry) end
        return false
      end
      carry[#carry + 1] = {item = s.item, count = n}
      got = got + n
    end
  else
    local n = colony_mod.take_stock(colony, construct.REPAIR_PACK, 1)
    if n < 1 then return false end
    carry[1] = {item = construct.REPAIR_PACK, count = n}
    got = n
  end
  if got <= 0 then return false end
  colony.claimed[site.key] = true
  storage.unit_state[un] = {colony_id = colony.id, job = "construct", state = "to_construct",
    kind = site.kind, site = site.target, site_key = site.key, carry = carry}
  set_label(e, M.LABELS.construct)
  go(e, site.target.position, 2)
  return true
end

local function start_trip(colony, un, hut)
  local e = colony.colonists[un]
  local site = find_site(colony, e, hut)
  if not site then
    hut.workers[un] = nil
    colony.no_site[hut.job] = game.tick + 600
    return false
  end
  if hut.job ~= "mine" then colony.claimed[key(site)] = true end   -- resources are shared, trees/patches/plots are not
  storage.unit_state[un] = {colony_id = colony.id, job = hut.job, hut = hut, state = "to_site", site = site,
    site_key = key(site)}
  set_label(e, M.LABELS[hut.job])
  go(e, site, 1.5)
  return true
end

local function idle(colony, un, e)
  storage.unit_state[un] = {colony_id = colony.id, state = "idle"}
  set_label(e, "idle")
  -- Deterministic jitter by unit number: a town spawned in one tick would otherwise retry in lockstep.
  scheduler.after(M.RETRY_TICKS + (un * 37) % 240, "work.retry", {un = un})
end

-- Start a haul trip if there is one; returns true when the colonist is on its way.
local function start_haul(colony, un, e, task)
  if not task then return false end
  local taken, inflight_target = take_load(colony, task)
  if not taken then return false end
  local dest, state = nil, "to_house"
  if task.kind == "collect" then dest, state = colony.hall.position, "to_hall"
  elseif task.kind == "compost" then dest, state = task.bin.entity.position, "to_bin"
  elseif task.house then dest = task.house.entity.position
  elseif task.machine then dest = task.machine.entity.position
  elseif task.crate then dest = task.crate.entity.position
  else dest = task.hut.entity.position end
  storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = state, bin = task.bin,
    target = inflight_target or (task.kind == "collect" and task.machine or nil), inflight_target = inflight_target,
    carry = taken}
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
  if job == "construct" then
    if start_construct(colony, un, e) then return end
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
  if colony and st.site_key and (st.job == "chop" or st.job == "forage" or st.job == "farm" or st.job == "construct") then
    colony.claimed[st.site_key] = nil
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

-- Crops ripen on a scheduled event per planted plot (no per-tick scanning).
scheduler.register("farm.ripen", function(d)
  local colony = storage.colonies[d.colony_id]
  local plot = colony and colony.plots and colony.plots[d.un]
  if not (plot and plot.entity.valid) then return end
  if plot.stage ~= farm.GROWING then return end
  plot.stage, plot.ripe_at = farm.RIPE, nil
  plot.entity.graphics_variation = farm.RIPE
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
  elseif st.job == "farm" then
    colony.claimed[k] = nil
    local plot = colony.plots and colony.plots[site.unit_number]
    if plot and plot.entity.valid then
      if plot.stage == farm.RIPE then
        n = farm.yield_for(farm.fertility(site.surface.get_tile(site.position).name))
        item = "colony-produce"
        plot.stage, plot.ripe_at = farm.FALLOW, nil
        site.graphics_variation = farm.FALLOW
      elseif plot.stage == farm.FALLOW then
        plot.stage, plot.ripe_at = farm.GROWING, game.tick + farm.GROW_TICKS
        site.graphics_variation = farm.GROWING
        scheduler.after(farm.GROW_TICKS, "farm.ripen", {colony_id = colony.id, un = site.unit_number})
      end
    end
  elseif st.job == "mine" then
    n = math.min(M.MINE_PER_TRIP, site.amount or 0)
    if n > 0 then
      if site.amount > n then site.amount = site.amount - n else site.destroy() end   -- 0 is not a legal amount
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
  -- Yield goes into the hut that employed the colonist: the hut is the forward stockpile, and a hauler
  -- carries it inward (hut_collect_offer) instead of every worker walking each load to the Town Hall.
  st.carry = {{item = item, count = n}}
  st.state = "to_hut"
  go(e, hut.entity.position, 3)
end)

-- A `unit` standing inside a ghost blocks `revive` outright (the engine will not place an entity where a
-- character stands). `go(..., 2)` can leave the builder on its own site, and an idle colonist never steps off
-- by itself, so a blocked site used to be retried forever with the builder standing on it.
local function unit_blocking(site)
  local box = site.bounding_box
  local r = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y) / 2 + 1
  for _, o in ipairs(site.surface.find_entities_filtered{position = site.position, radius = r, type = "unit"}) do
    if o.valid then return o end
  end
end

-- A walkable point just outside the ghost's footprint, on the side the colonist already stands, so it steps
-- off rather than across the site.
local function aside_from(site, from)
  local box = site.bounding_box
  local r = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y) / 2 + 2.5
  local dx, dy = from.x - site.position.x, from.y - site.position.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.1 then dx, dy, len = 1, 0, 1 end
  return {x = site.position.x + dx / len * r, y = site.position.y + dy / len * r}
end

scheduler.register("construct.finish", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.job == "construct") then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists[d.un]
  if not (colony and e and e.valid) then return end
  if st.site_key then colony.claimed[st.site_key] = nil end
  local site = st.site
  if st.kind == "build" then
    -- `revive` consumes the ghost, so capture what we need for the message first.
    local pos = site and site.valid and {x = site.position.x, y = site.position.y}
    local ghost_name = site and site.valid and site.ghost_name
    -- `revive` returns (items it collided with, the new entity, the item request proxy): the entity is the
    -- second value, so take it explicitly rather than testing the item list for truthiness. `raise_revive`
    -- also re-delivers the ghost's blueprint tags to `on_built`, which is how a revived opt-in machine is
    -- registered again (#36).
    local built = site and site.valid and site.type == "entity-ghost" and select(2, site.revive{raise_revive = true})
    if built then
      st.carry = nil                            -- the ghost consumed the materials
      if colony.ghosts then colony.ghosts[st.site_key] = nil end
      popup(e.surface, pos or e.position, {"", "Built ", item_name(ghost_name)})
    else
      -- The builder is the blocker: step it off the footprint and come back, instead of backing off for an
      -- hour and leaving the ghost standing. Any other blocker (tree, biter, someone else's building) earns
      -- the long back-off, because nothing about it changes just by waiting a few ticks.
      local blocker = site and site.valid and unit_blocking(site)
      if blocker and blocker.unit_number == d.un then
        colony.claimed[st.site_key] = true       -- the site is still ours, just not reachable yet
        st.state = "to_construct"                -- arriving again re-arms the work timer and retries
        go(e, aside_from(site, e.position), 0.5)
        return
      end
      if st.carry then return_to_hall(colony, st.carry) end
      st.carry = nil
      colony.ghost_blocked = colony.ghost_blocked or {}
      colony.ghost_blocked[st.site_key] = game.tick + construct.RETRY_TICKS   -- blocked site: back off
    end
  else
    local packs = 0
    for _, s in ipairs(st.carry or {}) do if s.item == construct.REPAIR_PACK then packs = packs + s.count end end
    st.carry = nil
    if site and site.valid and packs > 0 then
      local health, used = construct.repaired(site.health, site.max_health)
      site.health = health
      if used then
        packs = packs - 1
        popup(e.surface, site.position, {"", "Repaired ", item_name(site.name)})
      end
    end
    if packs > 0 then return_to_hall(colony, {{item = construct.REPAIR_PACK, count = packs}}) end
  end
  M.assign(colony, d.un)
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
  if st.state == "to_construct" then
    st.state = st.kind == "build" and "building" or "repairing"
    local e = colony.colonists[ev.unit_number]
    if e and e.valid and st.site and st.site.valid then work_ring(e, st.site.position) end
    scheduler.after(construct.WORK_TICKS, "construct.finish", {un = ev.unit_number})
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
        -- A machine just got items: its cached need list is stale, so drop it until the next sweep re-reads
        -- the inventory. Without this the colony would re-request the same load every trip.
        if st.inflight_target.requests then
          st.inflight_target.need, colony.machine_dirty = nil, true
        end
      end
      if #refused > 0 then return_to_hall(colony, refused) end
      if inserted == 0 then target.blocked_until = game.tick + 600 end   -- machine refuses these items: stop retrying for a while
      st.carry = nil
      -- Spoilage (#78): a house that fills up with garbage cannot take food, and this colonist is already
      -- standing here, so clearing it costs a trip nobody had to plan.
      local e = colony.colonists[ev.unit_number]
      local bin = e and e.valid and colony_mod.nearest_bin(colony, target.entity.position)
      local spoil = bin and target.entity.remove_item{name = compost.SOURCE, count = M.CARRY_CAP}
      if spoil and spoil > 0 then
        st.carry, st.state, st.bin = {{item = compost.SOURCE, count = spoil}}, "to_bin", bin
        go(e, bin.entity.position, 3)
        return
      end
    else M.release(st) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_bin" then
    local e = colony.colonists[ev.unit_number]
    local bin, carry = st.bin, st.carry
    st.bin, st.carry = nil, nil
    local leftover, dropped = {}, 0
    if bin and bin.entity.valid then
      for _, s in ipairs(carry or {}) do
        local n = bin.entity.insert{name = s.item, count = s.count}
        dropped = dropped + n
        if n < s.count then leftover[#leftover + 1] = {item = s.item, count = s.count - n} end
      end
    else leftover = carry or {} end
    -- A bin full or gone is not a reason to lose the load; the hall is a poor home for spoilage but the bin
    -- can be rebuilt, and the next delivery clears it out again.
    if #leftover > 0 then return_to_hall(colony, leftover) end
    if dropped > 0 and e and e.valid then popup(e.surface, e.position, {"", "Composted ", tostring(dropped)}) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_site" then
    st.state = "working"
    local e = colony.colonists[ev.unit_number]
    if e and e.valid and st.site.valid then work_ring(e, st.site.position) end
    scheduler.after(M.WORK_TICKS + (ev.unit_number * 23) % 240, "work.finish", {un = ev.unit_number})
  elseif st.state == "to_hut" then
    local e = colony.colonists[ev.unit_number]
    local hut_entity = st.hut and st.hut.entity
    local refused = {}
    if hut_entity and hut_entity.valid and st.carry then
      for _, s in ipairs(st.carry) do
        local n = hut_entity.insert{name = s.item, count = s.count}
        if n < s.count then refused[#refused + 1] = {item = s.item, count = s.count - n} end
      end
    else
      refused = st.carry or {}
    end
    st.carry = nil
    if #refused > 0 then
      if e and e.valid and colony.hall.valid then
        st.carry, st.state = refused, "to_hall"     -- hut full or gone: fall back to the Town Hall
        go(e, colony.hall.position, 3)
        return
      end
      if e and e.valid then
        for _, s in ipairs(refused) do
          e.surface.spill_item_stack{position = e.position, stack = {name = s.item, count = s.count}, allow_belts = false}
        end
      end
    end
    M.assign(colony, ev.unit_number)
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
