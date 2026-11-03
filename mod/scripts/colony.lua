-- Colony adapter (#24 #25 #28 #29): Town Hall claims territory, housing is territory-restricted,
-- periodic evaluation (scheduler, not per-tick) computes desirability and spawns migrants.
-- Rules live in scripts.model.*; this file only talks to the engine.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local farm = require("scripts.model.farm")
local crates = require("scripts.model.crates")
local construct = require("scripts.model.construct")
local desirability = require("scripts.model.desirability")
local colony_model = require("scripts.model.colony_model")
local scenic = require("scripts.model.scenic")
local compost = require("scripts.model.compost")
local wildlife = require("scripts.wildlife")
local fishing = require("scripts.model.fishing")
local salt = require("scripts.model.salt")
local well = require("scripts.model.well")
local recreation = require("scripts.model.recreation")
local yields = require("scripts.model.yields")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local tags = require("scripts.model.tags")
local ledger = require("scripts.model.ledger")
local quota = require("scripts.model.quota")
local headcount = require("scripts.model.headcount")
local milestones = require("scripts.model.milestones")
local workshop = require("scripts.model.workshop")
local work = require("scripts.work")
local gui = require("scripts.gui")
local feedback = require("scripts.feedback")
local transit = require("scripts.transit")
local mortality = require("scripts.mortality")
local shelter = require("scripts.shelter")
local commute = require("scripts.commute")
local mortality_model = require("scripts.model.mortality")
local M = {}

M.HALL = "colony-town-hall"
M.WATCHTOWER = "colony-watchtower"
M.PLOT = "colony-farm-plot"
M.WELL = "colony-well"
M.MOTOR_POOL = "colony-motor-pool"
M.TAVERN = "colony-tavern"
M.PLATFORM = "colony-passenger-platform"
M.CEMETERY = "colony-cemetery"
M.CANTEEN = "colony-canteen"
M.MEAL_ITEMS = commute.FOOD_ITEMS     -- what a Canteen serves (#50): the foods houses eat
M.HUT_RADIUS = 48              -- working radius around a labour hut (other colonies' land excluded)
M.REGROW_TICKS = 2400           -- a harvested forage patch grows back in place after this long...
M.REGROW_JITTER = 1800          -- ...plus up to this much, so a grove does not regrow in lockstep
M.FORAGE_PER_CHUNK = 3          -- natural forage patches seeded per already-generated territory chunk
M.FORAGE_TILES = {["grass-1"] = true, ["grass-2"] = true, ["grass-3"] = true, ["grass-4"] = true}
M.HOUSES = {["colony-housing-tent"] = "tent", ["colony-housing-cabin"] = "cabin",
  ["colony-housing-homestead"] = "homestead", ["colony-housing-apartment"] = "apartment"}
-- Colony logistics crates (#33): supply = provider, demand = requester, warehouse = bulk colony stock.
M.SUPPLY_CRATE = "colony-supply-crate"
M.DEMAND_CRATE = "colony-demand-crate"
M.WAREHOUSE = "colony-warehouse"
M.CRATES = {
  [M.SUPPLY_CRATE] = crates.SUPPLY,
  [M.DEMAND_CRATE] = crates.DEMAND,
  [M.WAREHOUSE] = crates.WAREHOUSE,
}
-- Compost Bin (#78, design §3.2): spoilage is removed from houses and stock by colonists and converted here.
M.COMPOST_BIN = "colony-compost-bin"
M.SALT_PAN = "colony-salt-pan"
M.COMPOST_TICKS = 600           -- conversion pass cadence; a bin is a building, not a per-tick machine
M.STARVE_AFTER = 4              -- consecutive evaluations with unmet critical need before a colonist dies
M.SCENIC_RADIUS = 40            -- tiles around the hall that scenic reads (fixed: cost must not grow with the town)
M.SCENIC_STRIDE = 4             -- tile sample stride: 1/16 of the area is actually read
M.SCENIC_EVERY = 4              -- evaluations between scenic samples (surroundings change slowly)
M.POP_TTL = 5                   -- ticks a cached population count / food total / stock snapshot may be reused
M.FOOD_TTL = 30
M.STOCK_TTL = 30
M.HOUSE_STOCK_TTL = 20          -- ticks a house's stock snapshot may be reused by the haul planner (#22)
M.POWERED_ENERGY = 10000        -- J in the hidden sink buffer that counts as 'powered'
M.FOOD_PER_COLONIST = yields.FOOD_PER_INTERVAL   -- food items per interval
M.FOOD_ITEMS = {"colony-forage", "colony-fish", "colony-meat", "colony-produce", "raw-fish",
  "colony-preserved-meat", "colony-preserved-fish", "colony-bread", "yumako", "jellynut", "bioflux", "yumako-mash", "jelly"}
M.INTERVAL = 600                -- default ticks between evaluations
M.TARGET_STOCK_INTERVALS = 5

-- Ticks between evaluations (food use, migration, starvation). Runtime-global setting; tests may set storage.interval_override.
function M.interval()
  return storage.interval_override or (settings.global["colony-interval-seconds"] and settings.global["colony-interval-seconds"].value * 60) or M.INTERVAL
end

local function name_of(e) return e.type == "entity-ghost" and e.ghost_name or e.name end

local function refund(ev, e, name, message)
  local player = ev.player_index and game.get_player(ev.player_index)
  if player then
    player.insert{name = name, count = 1, quality = e.quality}
    player.create_local_flying_text{text = message or {"colony-message.outside-territory"}, position = e.position}
  else
    e.surface.spill_item_stack{position = e.position, stack = {name = name, count = 1}}
  end
end

-- Fishing Dock (#80): a dock without water beside it is not a dock. Checked once, when it is built, and the
-- rule itself lives in model/fishing.lua; this is just the tile probe (any tile that collides with the water
-- layer counts, so ponds on any planet count and lava does not).
local function on_shore(e)
  local surface = e.surface
  return fishing.on_shore(e.position, function(x, y)
    local tile = surface.get_tile(x, y)
    return tile and tile.collides_with("water_tile")
  end)
end

-- Salt pans (#81), in a stable order: [unit_number] = {entity, colony_id, next_at}.
function M.salt_pan_list(colony)
  local ids = {}
  for un, p in pairs(colony.salt_pans or {}) do
    if p.entity.valid then ids[#ids + 1] = un else colony.salt_pans[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.salt_pans[un] end
  return out
end

-- Passenger Platforms (#49), in a stable order: [unit_number] = {entity, colony_id, stop (cached train stop)}.
function M.platform_list(colony)
  local ids = {}
  for un, p in pairs(colony.platforms or {}) do
    if p.entity.valid then ids[#ids + 1] = un else colony.platforms[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.platforms[un] end
  return out
end

-- Taverns (#48), in a stable order: [unit_number] = {entity, colony_id, inflight, owed, houses, inspired}.
function M.tavern_list(colony)
  local ids = {}
  for un, t in pairs(colony.taverns or {}) do
    if t.entity.valid then ids[#ids + 1] = un else colony.taverns[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.taverns[un] end
  return out
end

-- Canteens (#50), in a stable order: [unit_number] = {entity, colony_id, inflight}.
function M.canteen_list(colony)
  local ids = {}
  for un, c in pairs(colony.canteens or {}) do
    if c.entity.valid then ids[#ids + 1] = un else colony.canteens[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.canteens[un] end
  return out
end

-- Cemeteries (#53), in a stable order: [unit_number] = {entity, colony_id, graves}.
function M.cemetery_list(colony)
  local ids = {}
  for un, c in pairs(colony.cemeteries or {}) do
    if c.entity.valid then ids[#ids + 1] = un else colony.cemeteries[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.cemeteries[un] end
  return out
end

-- Motor Pools (#60), in a stable order: [unit_number] = {entity, colony_id, inflight, out}.
function M.pool_list(colony)
  local ids = {}
  for un, p in pairs(colony.pools or {}) do
    if p.entity.valid then ids[#ids + 1] = un else colony.pools[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.pools[un] end
  return out
end

-- Wells (#43), in a stable order: [unit_number] = {entity, colony_id, next_at}.
function M.well_list(colony)
  local ids = {}
  for un, w in pairs(colony.wells or {}) do
    if w.entity.valid then ids[#ids + 1] = un else colony.wells[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.wells[un] end
  return out
end

function M.food_in(colony)
  local hall = colony.hall
  if not (hall and hall.valid) then return 0 end
  local n = 0
  for _, item in ipairs(M.FOOD_ITEMS) do
    if prototypes.item[item] then n = n + hall.get_item_count(item) end
  end
  return n
end

-- Population, food and stock are read on every assignment (the job matrix ratios, the affordable check) but
-- change slowly, so they are cached with a short TTL (#75: recomputing them per assignment was ~0.4 ms/tick
-- at 500 colonists). All three are pure reads; the prune of dead colonists just happens once per TTL.
function M.live_colonists(colony)
  if colony.pop_tick and game.tick - colony.pop_tick < M.POP_TTL then return colony.pop_cache end
  local n = 0
  for id, c in pairs(colony.colonists) do
    if c.valid then n = n + 1 else
      colony.colonists[id] = nil
      if colony.locks then colony.locks[id] = nil end
    end
  end
  colony.pop_cache, colony.pop_tick = n, game.tick
  return n
end

-- Sorted live colonist unit_numbers: the stable order used by rosters and by house assignment.
function M.colonist_ids(colony)
  local ids = {}
  for un, c in pairs(colony.colonists) do
    if c.valid then ids[#ids + 1] = un else
      colony.colonists[un] = nil
      if colony.locks then colony.locks[un] = nil end
    end
  end
  table.sort(ids)
  return ids
end

-- Who lives in which house: [house unit_number] = {colonist unit_number, ...}. Per-colonist job locks are
-- managed on the house panel, so a town with hundreds of colonists never has to list them all in one window.
function M.households(colony)
  local houses = M.house_list(colony)
  local caps = {}
  for i, h in ipairs(houses) do caps[i] = housing.TIERS[h.kind].capacity end
  local split = housing.assign(M.colonist_ids(colony), caps)
  local out = {}
  for i, h in ipairs(houses) do out[h.entity.unit_number] = split[i] or {} end
  return out
end

-- Taverns pour ale for the houses around them (#48, model/recreation.lua): marks each house `inspired` and returns
-- the share of the town that was served. Runs once per colony evaluation.
function M.serve_taverns(colony, houses, occ)
  local taverns = M.tavern_list(colony)
  if #taverns == 0 then
    for _, h in ipairs(houses) do h.inspired = nil end
    return 0
  end
  local tl, hl = {}, {}
  for i, t in ipairs(taverns) do
    tl[i] = {position = t.entity.position, ale = t.entity.get_item_count(recreation.ITEM), owed = t.owed}
  end
  for i, h in ipairs(houses) do hl[i] = {position = h.entity.position, occupants = occ[i] or 0} end
  local served, used, owed, coverage = recreation.serve(tl, hl)
  for i, t in ipairs(taverns) do
    if used[i] > 0 then t.entity.remove_item{name = recreation.ITEM, count = used[i]} end
    t.owed, t.houses, t.inspired = owed[i], 0, 0
  end
  for i, h in ipairs(houses) do
    local ti = served[i]
    h.inspired = ti ~= nil or nil
    if ti then
      taverns[ti].houses = taverns[ti].houses + 1
      taverns[ti].inspired = taverns[ti].inspired + (occ[i] or 0)
    end
  end
  return coverage
end

-- Is this colonist Inspired (+25% work speed)? True when its house was served by a Tavern last evaluation.
function M.is_inspired(colony, un)
  local e = M.house_of_colonist(colony, un)
  local h = e and colony.houses[e.unit_number]
  return h ~= nil and h.inspired == true
end

function M.house_of_colonist(colony, un)
  if not colony then return nil end
  -- Sleeping asks this for every colonist that goes to bed, so the split is cached: `households` sorts the
  -- whole town and re-runs the housing assignment, which is far too much work per colonist (#22).
  local cache = colony.house_index
  if not (cache and colony.house_index_tick and game.tick - colony.house_index_tick < M.POP_TTL) then
    cache = {}
    for house_un, members in pairs(M.households(colony)) do
      local h = colony.houses and colony.houses[house_un]
      if h and h.entity and h.entity.valid then
        for _, member in ipairs(members) do cache[member] = h.entity end
      end
    end
    colony.house_index, colony.house_index_tick = cache, game.tick
  end
  return cache[un] or (colony.hall and colony.hall.valid and colony.hall or nil)
end

-- Crates in deterministic (unit_number) order; prunes dead ones. `kind` filters to one crate type.
function M.crate_list(colony, kind)
  local ids = {}
  for un, c in pairs(colony.crates or {}) do
    if c.entity.valid then
      if not kind or c.kind == kind then ids[#ids + 1] = un end
    else
      colony.crates[un] = nil
    end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.crates[un] end
  return out
end

-- Compost bins in deterministic (unit_number) order; prunes dead ones. Same shape as crate_list.
function M.bin_list(colony)
  local ids = {}
  for un, b in pairs(colony.bins or {}) do
    if b.entity.valid then ids[#ids + 1] = un else colony.bins[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.bins[un] end
  return out
end

-- The bin a colonist would walk to from `pos`: nearest wins, ties by unit_number, so the choice is stable.
function M.nearest_bin(colony, pos)
  local best, best_d
  for _, b in ipairs(M.bin_list(colony)) do
    local e = b.entity
    local dx, dy = e.position.x - pos.x, e.position.y - pos.y
    local d = dx * dx + dy * dy
    if not best_d or d < best_d then best, best_d = b, d end
  end
  return best
end

-- Colony stock (Town Hall + warehouses) as one table: an assignment asks about a dozen items and each
-- question used to rebuild and sort the warehouse list. Supply trips still take from the hall first (the
-- town's working stock) and fall back to bulk storage; deposits fill the hall first and overflow outward.
function M.stock_table(colony)
  if colony.stock_cache and game.tick - (colony.stock_tick or -1e9) < M.STOCK_TTL then return colony.stock_cache end
  local t = {}
  local hall = colony.hall
  if hall and hall.valid then
    local inv = hall.get_inventory(defines.inventory.chest)
    if inv then for _, s in ipairs(inv.get_contents()) do t[s.name] = s.count end end
  end
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do
    local inv = c.entity.get_inventory(defines.inventory.chest)
    if inv then
      for _, s in ipairs(inv.get_contents()) do t[s.name] = (t[s.name] or 0) + s.count end
    end
  end
  colony.stock_cache, colony.stock_tick = t, game.tick
  return t
end

function M.stock_count(colony, item)
  return M.stock_table(colony)[item] or 0
end

-- Colony resource ledger (#82): aggregates Town Hall stock, warehouses, labour huts, salt pans, and
-- in-transit carries by colonists into one inventory view.
M.LEDGER_TTL = 30   -- ticks a cached ledger snapshot is kept while GUI is open

function M.ledger_snapshot(colony)
  if colony.ledger_cache and game.tick - (colony.ledger_tick or -1e9) < M.LEDGER_TTL then
    return colony.ledger_cache
  end
  local stock = {}
  local hall = colony.hall
  if hall and hall.valid then
    local inv = hall.get_inventory(defines.inventory.chest)
    if inv then for _, s in ipairs(inv.get_contents()) do stock[s.name] = (stock[s.name] or 0) + s.count end end
  end
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do
    if c.entity and c.entity.valid then
      local inv = c.entity.get_inventory(defines.inventory.chest)
      if inv then for _, s in ipairs(inv.get_contents()) do stock[s.name] = (stock[s.name] or 0) + s.count end end
    end
  end

  local huts_data = {}
  for _, h in pairs(colony.huts or {}) do
    if h.entity and h.entity.valid then
      local inv = h.entity.get_inventory(defines.inventory.chest)
      if inv then
        local contents = {}
        for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end
        huts_data[#huts_data + 1] = {name = h.entity.name, contents = contents}
      end
    end
  end
  for _, sp in pairs(colony.salt_pans or {}) do
    if sp.entity and sp.entity.valid then
      local inv = sp.entity.get_inventory(defines.inventory.chest)
      if inv then
        local contents = {}
        for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end
        huts_data[#huts_data + 1] = {name = sp.entity.name, contents = contents}
      end
    end
  end
  for _, w in pairs(colony.wells or {}) do
    if w.entity and w.entity.valid then
      local inv = w.entity.get_inventory(defines.inventory.chest)
      if inv then
        local contents = {}
        for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end
        huts_data[#huts_data + 1] = {name = w.entity.name, contents = contents}
      end
    end
  end

  local transit_data = {}
  for un, c in pairs(colony.colonists or {}) do
    if c.valid then
      local st = storage.unit_state and storage.unit_state[un]
      if st and st.carry then
        for _, cr in ipairs(st.carry) do
          if cr.item and cr.count and cr.count > 0 then
            transit_data[#transit_data + 1] = {item = cr.item, count = cr.count}
          end
        end
      end
    end
  end

  local res = ledger.aggregate{
    stock = stock,
    huts = huts_data,
    transit = transit_data,
  }
  colony.ledger_cache, colony.ledger_tick = res, game.tick
  return res
end

-- --- harvest quotas (#84) --------------------------------------------------------------------------------
function M.global_quotas()
  local g = {}
  if settings and settings.global then
    for item in pairs(quota.RESOURCES) do
      local s = settings.global["colony-quota-" .. item]
      if s and s.value and s.value > 0 then g[item] = s.value end
    end
  end
  return g
end

function M.quota_target(colony, item)
  return quota.target(colony.quotas, M.global_quotas(), item)
end

function M.quota_met(colony, item)
  local tgt = M.quota_target(colony, item)
  if tgt <= 0 then return false end
  local led = M.ledger_snapshot(colony)
  local count = led and led.totals and led.totals[item] or 0
  return quota.met(tgt, count)
end

function M.set_quota(colony, item, target)
  colony.quotas = colony.quotas or {}
  colony.quotas[item] = target
  colony.ledger_cache = nil
  for un in pairs(colony.colonists or {}) do
    local st = storage.unit_state and storage.unit_state[un]
    if st and st.state == "idle" then
      work.assign(colony, un)
    end
  end
end

-- --- workforce headcount targets (#73) ---------------------------------------------------------------------
function M.job_target(colony, job)
  return headcount.target(colony.job_targets, job)
end

function M.set_job_target(colony, job, target)
  colony.job_targets = colony.job_targets or {}
  headcount.set_target(colony.job_targets, job, target)
  for un in pairs(colony.colonists or {}) do
    local st = storage.unit_state and storage.unit_state[un]
    if st and st.state == "idle" then
      work.assign(colony, un)
    end
  end
end

function M.shift_job_target(colony, job, delta)
  colony.job_targets = colony.job_targets or {}
  local cur = colony.job_targets[job]
  local current_count = (work.job_counts(colony)[job] or 0)
  local new_val = headcount.shift_target(cur, delta, current_count)
  colony.job_targets[job] = new_val
  M.reassign_workforce(colony)
  return new_val
end

function M.reassign_workforce(colony)
  if not colony then return end
  for un, c in pairs(colony.colonists or {}) do
    local st = storage.unit_state and storage.unit_state[un]
    if c.valid and st and (st.state == "idle" or ((st.state == "sleeping" or st.state == "to_bed") and not work.is_sleep_time(c.surface))) then
      work.assign(colony, un)
    end
  end
end

function M.headcount_capped(colony, job)
  local tgt = M.job_target(colony, job)
  if tgt == nil then return false end
  local counts = work.job_counts(colony)
  return (counts[job] or 0) >= tgt
end

function M.take_stock(colony, item, count)
  colony.stock_cache = nil   -- stock moved: the cached snapshot is stale
  local taken = 0
  local hall = colony.hall
  if hall and hall.valid then taken = hall.remove_item{name = item, count = count} end
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do
    if taken >= count then break end
    taken = taken + c.entity.remove_item{name = item, count = count - taken}
  end
  return taken
end

function M.put_stock(colony, item, count)
  colony.stock_cache = nil   -- stock moved: the cached snapshot is stale
  local left = count
  local hall = colony.hall
  if hall and hall.valid then left = left - hall.insert{name = item, count = left} end
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do
    if left <= 0 then break end
    left = left - c.entity.insert{name = item, count = left}
  end
  return count - left
end

-- Valid houses in deterministic (unit_number) order; prunes dead ones.
function M.house_list(colony)
  local ids = {}
  for un, h in pairs(colony.houses) do
    if h.entity.valid then ids[#ids + 1] = un else
      if h.sink and h.sink.valid then h.sink.destroy() end
      colony.houses[un] = nil
    end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.houses[un] end
  return out
end

function M.capacity(colony)
  local n = 0
  for _, h in ipairs(M.house_list(colony)) do n = n + housing.TIERS[h.kind].capacity end
  return n
end

function M.house_stock(h)
  local inv = h.entity.get_inventory(defines.inventory.chest)
  local stock = {}
  for item in pairs(housing.items_of(housing.TIERS[h.kind])) do stock[item] = inv.get_item_count(item) end
  return stock, inv
end

-- Stock snapshot for the haul planner. A house holds 6-10 item types, so reading every house on every
-- assignment was the town's single biggest Lua cost once a colony had ~80 houses (#22). Deliveries are the
-- only thing that changes it, and a trip takes far longer than the TTL, so a slightly stale snapshot costs
-- nothing; the in-flight load is subtracted fresh by `housing.demand`.
function M.house_stock_cached(h)
  if h.stock_tick and game.tick - h.stock_tick < M.HOUSE_STOCK_TTL then return h.stock end
  local stock = M.house_stock(h)
  h.stock, h.stock_tick = stock, game.tick
  return stock
end

function M.is_powered(h)
  return h.sink ~= nil and h.sink.valid and h.sink.energy >= M.POWERED_ENERGY
end

-- Total food on hand (hall + house buffers); used by work planning and desirability.
function M.total_food(colony)
  if colony.food_tick and game.tick - colony.food_tick < M.FOOD_TTL then return colony.food_total end
  local n = M.food_in(colony)
  for _, h in ipairs(M.house_list(colony)) do
    local stock = M.house_stock(h)
    for _, opt in ipairs(housing.FOOD) do n = n + (stock[opt.item] or 0) end
  end
  -- Warehouses and hut stockpiles count too: food only waits there until a hauler clears it.
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do
    for _, item in ipairs(M.FOOD_ITEMS) do
      if prototypes.item[item] then n = n + c.entity.get_item_count(item) end
    end
  end
  for _, h in pairs(colony.huts or {}) do
    if h.entity.valid then
      for _, item in ipairs(M.FOOD_ITEMS) do
        if prototypes.item[item] then n = n + h.entity.get_item_count(item) end
      end
    end
  end
  colony.food_total, colony.food_tick = n, game.tick
  return n
end

local function gps(e_or_pos, surface)
  local p = e_or_pos.position or e_or_pos
  return string.format("[gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), (surface or e_or_pos.surface).name)
end
M.gps = gps

-- Starvation takes someone who lives in the house that went without, not a stranger across town, and says
-- so: which house, and which need it lacked.
local function kill_one(colony, h, need_id)
  local members = M.households(colony)[h.entity.unit_number] or {}
  for i = #members, 1, -1 do
    local id = members[i]
    local c = colony.colonists[id]
    if c and c.valid then
      -- Struck off before it dies, so mortality's on_entity_died handler does not count it twice.
      colony.colonists[id] = nil
      if colony.locks then colony.locks[id] = nil end
      mortality.record(colony, c.position, c.surface, "starved", true)
      c.die()
      colony.hall.force.print({"colony-message.starved", {"colony-gui.need-" .. need_id},
        {"entity-name." .. h.entity.name}, gps(h.entity)})
      return true
    end
  end
  return false
end

-- A migrant arrives at the Town Hall: right in town, so it can always path to its job (spawning out at the
-- edge stranded colonists behind lakes and cliffs). The arrival is shown over the hall and announced with a
-- map link, so a new face is never a silent surprise.
-- A new colonist at the hall, or at `at` (a Passenger Platform, #49) when it arrived by train.
local function spawn_colonist(colony, at)
  local hall = colony.hall
  local pos = hall.surface.find_non_colliding_position("colony-colonist", at or hall.position, 10, 0.5)
  if not pos then return false end
  local c = hall.surface.create_entity{name = "colony-colonist", position = pos, force = hall.force}
  if not c then return false end
  colony.colonists[c.unit_number] = c
  colony.pop_cache, colony.pop_tick = nil, nil
  script.register_on_object_destroyed(c)
  work.assign(colony, c.unit_number)
  rendering.draw_text{text = {"colony-message.arrival-popup"}, surface = hall.surface,
    target = {entity = c, offset = {0, -2}}, color = {0.8, 1, 0.8}, scale = 0.9, alignment = "center",
    time_to_live = 180}
  return c
end

M.spawn_colonist = spawn_colonist

-- Scenic (#29): count trees in a fixed box around the hall and sample the tiles under them, once every
-- M.SCENIC_EVERY evaluations. Trees are entities, so one filtered find per sample beats per-tile probing;
-- the box is fixed rather than the whole territory so the cost stays flat as watchtowers expand.
local function sample_scenic(colony)
  local hall = colony.hall
  if not (hall and hall.valid) then return end
  local s, p, r = hall.surface, hall.position, M.SCENIC_RADIUS
  local trees = 0
  for _, e in ipairs(s.find_entities_filtered{area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}}, type = "tree"}) do
    if e.valid then trees = trees + 1 end
  end
  local water, built, tiles = 0, 0, 0
  for x = math.floor(p.x - r), math.floor(p.x + r), M.SCENIC_STRIDE do
    for y = math.floor(p.y - r), math.floor(p.y + r), M.SCENIC_STRIDE do
      local tile = s.get_tile(x, y)
      tiles = tiles + 1
      if tile then
        if scenic.is_water(tile.name) then water = water + 1
        elseif scenic.is_built(tile.name) then built = built + 1 end
      end
    end
  end
  if tiles == 0 then return end
  local side = 2 * r + 1
  colony.scenic, colony.scenic_parts = scenic.score{
    tree_cover = trees / (side * side),
    water_cover = water / tiles,
    built_cover = built / tiles,
  }
end

-- A colonist packs up and walks away (#29). The newest arrival goes first. Unlike starvation this leaves no
-- body: destroying the entity is enough, because work's on_object_destroyed handler returns whatever the
-- colonist was carrying, frees its hut seat and drops its job label.
local function leave_one(colony)
  local un
  for id, c in pairs(colony.colonists) do
    if c.valid and (not un or id > un) and not commute.is_commuter(id) then un = id end   -- commuters are not ours to lose
  end
  if not un then return false end
  local c = colony.colonists[un]
  colony.colonists[un] = nil
  if colony.locks then colony.locks[un] = nil end
  colony.pop_cache, colony.pop_tick = nil, nil
  c.destroy()
  return true
end

function M.evaluate(data)
  local colony = storage.colonies[data.colony_id]
  if not colony then return end
  if not colony.hall.valid then return end    -- hall gone; colony dormant
  scheduler.after(M.interval(), "colony.evaluate", data)

  -- Salt pans (#81): evaporation needs nobody. Each pan fills on its own clock, so this costs one comparison
  -- per pan per evaluation and never scans the map.
  for un, pan in pairs(colony.salt_pans or {}) do
    if not pan.entity.valid then
      colony.salt_pans[un] = nil              -- reading .unit_number off a dead entity would error
    elseif game.tick >= (pan.next_at or 0) then
      pan.next_at = game.tick + salt.TICKS_PER_SALT
      if not salt.full(pan.entity.get_item_count(salt.ITEM)) then
        pan.entity.insert{name = salt.ITEM, count = 1}
      end
    end
  end

  -- Wells (#43): water generation. Each well fills on its own clock, so this costs one comparison
  -- per well per evaluation and never scans the map.
  for un, well_rec in pairs(colony.wells or {}) do
    if not well_rec.entity.valid then
      colony.wells[un] = nil
    elseif game.tick >= (well_rec.next_at or 0) then
      well_rec.next_at = game.tick + well.TICKS_PER_WATER
      if not well.full(well_rec.entity.get_item_count(well.ITEM)) then
        well_rec.entity.insert{name = well.ITEM, count = 1}
      end
    end
  end

  -- Wildlife (#79): one evaluation's worth of herd work - prune the dead, nudge the wanderers, top the herd
  -- up slowly. Bounded by wildlife.CAP, so this never grows with the town.
  wildlife.tick(colony, game.tick)

  local pop = M.live_colonists(colony)
  local houses = M.house_list(colony)
  local caps = {}
  for i, h in ipairs(houses) do caps[i] = housing.TIERS[h.kind].capacity end
  local occ = housing.distribute(pop, caps)

  -- per-house consumption (items come out of the house's own inventory)
  local score_sum, rated = 0, 0
  for i, h in ipairs(houses) do
    local tier = housing.TIERS[h.kind]
    local stock, inv = M.house_stock(h)
    local before = {}
    for k, v in pairs(stock) do before[k] = v end
    local consumed, sat, score, crit = housing.step(tier, occ[i], stock, M.is_powered(h), h.acc)
    h.stock_tick = nil   -- the shelves just changed: status lines must not read the old snapshot
    for item, n in pairs(consumed) do if n > 0 then inv.remove{name = item, count = n} end end
    h.score, h.sat, h.occupants = score, sat, occ[i]
    if occ[i] > 0 then
      score_sum = score_sum + score; rated = rated + 1
      if crit then
        h.hungry = (h.hungry or 0) + 1
        if h.hungry >= M.STARVE_AFTER then
          local lacking = "food"
          for _, need in ipairs(tier.needs) do
            if need.critical and not sat[need.id] then lacking = need.id; break end
          end
          kill_one(colony, h, lacking)
          h.hungry = 0
        end
      else h.hungry = 0 end
    end
  end
  colony.recreation = M.serve_taverns(colony, houses, occ)
  local kept = {}
  for _, a in ipairs(colony.deaths) do if a < 40 then kept[#kept + 1] = a + 1 end end
  colony.deaths = kept

  pop = M.live_colonists(colony)
  if (colony.scenic_n or 0) <= 0 then
    sample_scenic(colony)
    colony.scenic_n = M.SCENIC_EVERY
  else colony.scenic_n = colony.scenic_n - 1 end
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local pollution = scenic.pollution_ratio(colony.hall.surface.get_pollution(colony.hall.position))
  colony.pollution = pollution
  local d, parts = desirability.compute({
    food_ratio = M.total_food(colony) / target,
    free_housing_ratio = capacity > 0 and math.max(capacity - pop - (colony.away or 0), 0) / capacity or 0,
    scenic = colony.scenic or 0, leisure = rated > 0 and score_sum / rated or 0, recreation = colony.recreation or 0,
    pollution = pollution, deaths = colony.deaths,
    death_halflife = mortality_model.halflife(desirability.defaults.death_halflife, #M.cemetery_list(colony) > 0),
  })
  colony.d, colony.d_parts = d, parts
  if colony.accept_migrants ~= false and d > desirability.defaults.migrate_in and pop + (colony.away or 0) < capacity then
    local c = spawn_colonist(colony)
    if c then
      colony.hall.force.print({"colony-message.migrant-arrived", gps(c)})
      if settings.global["colony-debug-log"].value then
        game.print("[colony " .. colony.id .. "] migrant arrived, D=" .. string.format("%.2f", d))
      end
    end
  elseif d < desirability.defaults.leave_below then
    local n = colony_model.leave_count(pop, d)
    -- With a Passenger Platform and room in another colony, leavers take the train instead (#49).
    n = n - transit.depart(colony, n, 0)
    local gone = 0
    for _ = 1, n do if leave_one(colony) then gone = gone + 1 else break end end
    n = gone
    if n > 0 then
      colony.hall.force.print({"colony-message.colonists-left", n})
      if settings.global["colony-debug-log"].value then
        game.print("[colony " .. colony.id .. "] " .. n .. " colonist(s) left, D=" .. string.format("%.2f", d))
      end
    end
  end
  -- Colonists with no bed (a house was removed) move by train when another colony has room (#49).
  -- Commuters at work here (#50) sleep at home, so they are never homeless here.
  local homeless = M.live_colonists(colony) - #commute.here(colony) - M.capacity(colony) - transit.waiting_count(colony)
  if homeless > 0 then transit.depart(colony, 0, homeless) end
  commute.evaluate(colony)
  M.check_milestones(colony.hall.force)
  feedback.ensure(colony)
  -- Sleepers whose individual check was lost (save/load mid-walk) are woken here. Idle colonists already
  -- re-assign themselves on their `work.retry` timer, so walking the whole town here would double the
  -- assignment rate - and this loop runs for every colonist every evaluation (#22 caught the cost).
  if not work.is_sleep_time(colony.hall.surface) then
    for un, c in pairs(colony.colonists or {}) do
      local st = storage.unit_state and storage.unit_state[un]
      if c.valid and st and (st.state == "sleeping" or st.state == "to_bed") then
        st.state = "idle"
        work.assign(colony, un)
      end
    end
  end
end
scheduler.register("colony.evaluate", M.evaluate)

-- Forage patches are part of the world: autoplaced on grass in new chunks (see prototypes/buildings.lua),
-- and seeded once into chunks that were generated before the mod added them. The Forager's Hut only ever
-- harvests patches that already exist nearby - it never conjures bushes out of thin air.
local function chunk_seed(colony, cx, cy)
  local seed = (cx * 73856093 + cy * 19349663 + colony.id * 83492791) % 4294967296
  return math.floor(math.abs(seed))
end

function M.seed_forage(colony)
  if colony.forage_seeded then return 0 end
  colony.forage_seeded = true
  local hall = colony.hall
  if not (hall and hall.valid) then return 0 end
  local s = hall.surface
  local n = 0
  for _, c in ipairs(territory.chunks(colony)) do
    local cx, cy = c[1], c[2]
    if s.is_chunk_generated({x = cx, y = cy}) then
      local rng = game.create_random_generator(chunk_seed(colony, cx, cy))
      for _ = 1, M.FORAGE_PER_CHUNK do
        local x = cx * 32 + rng(0, 31) + 0.5
        local y = cy * 32 + rng(0, 31) + 0.5
        local tile = s.get_tile(x, y)
        if tile and M.FORAGE_TILES[tile.name]
          and s.can_place_entity{name = "colony-forage-patch", position = {x, y}}
          and s.create_entity{name = "colony-forage-patch", position = {x, y}, force = "neutral"} then
          n = n + 1
        end
      end
    end
  end
  return n
end

-- A harvested patch regrows where it was, if the spot is still free and still ours.
function M.on_forage_harvested(colony, pos)
  colony.rng = colony.rng or game.create_random_generator(colony.id * 7919)
  scheduler.after(M.REGROW_TICKS + colony.rng(0, M.REGROW_JITTER), "colony.regrow_patch",
    {colony_id = colony.id, pos = {x = pos.x, y = pos.y}})
end

scheduler.register("colony.regrow_patch", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall.valid) then return end
  local s = colony.hall.surface
  if territory.owner_at(colony.surface_index, d.pos) ~= colony.id then return end
  if not s.can_place_entity{name = "colony-forage-patch", position = d.pos} then return end
  s.create_entity{name = "colony-forage-patch", position = d.pos, force = "neutral"}
  for _, h in pairs(colony.huts or {}) do
    if h.job == "forage" and h.entity.valid then
      colony.no_site[h.entity.unit_number] = nil
    end
  end
end)

-- Chunks generated before the mod's autoplace existed have no patches yet: seed them once, on load.
scheduler.register("colony.seed_all", function()
  for _, colony in pairs(storage.colonies) do M.seed_forage(colony) end
end)

-- Re-create alt-mode badges for machines opted in before badges existed (#34).
scheduler.register("colony.rebadge", function()
  for _, colony in pairs(storage.colonies) do
    for _, m in pairs(colony.machines) do
      if m.enabled and m.entity.valid then M.set_machine(colony, m.entity, true) end
    end
  end
end)
events.on_configuration_changed(function()
  scheduler.after(1, "colony.seed_all", {})
  scheduler.after(1, "colony.rebadge", {})
end)

local function on_built(ev)
  local e = ev.entity or ev.created_entity
  if not (e and e.valid) then return end
  local name = name_of(e)
  local dict = ev.tags     -- blueprint tags: the only colony state a blueprint can carry (#36)

  -- Ghost placement validation (#83): reject ghosts placed outside valid territory or unbuildable soil/shores
  -- immediately with local flying text so the player never experiences a silent placement failure.
  if e.type == "entity-ghost" then
    if name == M.HALL then
      local owner = territory.owner_at(e.surface.index, e.position)
      if owner then
        local p = ev.player_index and game.get_player(ev.player_index)
        if p then p.create_local_flying_text{text = {"colony-message.hall-too-close"}, position = e.position} end
        e.destroy()
        return
      end
    elseif name == M.WATCHTOWER then
      local owner = territory.owner_at(e.surface.index, e.position)
      if not owner then
        local p = ev.player_index and game.get_player(ev.player_index)
        if p then p.create_local_flying_text{text = {"colony-message.watchtower-unclaimed"}, position = e.position} end
        e.destroy()
        return
      end
    elseif name == M.PLOT then
      local owner = territory.owner_at(e.surface.index, e.position)
      local tile = e.surface.get_tile(e.position)
      if not owner or not farm.plantable(tile.name) then
        local p = ev.player_index and game.get_player(ev.player_index)
        if p then p.create_local_flying_text{text = owner and {"colony-message.bad-farmland"} or {"colony-message.outside-territory"}, position = e.position} end
        e.destroy()
        return
      end
      local existing = e.surface.find_entities_filtered{name = M.PLOT, position = e.position, radius = 0.4}
      if #existing > 0 then
        local p = ev.player_index and game.get_player(ev.player_index)
        if p then p.create_local_flying_text{text = {"colony-message.plot-occupied"}, position = e.position} end
        e.destroy()
        return
      end
    elseif M.CRATES[name] or name == M.COMPOST_BIN or name == M.SALT_PAN or name == M.WELL or name == M.MOTOR_POOL or name == M.TAVERN or name == M.PLATFORM or name == M.CEMETERY or name == M.CANTEEN or M.HOUSES[name] or labour.HUTS[name] then
      local owner = territory.owner_at(e.surface.index, e.position)
      if not owner then
        local p = ev.player_index and game.get_player(ev.player_index)
        if p then p.create_local_flying_text{text = {"colony-message.outside-territory"}, position = e.position} end
        e.destroy()
        return
      end
      if name == M.SALT_PAN or (labour.HUTS[name] and labour.HUTS[name].job == "fish") then
        local ok, water = on_shore(e)
        if not ok then
          local p = ev.player_index and game.get_player(ev.player_index)
          if p then
            local msg = (name == M.SALT_PAN) and "colony-message.no-shore-salt" or "colony-message.no-shore"
            p.create_local_flying_text{text = {msg, water, fishing.MIN_WATER}, position = e.position}
          end
          e.destroy()
          return
        end
      end
    end
    return
  end

  if name == M.HALL then
    local owner = territory.owner_at(e.surface.index, e.position)
    if owner then refund(ev, e, name, {"colony-message.hall-too-close"}); e.destroy(); return end   -- no overlapping halls
    local id = storage.next_colony_id; storage.next_colony_id = id + 1
    local colony = {id = id, surface_index = e.surface.index, hall = e, houses = {}, machines = {}, huts = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {},
      colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}}
    storage.colonies[id] = colony
    M.seed_forage(colony)   -- the claimed land already has berries on it
    local founder = ev.player_index and game.get_player(ev.player_index)
    if founder then founder.create_local_flying_text{text = {"colony-message.colony-founded"}, position = e.position} end
    e.force.print({"colony-message.colony-founded-hint", gps(e)})
    M.check_milestones(e.force)
    feedback.ensure(colony)
    rendering.draw_circle{color = {0.1, 0.4, 0.15, 0.5}, width = 2, filled = false, radius = territory.HALL_RADIUS,
      target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
    scheduler.after(M.interval(), "colony.evaluate", {colony_id = id})
    scheduler.after(construct.SCAN_TICKS, "construct.scan", {colony_id = id})   -- #37 ghosts + damage
    scheduler.after(work.MACHINE_SWEEP_TICKS, "work.machine_sweep", {colony_id = id})   -- #75 machine output
    M.refresh_all_cursor_overlays()
  elseif name == M.PLOT then
    local owner = territory.owner_at(e.surface.index, e.position)
    local tile = e.surface.get_tile(e.position)
    if not owner or not farm.plantable(tile.name) then
      refund(ev, e, name, owner and {"colony-message.bad-farmland"} or nil)
      e.destroy()
      return
    end
    local existing = e.surface.find_entities_filtered{name = M.PLOT, position = e.position, radius = 0.4}
    if #existing > 1 then
      refund(ev, e, name, {"colony-message.plot-occupied"})
      e.destroy()
      return
    end
    local colony = storage.colonies[owner]
    colony.plots = colony.plots or {}
    colony.plots[e.unit_number] = {entity = e, colony_id = colony.id, stage = farm.FALLOW}
    e.graphics_variation = farm.FALLOW
    script.register_on_object_destroyed(e)
  elseif name == M.WATCHTOWER then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then
      refund(ev, e, name, {"colony-message.watchtower-unclaimed"})
      e.destroy()
      return
    end
    local colony = storage.colonies[owner]
    colony.towers[e.unit_number] = e
    local p = ev.player_index and game.get_player(ev.player_index)
    if p then
      p.create_local_flying_text{text = {"colony-message.watchtower-expanded", territory.TOWER_RADIUS}, position = e.position}
    end
    rendering.draw_circle{color = {0.1, 0.4, 0.15, 0.5}, width = 2, filled = false, radius = territory.TOWER_RADIUS,
      target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
    M.refresh_all_cursor_overlays()
  elseif M.CRATES[name] then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.crates = colony.crates or {}
    colony.crates[e.unit_number] = {entity = e, kind = M.CRATES[name], colony_id = colony.id,
      filters = {}, inflight = {}}
    script.register_on_object_destroyed(e)
    if dict then M.apply_tags(colony, e, dict) end
  elseif name == M.COMPOST_BIN then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.bins = colony.bins or {}
    colony.bins[e.unit_number] = {entity = e, colony_id = colony.id}
    script.register_on_object_destroyed(e)
    if not colony.compost_timer then
      colony.compost_timer = true
      scheduler.after(M.COMPOST_TICKS, "colony.compost", {colony_id = colony.id})
    end
  elseif name == M.SALT_PAN then
    -- Salt Pan (#81): shoreline evaporation, no worker. Same shore rule as the Fishing Dock, because salt is a
    -- *geography* problem - if there is no water to evaporate, there is no salt.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local ok, water = on_shore(e)
    if not ok then
      refund(ev, e, name, {"colony-message.no-shore-salt", water, fishing.MIN_WATER})
      e.destroy()
      return
    end
    local colony = storage.colonies[owner]
    colony.salt_pans = colony.salt_pans or {}
    colony.salt_pans[e.unit_number] = {entity = e, colony_id = colony.id,
      next_at = game.tick + salt.TICKS_PER_SALT}
    script.register_on_object_destroyed(e)
  elseif name == M.WELL then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.wells = colony.wells or {}
    colony.wells[e.unit_number] = {entity = e, colony_id = colony.id,
      next_at = game.tick + well.TICKS_PER_WATER}
    script.register_on_object_destroyed(e)
  elseif name == M.MOTOR_POOL then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.pools = colony.pools or {}
    colony.pools[e.unit_number] = {entity = e, colony_id = colony.id, inflight = {}, out = 0}
    script.register_on_object_destroyed(e)
  elseif name == M.PLATFORM then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.platforms = colony.platforms or {}
    colony.platforms[e.unit_number] = {entity = e, colony_id = colony.id}
    rendering.draw_circle{color = {0.4, 0.7, 1, 0.5}, width = 2, filled = false, radius = 10,
      target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
  elseif name == M.CANTEEN then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.canteens = colony.canteens or {}
    colony.canteens[e.unit_number] = {entity = e, colony_id = colony.id, inflight = {}}
    script.register_on_object_destroyed(e)
  elseif name == M.CEMETERY then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.cemeteries = colony.cemeteries or {}
    colony.cemeteries[e.unit_number] = {entity = e, colony_id = colony.id, graves = 0}
    script.register_on_object_destroyed(e)
  elseif name == M.TAVERN then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.taverns = colony.taverns or {}
    colony.taverns[e.unit_number] = {entity = e, colony_id = colony.id, inflight = {}, owed = 0}
    rendering.draw_circle{color = {0.9, 0.6, 0.2, 0.5}, width = 2, filled = false, radius = recreation.RADIUS,
      target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
  elseif (M.HOUSES[name] or labour.HUTS[name]) then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    if labour.HUTS[name] then
      if labour.HUTS[name].job == "fish" then
        local ok, water = on_shore(e)
        if not ok then
          refund(ev, e, name, {"colony-message.no-shore", water, fishing.MIN_WATER})
          e.destroy()
          return
        end
      end
      local hut = {entity = e, job = labour.HUTS[name].job, colony_id = colony.id, workers = {}, inflight = {}, wear = 0}
      if hut.job == "research" then
        e.custom_status = {
          diode = defines.entity_status_diode.red,
          label = {"colony-gui-hut.lab-unstaffed"}
        }
      end
      colony.huts[e.unit_number] = hut
      rendering.draw_circle{color = {0.45, 0.45, 0.15, 0.5}, width = 2, filled = false, radius = M.HUT_RADIUS,
        target = e, surface = e.surface, only_in_alt_mode = true}
      return
    end
    local h = {entity = e, kind = M.HOUSES[name], acc = {}, inflight = {}}
    if housing.needs_power(housing.TIERS[h.kind]) then
      h.sink = e.surface.create_entity{name = "colony-power-sink", position = e.position, force = e.force}
    end
    colony.houses[e.unit_number] = h
    script.register_on_object_destroyed(e)
  elseif dict and gui.MACHINE_GUIS[e.type] then
    -- A machine carries no colony prototype of ours, so only a blueprint tags can say it was opted in.
    local colony = M.colony_of(e)
    if colony then M.apply_tags(colony, e, dict) end
  end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)
events.on(defines.events.script_raised_built, on_built)
events.on(defines.events.script_raised_revive, on_built)

-- Territory is derived from the live hall and towers (territory.owner_at), so destroying a watchtower
-- shrinks it immediately: there is no index to rebuild.

-- --- cursor territory overlay (#83, #7 guidance) ---------------------------------------------------------
-- Rendered only while holding a watchtower or town hall in cursor. Attached rendering takes zero per-tick cost.
function M.clear_cursor_overlay(player_index)
  if not storage.cursor_overlays then return end
  local list = storage.cursor_overlays[player_index]
  if list then
    for _, r in ipairs(list) do
      if r and r.valid then r.destroy() end
    end
    storage.cursor_overlays[player_index] = nil
  end
end

function M.update_cursor_overlay(player)
  if not (player and player.valid) then return end
  M.clear_cursor_overlay(player.index)
  local item_name = nil
  if player.cursor_stack and player.cursor_stack.valid_for_read then
    item_name = player.cursor_stack.name
  elseif player.cursor_ghost then
    item_name = player.cursor_ghost.name
  end
  if not (item_name == M.WATCHTOWER or item_name == M.HALL or M.HOUSES[item_name] or labour.HUTS[item_name]
      or M.CRATES[item_name] or item_name == M.COMPOST_BIN or item_name == M.SALT_PAN
      or item_name == M.WELL or item_name == M.MOTOR_POOL or item_name == M.TAVERN or item_name == M.PLATFORM or item_name == M.CEMETERY or item_name == M.CANTEEN or item_name == M.PLOT) then return end

  local surface = player.surface
  local list = {}
  for _, colony in pairs(storage.colonies or {}) do
    if colony.surface_index == surface.index then
      if colony.hall and colony.hall.valid then
        local r_fill = rendering.draw_circle{
          color = {0.008, 0.032, 0.012, 0.04},   -- premultiplied: a faint wash, the terrain stays readable
          filled = true,
          radius = territory.HALL_RADIUS,
          target = colony.hall,
          surface = surface,
          players = {player},
        }
        local r_border = rendering.draw_circle{
          color = {0.1, 0.4, 0.15, 0.5},
          width = 2,
          filled = false,
          radius = territory.HALL_RADIUS,
          target = colony.hall,
          surface = surface,
          players = {player},
        }
        table.insert(list, r_fill)
        table.insert(list, r_border)
      end
      for _, tower in pairs(colony.towers or {}) do
        if tower and tower.valid then
          local r_fill = rendering.draw_circle{
            color = {0.008, 0.032, 0.012, 0.04},   -- premultiplied: a faint wash, the terrain stays readable
            filled = true,
            radius = territory.TOWER_RADIUS,
            target = tower,
            surface = surface,
            players = {player},
          }
          local r_border = rendering.draw_circle{
            color = {0.1, 0.4, 0.15, 0.5},
            width = 2,
            filled = false,
            radius = territory.TOWER_RADIUS,
            target = tower,
            surface = surface,
            players = {player},
          }
          table.insert(list, r_fill)
          table.insert(list, r_border)
        end
      end
    end
  end
  storage.cursor_overlays = storage.cursor_overlays or {}
  storage.cursor_overlays[player.index] = list
end

function M.refresh_all_cursor_overlays()
  if not storage.cursor_overlays then return end
  for player_index, _ in pairs(storage.cursor_overlays) do
    local p = game.get_player(player_index)
    if p and p.valid then M.update_cursor_overlay(p) end
  end
end

events.on(defines.events.on_player_cursor_stack_changed, function(ev)
  local p = ev.player_index and game.get_player(ev.player_index)
  if p and p.valid then M.update_cursor_overlay(p) end
end)
events.on(defines.events.on_player_changed_surface, function(ev)
  local p = ev.player_index and game.get_player(ev.player_index)
  if p and p.valid then M.update_cursor_overlay(p) end
end)
events.on(defines.events.on_pre_player_left_game, function(ev)
  if ev.player_index then M.clear_cursor_overlay(ev.player_index) end
end)
events.on(defines.events.on_runtime_mod_setting_changed, function(ev)
  if ev.setting and ev.setting:find("^colony%-quota%-") then
    for _, colony in pairs(storage.colonies or {}) do
      colony.ledger_cache = nil
      for un in pairs(colony.colonists or {}) do
        local st = storage.unit_state and storage.unit_state[un]
        if st and st.state == "idle" then
          work.assign(colony, un)
        end
      end
    end
  end
end)

events.on(defines.events.on_object_destroyed, function(ev)
  local un = ev.useful_id
  if not un then return end
  for _, colony in pairs(storage.colonies) do
    if colony.houses and colony.houses[un] then
      local h = colony.houses[un]
      if h.sink and h.sink.valid then h.sink.destroy() end
      colony.houses[un] = nil
      return
    end
    if colony.wells and colony.wells[un] then
      colony.wells[un] = nil
      return
    end
    if colony.platforms and colony.platforms[un] then
      colony.platforms[un] = nil   -- colonists waiting there notice on their next assignment and go back to work
      return
    end
    if colony.taverns and colony.taverns[un] then
      colony.taverns[un] = nil
      return
    end
    if colony.canteens and colony.canteens[un] then
      colony.canteens[un] = nil
      return
    end
    if colony.cemeteries and colony.cemeteries[un] then
      colony.cemeteries[un] = nil   -- the graves go with it; `buried` keeps the count
      return
    end
    if colony.pools and colony.pools[un] then
      colony.pools[un] = nil   -- trucks still out park at the hall instead (work.lua)
      return
    end
    if colony.towers and colony.towers[un] then
      colony.towers[un] = nil
      M.refresh_all_cursor_overlays()
      return
    end
    if colony.plots and colony.plots[un] then
      colony.plots[un] = nil
      return
    end
    if colony.crates and colony.crates[un] then
      colony.crates[un] = nil
      return
    end
    if colony.bins and colony.bins[un] then
      colony.bins[un] = nil
      return
    end
    if colony.salt_pans and colony.salt_pans[un] then
      colony.salt_pans[un] = nil
      return
    end
    if colony.machines and colony.machines[un] then
      colony.machines[un] = nil
      colony.machine_dirty = true
      return
    end
  end
end)

work.bind(M); gui.bind(M); feedback.bind(M); transit.bind(M); mortality.bind(M); shelter.bind(M); commute.bind(M, transit)   -- avoids a require cycle (runtime require is illegal)

-- ---------- opt-in machine registry (#34) ----------
-- The badge is alt-mode only: a small Town Hall icon over every machine the colony serves, so the player
-- can see coverage without opening each one. Rendering objects whose entity target is destroyed are
-- destroyed by the engine, so no cleanup is needed when a machine is mined.
M.BADGE_SPRITE = "entity/colony-town-hall"   -- SpritePath: the Town Hall's icon

-- Sensible request rows for a machine, so one marker drag leaves it working: five crafts' worth of each
-- ingredient (assemblers and furnaces). Anything without a readable recipe starts empty and is set by hand.
M.REQUEST_ROWS = 3
function M.default_requests(e)
  local out = {}
  local recipe = (e.type == "assembling-machine" or e.type == "furnace")
    and (e.get_recipe() or (e.type == "furnace" and e.previous_recipe and e.previous_recipe.name
      and prototypes.recipe[e.previous_recipe.name]))
  if recipe then
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" and #out < M.REQUEST_ROWS then out[#out + 1] = {item = ing.name, count = math.max(ing.amount * 5, 5)} end
    end
  end
  return out
end

function M.set_machine(colony, e, enabled)
  local m = colony.machines[e.unit_number]
  if enabled then
    m = m or {entity = e, requests = {}, collect = true, inflight = {}, need = nil, has_output = nil}
    m.entity = e
    m.enabled = true
    m.need, m.has_output = nil, nil      -- the sweep rediscovers both within a pass
    colony.machines[e.unit_number] = m
    if next(m.requests) == nil then m.requests = M.default_requests(e) end
    colony.machine_dirty = true
    script.register_on_object_destroyed(e)   -- so the registry (and the cached list) is pruned
    if not (m.badge and m.badge.valid) then
      m.badge = rendering.draw_sprite{sprite = M.BADGE_SPRITE, target = {entity = e, offset = {0, -1.3}},
        surface = e.surface, x_scale = 0.3, y_scale = 0.3, only_in_alt_mode = true}
    end
  elseif m then
    m.enabled = false
    m.need, m.has_output = nil, nil
    colony.machine_dirty = true
    if m.badge and m.badge.valid then m.badge.destroy() end
    m.badge = nil
  end
  return m
end

-- ---------- compost: spoilage -> fertilizer (#78) ----------
-- Batches, not a per-tick reaction: a bin's contents are read once per pass, the whole multiples of ten are
-- swapped for fertilizer, and the remainder stays for next time. Colonists move both halves in and out, so
-- nothing here touches an inventory that is not already there.
scheduler.register("colony.compost", function(d)
  local colony = storage.colonies[d.colony_id]
  if not colony then return end
  local bins = M.bin_list(colony)
  if #bins == 0 then
    colony.compost_timer = nil     -- nothing to compost; a new bin restarts the pass
    return
  end
  for _, b in ipairs(bins) do
    local have = b.entity.get_item_count(compost.SOURCE)
    local made = compost.batches(have)
    if made > 0 then
      b.entity.remove_item{name = compost.SOURCE, count = made * compost.SPOILAGE_PER_FERTILIZER}
      local left = made - b.entity.insert{name = compost.PRODUCT, count = made}
      if left > 0 then                      -- bin full: the fertilizer is not lost, it waits in the bin's place
        b.entity.insert{name = compost.SOURCE, count = left * compost.SPOILAGE_PER_FERTILIZER}
      end
    end
  end
  scheduler.after(M.COMPOST_TICKS, "colony.compost", d)
end)

-- ---------- blueprint / copy-paste persistence (#36) ----------
-- Everything above lives in `storage`, which a blueprint cannot see. BlueprintEntity.tags is the one channel
-- the engine carries from a blueprint back into the world (it arrives as `ev.tags` on build, and as
-- `ghost.tags` on the ghost itself), so the colony mirrors its per-entity settings there and restores them on
-- build, revive, copy-paste, clone and blueprint-paste-over.

-- Exported rather than a local: `on_built` is defined earlier in this file and must reach it at runtime.
function M.colony_of(e)
  local owner = territory.owner_at(e.surface.index, e.position)
  return owner and storage.colonies[owner]
end

-- The registry record behind an entity, wherever it stands: a blueprint source can be in any colony.
function M.find_record(e)
  if not (e and e.valid) then return end
  local un = e.unit_number
  if not un then return end
  for _, colony in pairs(storage.colonies) do
    local m = colony.machines[un]
    if m and m.enabled then return colony, "machine", m end
    local c = colony.crates and colony.crates[un]
    if c then return colony, "crate", c end
  end
end

-- Tag dictionary to write into a blueprint for this entity, or nil if the colony does not serve it.
function M.entity_tags(e)
  local _, kind, rec = M.find_record(e)
  if kind == "machine" then return tags.dictionary(tags.machine(rec)) end
  if kind == "crate" then return tags.dictionary(tags.crate(rec)) end
end

-- Restore settings a blueprint/copy carried. The payload is untrusted, so the model validates it.
function M.apply_tags(colony, e, dict)
  local payload = tags.decode(dict)
  if not (payload and colony and e and e.valid) then return false end
  if payload.machine then
    if not gui.MACHINE_GUIS[e.type] then return false end
    local m = M.set_machine(colony, e, true)
    if not m then return false end
    m.collect, m.requests = payload.machine.collect, payload.machine.requests
    m.need, m.has_output = nil, nil
    return true
  elseif payload.crate then
    local c = colony.crates and colony.crates[e.unit_number]
    if not c then return false end
    c.filters = payload.crate.filters
    return true
  end
  return false
end

-- Copy rows out of a registry record into a fresh table: two machines must never share the same row list.
local function copy_rows(rows)
  local out = {}
  for row, r in pairs(rows or {}) do
    if r and r.item then out[row] = {item = r.item, count = r.count} end
  end
  return out
end

-- Copy the colony half of copy-paste. The engine copies the entity's own settings; the registry is ours, so
-- a plain (un-opted-in) source clears the destination rather than leaving it serving silently.
function M.copy_settings(src, dst)
  if not (src and src.valid and dst and dst.valid) then return false end
  local colony = M.colony_of(dst)
  if not colony then return false end
  local _, kind, rec = M.find_record(src)
  if gui.MACHINE_GUIS[dst.type] then
    local m = M.set_machine(colony, dst, kind == "machine")
    if not m then return false end
    -- Not `x and y or z`: collect is a boolean, so that idiom turns a copied false back into true.
    if kind == "machine" then
      m.collect, m.requests = rec.collect, copy_rows(rec.requests)
    else
      m.collect, m.requests = true, {}
    end
    m.need, m.has_output = nil, nil
    return true
  end
  local c = colony.crates and colony.crates[dst.unit_number]
  if c then
    c.filters = kind == "crate" and copy_rows(rec.filters) or {}
    return true
  end
  return false
end

-- Write our tags into the blueprint being created. `mapping` is a LuaLazyLoadedValue of blueprint entity
-- index -> source entity, so the blueprint index never has to be guessed.
function M.tag_blueprint(target, mapping)
  if not (target and target.valid and mapping) then return 0 end
  local ok, map = pcall(function() return mapping.get and mapping:get() or mapping end)
  if not (ok and type(map) == "table") then return 0 end
  local n = 0
  for index, entity in pairs(map) do
    local dict = M.entity_tags(entity)
    if dict then
      local wrote = pcall(function()
        local existing = target.get_blueprint_entity_tags(index) or {}
        for k, v in pairs(dict) do existing[k] = v end
        target.set_blueprint_entity_tags(index, existing)
      end)
      if wrote then n = n + 1 end
    end
  end
  return n
end

events.on(defines.events.on_player_setup_blueprint, function(ev)
  M.tag_blueprint(ev.record or ev.stack, ev.mapping)
end)

events.on(defines.events.on_entity_settings_pasted, function(ev)
  M.copy_settings(ev.source, ev.destination)
end)

events.on(defines.events.on_entity_cloned, function(ev)
  M.copy_settings(ev.source, ev.destination)
end)

-- A blueprint pasted straight onto an existing entity (or ghost) skips both build paths above.
events.on(defines.events.on_blueprint_settings_pasted, function(ev)
  local e = ev.entity
  if not (e and e.valid) then return end
  local dict = ev.tags or (e.type == "entity-ghost" and e.tags) or nil
  if not dict then return end
  local colony = M.colony_of(e)
  if colony then M.apply_tags(colony, e, dict) end
end)

-- Colony overview for the Town Hall panel (#38). Plain data, computed on demand (GUI refresh only).
-- Milestones (model/milestones.lua) are force-wide: the best colony's population counts.
function M.milestone_facts(force)
  local best, halls = 0, 0
  for _, c in pairs(storage.colonies) do
    if c.hall and c.hall.valid and c.hall.force == force then
      halls = halls + 1
      best = math.max(best, M.live_colonists(c))
    end
  end
  local researched = {}
  for _, m in ipairs(milestones.LIST) do
    local t = force.technologies[m.tech]
    if t and t.researched then researched[m.tech] = true end
  end
  return {halls = halls, pop = best}, researched
end

function M.check_milestones(force)
  local facts, researched = M.milestone_facts(force)
  for _, name in ipairs(milestones.due(facts, researched)) do
    local t = force.technologies[name]
    if t then
      t.researched = true
      force.print({"colony-message.milestone", {"technology-name." .. name}, {"technology-description." .. name}})
    end
  end
end

-- Huts short of a tool, merged per tool and sorted: {{tool=, short=}}. A tool already on its way counts.
function M.tool_gaps(colony)
  local gaps = {}
  for _, h in pairs(colony.huts) do
    if h.entity.valid then
      local def, tools = work.hut_info(h)
      if def.tool then
        local short = math.min(def.capacity, h.limit or def.capacity) - tools - (h.inflight[def.tool] or 0)
        if short > 0 then gaps[#gaps + 1] = {tool = def.tool, short = short} end
      end
    end
  end
  table.sort(gaps, function(a, b) return a.tool < b.tool end)
  local merged = {}
  for _, g in ipairs(gaps) do
    local last = merged[#merged]
    if last and last.tool == g.tool then last.short = last.short + g.short else merged[#merged + 1] = g end
  end
  return merged
end

-- Town Hall workshop (model/workshop.lua): at most one tool per WORKSHOP_TICKS, made from colony stock for a
-- hut that is waiting on it, and only from recipes the force has unlocked. Shown over the hall as it happens.
M.WORKSHOP_TICKS = 600
function M.workshop(colony)
  if game.tick < (colony.workshop_at or 0) then return end
  local gaps = M.tool_gaps(colony)
  if #gaps == 0 then return end
  local recipes, unlocked = colony.hall.force.recipes, {}
  for _, g in ipairs(gaps) do
    if recipes[g.tool] and recipes[g.tool].enabled then unlocked[g.tool] = true end
  end
  local tool, recipe = workshop.pick(gaps, M.stock_table(colony), unlocked)
  if not tool then return end
  local items = {}
  for item in pairs(recipe) do items[#items + 1] = item end
  table.sort(items)
  for _, item in ipairs(items) do M.take_stock(colony, item, recipe[item]) end
  M.put_stock(colony, tool, 1)
  colony.workshop_at = game.tick + M.WORKSHOP_TICKS
  rendering.draw_text{text = {"colony-message.workshop-made", "[item=" .. tool .. "]"}, surface = colony.hall.surface,
    target = {entity = colony.hall, offset = {0, -2.5}}, color = {0.8, 1, 0.8}, scale = 1, alignment = "center",
    time_to_live = 120}
end

function M.stats(colony)
  local pop = M.live_colonists(colony)
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local food = M.total_food(colony)
  local tents, cabins, homesteads, apartments = 0, 0, 0, 0
  for _, h in ipairs(M.house_list(colony)) do
    if h.kind == "tent" then tents = tents + 1
    elseif h.kind == "cabin" then cabins = cabins + 1
    elseif h.kind == "homestead" then homesteads = homesteads + 1
    elseif h.kind == "apartment" then apartments = apartments + 1
    end
  end
  local chunks = #territory.chunks(colony)
  local huts, machines = 0, 0
  for _, h in pairs(colony.huts) do if h.entity.valid then huts = huts + 1 end end
  for _, m in pairs(colony.machines) do if m.enabled and m.entity.valid then machines = machines + 1 end end
  local towers, ghosts, damaged = 0, 0, 0
  for _, t in pairs(colony.towers or {}) do if t.valid then towers = towers + 1 end end
  for _, g in pairs(colony.ghosts or {}) do if g.valid then ghosts = ghosts + 1 end end
  for _, r in pairs(colony.repairs or {}) do if r.valid and construct.needs_repair(r.health, r.max_health) then damaged = damaged + 1 end end
  return {pop = pop, capacity = capacity, food = food, food_target = target, food_ratio = food / target,
    tents = tents, cabins = cabins, homesteads = homesteads, apartments = apartments,
    huts = huts, machines = machines, towers = towers, chunks = chunks,
    crates = #M.crate_list(colony), ghosts = ghosts, damaged = damaged,
    d = colony.d or 0, parts = colony.d_parts or {},
    scenic = colony.scenic or 0, pollution = colony.pollution or 0,
    fallen = colony.fallen or 0, buried = colony.buried or 0,
    away = colony.away or 0, commuters_here = #commute.here(colony)}
end

return M
