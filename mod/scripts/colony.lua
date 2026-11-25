-- Colony adapter (#24 #25 #28 #29): Town Hall claims territory, housing is territory-restricted,
-- periodic evaluation (scheduler, not per-tick) computes desirability and spawns migrants.
-- Rules live in scripts.model.*; this file only talks to the engine.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local farm = require("scripts.model.farm")
local specialization = require("scripts.model.specialization")
local crates = require("scripts.model.crates")
local links = require("scripts.model.links")
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
local theatre = require("scripts.model.theatre")
local plaza = require("scripts.model.plaza")
local inspiration = require("scripts.model.inspiration")
local research_speed = require("scripts.research_speed")
local forest = require("scripts.model.forest")
local tower_model = require("scripts.model.tower")
local turret_model = require("scripts.model.turret")
local yields = require("scripts.model.yields")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local tags = require("scripts.model.tags")
local ledger = require("scripts.model.ledger")
local quota = require("scripts.model.quota")
local supply_graph = require("scripts.model.supply_graph")
local headcount = require("scripts.model.headcount")
local milestones = require("scripts.model.milestones")
local material_priority = require("scripts.model.material_priority")
local work = require("scripts.work")
local gui = require("scripts.gui")
local feedback = require("scripts.feedback")
local transit = require("scripts.transit")
local mortality = require("scripts.mortality")
local shelter = require("scripts.shelter")
local commute = require("scripts.commute")
local tourism = require("scripts.tourism")
local illness = require("scripts.illness")
local militia = require("scripts.militia")
local armory = require("scripts.armory")
local patrol = require("scripts.patrol")
local command = require("scripts.command")
local mortality_model = require("scripts.model.mortality")
local breeding = require("scripts.model.breeding")
local stats = require("scripts.stats")
local tech = require("scripts.tech")
local ledger_signal = require("scripts.ledger_signal")
local core = require("scripts.model.core")
local planet = require("scripts.planet")
local M = {}

-- #63: a colony's core is either the seed Town Hall or a founding Habitat Dome. M.HALL keeps its literal
-- value (every proto/item/locale key uses it); `colony.hall` is the live *entity* and may be a dome.
M.HALL = core.HALL
M.DOME = core.DOME
M.CORE = core.CORE
M.is_core = core.is_core
M.is_dome = core.is_dome
M.WATCHTOWER = "colony-watchtower"
M.PLOT = "colony-farm-plot"
M.WELL = "colony-well"
M.WATER_TOWER = "colony-water-tower"
M.LEDGER = "colony-ledger"
M.MOTOR_POOL = "colony-motor-pool"
M.TAVERN = "colony-tavern"
M.THEATRE = "colony-theatre"        -- #48 slice B: worker-free Inspiration, shorter range than a Tavern
M.PLAZA = "colony-scenic-plaza"     -- #48 slice B: free decorative scenic bonus around the hall
M.PLATFORM = "colony-passenger-platform"
M.CEMETERY = "colony-cemetery"
M.CANTEEN = "colony-canteen"
M.SPA = "colony-spa"
M.ARMORY = "colony-armory"
M.PATROL_POST = "colony-patrol-post"
M.MEAL_ITEMS = commute.FOOD_ITEMS     -- what a Canteen serves (#50): the foods houses eat
local MEAL_SET = {}
for _, item in ipairs(M.MEAL_ITEMS) do MEAL_SET[item] = true end
M.is_sick = illness.is_sick
M.HUT_RADIUS = 48              -- working radius around a labour hut (other colonies' land excluded)
M.FORAGE_RADIUS = 96           -- working radius for Forager Huts (bushes are sparse, ~3/chunk)
M.REGROW_TICKS = 2400           -- a harvested forage patch grows back in place after this long...
M.REGROW_JITTER = 1800          -- ...plus up to this much, so a grove does not regrow in lockstep
M.FORAGE_PER_CHUNK = 3          -- natural forage patches seeded per already-generated territory chunk
M.FORAGE_TILES = {["grass-1"] = true, ["grass-2"] = true, ["grass-3"] = true, ["grass-4"] = true}
M.HOUSES = {["colony-housing-tent"] = "tent", ["colony-housing-cabin"] = "cabin",
  ["colony-housing-homestead"] = "homestead", ["colony-housing-townhouse"] = "townhouse",
  ["colony-housing-apartment"] = "apartment",
  ["colony-fusion-arcology"] = "arcology"}   -- #69 Tier-6 housing
M.HOUSES[M.DOME] = "dome"   -- #63: a dome is also a house (the founding dome is its core's stock room)
-- Colony logistics crates (#33): supply = provider, demand = requester, warehouse = bulk colony stock.
-- Haul Station (#94) is bulk stock like a Warehouse, plus a Wooden Trailer depot (work.lua).
M.SUPPLY_CRATE = "colony-supply-crate"
M.DEMAND_CRATE = "colony-demand-crate"
M.WAREHOUSE = "colony-warehouse"
M.HAUL_STATION = "colony-haul-station"
M.REFRIGERATED_WAREHOUSE = "colony-refrigerated-warehouse"
-- #69: the cryo store is ordinary bulk colony stock (accept-all, counted in the ledger) whose contents the
-- cold pass restamps ten times as often. Reusing the refrigerator kind means no new registry or schema.
M.CRYO_WAREHOUSE = "colony-cryo-warehouse"
M.LINK_CRATE = "colony-freight-crate"   -- #52: one half of a colony-to-colony freight pair
M.CRATES = {
  [M.SUPPLY_CRATE] = crates.SUPPLY,
  [M.DEMAND_CRATE] = crates.DEMAND,
  [M.WAREHOUSE] = crates.WAREHOUSE,
  [M.HAUL_STATION] = crates.HAUL_STATION,
  [M.REFRIGERATED_WAREHOUSE] = crates.REFRIGERATOR,
  [M.CRYO_WAREHOUSE] = crates.REFRIGERATOR,
  [M.LINK_CRATE] = crates.LINK,
}
-- Compost Bin (#78, design §3.2): spoilage is removed from houses and stock by colonists and converted here.
M.COMPOST_BIN = "colony-compost-bin"
M.SALT_PAN = "colony-salt-pan"
M.COMPOST_TICKS = 600           -- conversion pass cadence; a bin is a building, not a per-tick machine
M.STARVE_AFTER = 4              -- consecutive evaluations with unmet critical need before a colonist dies
M.BOOTSTRAP_SETTLERS = 4        -- migrants arrive briskly while the colony is below this, then five times slower
M.SCENIC_RADIUS = 40            -- tiles around the hall that scenic reads (fixed: cost must not grow with the town)
M.SCENIC_STRIDE = 4             -- tile sample stride: 1/16 of the area is actually read
M.SCENIC_EVERY = 4              -- evaluations between scenic samples (surroundings change slowly)
M.POP_TTL = 5                   -- ticks a cached population count / food total / stock snapshot may be reused
M.FOOD_TTL = 30
M.STOCK_TTL = 30
M.HOUSE_STOCK_TTL = 20          -- ticks a house's stock snapshot may be reused by the haul planner (#22)
M.POWERED_ENERGY = 10000        -- J in the hidden sink buffer that counts as 'powered'
M.FOOD_PER_COLONIST = yields.FOOD_PER_INTERVAL   -- food items per interval
-- Single source of truth for "colony food": the items a house can actually eat (#D2, #50 commute agrees).
-- The old hand-maintained list also held yumako, jellynut, bioflux, yumako-mash and jelly, which no colonist
-- can eat - counting them fed the migration gate, desirability and the empty-larder rule with inedible stock.
-- Derive it instead so the ledger/migration/desirability can never drift from housing.FOOD again.
M.FOOD_ITEMS = {}
for _, opt in ipairs(housing.FOOD) do M.FOOD_ITEMS[#M.FOOD_ITEMS + 1] = opt.item end
M.INTERVAL = 600                -- default ticks between evaluations
M.TARGET_STOCK_INTERVALS = 5

-- Ticks between evaluations (food use, migration, starvation). Runtime-global setting; tests may set storage.interval_override.
function M.interval()
  return storage.interval_override or (settings and settings.global and settings.global["colony-interval-seconds"] and settings.global["colony-interval-seconds"].value * 60) or M.INTERVAL
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

-- Habitat Domes (#63), in a stable order: [unit_number] = {entity, colony_id, ...}. A dome is a territory
-- emitter and a house; the founding dome is also the colony's core (aliased as `colony.hall`).
function M.dome_list(colony)
  local ids = {}
  for un, d in pairs(colony.domes or {}) do
    if d.entity and d.entity.valid then ids[#ids + 1] = un else colony.domes[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.domes[un] end
  return out
end

-- Theatres (#48 slice B), in a stable order: [unit_number] = {entity, colony_id, houses, inspired}.
-- `houses`/`inspired` are recomputed at every evaluation by serve_theatres and are only used by tooltips.
function M.theatre_list(colony)
  local ids = {}
  for un, t in pairs(colony.theatres or {}) do
    if t.entity.valid then ids[#ids + 1] = un else colony.theatres[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.theatres[un] end
  return out
end

-- Scenic Plazas (#48 slice B), in a stable order: [unit_number] = {entity, colony_id}. Pure decoration; the
-- only state they contribute is the count inside the hall's scenic radius, refreshed on the scenic cadence.
function M.plaza_list(colony)
  local ids = {}
  for un, p in pairs(colony.plazas or {}) do
    if p.entity.valid then ids[#ids + 1] = un else colony.plazas[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.plazas[un] end
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

-- Spas (#51), in a stable order: [unit_number] = {entity, colony_id}. A worker-free 2-visitor amenity;
-- it only creates host demand, so the registry is all the state it has.
function M.spa_list(colony)
  local ids = {}
  for un, s in pairs(colony.spas or {}) do
    if s.entity.valid then ids[#ids + 1] = un else colony.spas[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.spas[un] end
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
-- Water towers in stable order (#96); prunes dead ones.
function M.tower_list(colony)
  local ids = {}
  for un, t in pairs(colony.water_towers or {}) do
    if t.entity.valid then ids[#ids + 1] = un else colony.water_towers[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.water_towers[un] end
  return out
end

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

-- Armories (#56 remainder), in a stable order: [unit_number] = {entity, colony_id, inflight, equipped, limit}.
function M.armory_list(colony)
  return armory.list(colony)
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
    if not c.valid then
      local un = id
      if settings and settings.global and settings.global["colony-debug-log"] and settings.global["colony-debug-log"].value then
        local st = storage.unit_state and storage.unit_state[un]
        log(string.format("[colony-prune] tick=%d colonist %s became invalid (job=%s state=%s)",
          game.tick, tostring(un), tostring(st and st.job), tostring(st and st.state)))
      end
      colony.colonists[un] = nil
      if colony.locks then colony.locks[un] = nil end
    elseif not tourism.is_visitor(id) then
      n = n + 1   -- #51: a guest at a Spa is not a resident of the host town
    end
  end
  colony.pop_cache, colony.pop_tick = n, game.tick
  return n
end

-- Sorted live colonist unit_numbers: the stable order used by rosters and by house assignment.
function M.colonist_ids(colony)
  local ids = {}
  for un, c in pairs(colony.colonists) do
    if not c.valid then
      colony.colonists[un] = nil
      if colony.locks then colony.locks[un] = nil end
    elseif not tourism.is_visitor(un) then
      ids[#ids + 1] = un   -- #51: visitors get no host bed and are not in the household rosters
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
    for _, h in ipairs(houses) do h.inspired, h.inspiration_quality = nil, 0 end
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
    h.inspiration_quality = ti and inspiration.TAVERN or 0
    if ti then
      taverns[ti].houses = taverns[ti].houses + 1
      taverns[ti].inspired = taverns[ti].inspired + (occ[i] or 0)
    end
  end
  return coverage
end

-- Theatres (#48 slice B): worker-free and consumable-free, they Inspire every occupied house within 16 tiles
-- at quality 1.5 (overriding a Tavern's 1.25). Runs straight after serve_taverns, so the flags and qualities
-- the evaluation uses are the UNION of both amenities. Residents are counted once even where the radii overlap.
function M.serve_theatres(colony, houses, occ)
  local theatres = M.theatre_list(colony)
  if #theatres == 0 then return end   -- no Theatre: the Tavern coverage just computed stands unchanged
  local tl, hl = {}, {}
  for i, t in ipairs(theatres) do tl[i] = {position = t.entity.position} end
  for i, h in ipairs(houses) do hl[i] = {position = h.entity.position, occupants = occ[i] or 0} end
  local served = theatre.serve(tl, hl)
  for _, t in ipairs(theatres) do t.houses, t.inspired = 0, 0 end
  for i, h in ipairs(houses) do
    if served[i] then
      h.inspired = true
      h.inspiration_quality = math.max(h.inspiration_quality or 0, theatre.QUALITY)
      -- Tooltip attribution: nearest Theatre wins, ties go to the lower unit number (stable order).
      local hp, best, best_d = h.entity.position, nil, nil
      for ti, t in ipairs(theatres) do
        local tp = t.entity.position
        local dx, dy = hp.x - tp.x, hp.y - tp.y
        local d = dx * dx + dy * dy
        if not best_d or d < best_d then best, best_d = ti, d end
      end
      local t = theatres[best]
      if t then
        t.houses = t.houses + 1
        t.inspired = t.inspired + (occ[i] or 0)
      end
    end
  end
  local total, happy = 0, 0
  for i, h in ipairs(houses) do
    local n = occ[i] or 0
    total = total + n
    if h.inspired and n > 0 then happy = happy + n end
  end
  colony.recreation = total > 0 and happy / total or 0
  return colony.recreation
end

-- Inspired research cache (#48 slice A): how many scholars on duty are Inspired, and at what quality.
-- `split[i]` is this evaluation's sorted roster of colonist unit numbers living in `houses[i]`, and
-- `h.inspiration_quality` was just written by serve_taverns - so this needs no house-index lookup and no
-- second sort of the town beyond the scholar id list. Unit numbers are sorted before the float division so
-- two runs of the same save produce exactly the same share (MP determinism).
function M.compute_inspiration(colony, split, houses)
  local quality_of = {}
  for i, h in ipairs(houses) do
    local q = h.inspiration_quality or 0
    if q > 0 then
      for _, un in ipairs(split[i] or {}) do
        if q > (quality_of[un] or 0) then quality_of[un] = q end
      end
    end
  end
  local ids, total, inspired, weight = {}, 0, 0, 0
  for un, c in pairs(colony.colonists or {}) do if c.valid then ids[#ids + 1] = un end end
  table.sort(ids)
  local night = work.is_sleep_time(colony.hall.surface)
  for _, un in ipairs(ids) do
    local st = storage.unit_state and storage.unit_state[un]
    if st and st.job == "research" and st.hut and st.hut.entity and st.hut.entity.valid and not night
        and st.state ~= "sleeping" and st.state ~= "to_bed"
        and st.state ~= "to_shelter" and st.state ~= "sheltered" and st.state ~= "exposed" then
      total = total + 1
      local q = quality_of[un] or 0
      if q > 0 then
        inspired = inspired + 1
        weight = weight + (q - 1)   -- a Theatre scholar (0.5) must not lend its quality to every Tavern scholar
      end
    end
  end
  -- research_bonus(share, quality) = (quality-1)*share, so an AVERAGE inspired quality makes that product the
  -- sum of each scholar's bonus over all scholars. Taking the MAX quality instead would let one Theatre among
  -- a hundred Taverns hand the whole force +50% lab speed.
  local best = inspired > 0 and 1 + weight / inspired or 0
  colony.inspiration = {share = total > 0 and inspired / total or 0, quality = best}
  return colony.inspiration
end

-- The town's specialisation from the last sample, and its parts, so the work loop can add exactly +1 item to a
-- matching job's trip (#46). nil while the first sample hasn't landed (no bonus yet, no failure either).
function M.spec_of(colony) return colony and colony.spec or nil end
function M.spec_parts(colony) return colony and colony.spec_parts or nil end

-- Inspiration quality for one colonist (0 = none); the work buff still reads this as a boolean below.
function M.inspiration_quality(colony, un)
  local e = M.house_of_colonist(colony, un)
  local h = e and colony.houses[e.unit_number]
  if not h then return 0 end
  return h.inspiration_quality or (h.inspired == true and inspiration.TAVERN or 0)
end

-- Is this colonist Inspired (+25% work speed)? True when its house was served by a Tavern last evaluation.
function M.is_inspired(colony, un)
  return M.inspiration_quality(colony, un) > 0
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
    if c.entity.valid and c.entity.type ~= "entity-ghost" then
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

function M.link_crate_list(colony, role)
  local out = {}
  for _, c in ipairs(M.crate_list(colony, crates.LINK)) do
    if not role or c.role == role then out[#out + 1] = c end
  end
  return out
end

-- ---------- freight links (#52) ----------------------------------------------------------------------------
-- The registry is plain data in storage.links; the only live references are the LuaEntity fields already in
-- colony.crates. Everything below is O(1) lookups plus one bounded pass over the two slots - no world scan.

function M.link_record(c) return (c and storage.links and storage.links[c.link]) or nil end

function M.link_slot_live(slot)
  if not slot then return false end
  local col = storage.colonies and storage.colonies[slot.colony_id]
  local rec = col and col.crates and col.crates[slot.un]
  local e = rec and rec.entity
  return rec ~= nil and e ~= nil and e.valid and e.type ~= "entity-ghost"
    and rec.kind == crates.LINK and rec.colony_id == slot.colony_id and rec.link ~= nil
end

local function slot_summary(slot)
  local col = slot and storage.colonies and storage.colonies[slot.colony_id]
  local rec = col and col.crates and col.crates[slot.un]
  local e = rec and rec.entity
  return {colony_id = slot and slot.colony_id, un = slot and slot.un, role = slot and slot.role,
    kind = rec and rec.kind, alive = M.link_slot_live(slot),
    force = (e and e.valid) and e.force and e.force.name or nil,
    surface = (e and e.valid) and e.surface and e.surface.index or nil, rec = rec}
end

-- The peer slot of a linked crate, or nil. This is the trust boundary: both slots are cross-checked against
-- the live registry, the pair must be export -> import in different colonies on one force and one surface,
-- and the caller's role must agree with its slot. A mined/replaced/stale half yields no peer (and thus no
-- offer) instead of draining anything.
function M.link_peer(c)
  local link = M.link_record(c)
  local e = c and c.entity
  if not (link and e and e.valid) then return nil end
  local un = e.unit_number
  local self_slot
  if link.a and link.a.un == un then self_slot = link.a
  elseif link.b and link.b.un == un then self_slot = link.b
  else return nil end
  local a, b = slot_summary(link.a), slot_summary(link.b)
  local force_ok = a.force ~= nil and a.force == b.force
  local surface_ok = a.surface ~= nil and a.surface == b.surface
  local kind_ok = a.kind == crates.LINK and b.kind == crates.LINK
  if not links.valid_pair(a, b, force_ok, surface_ok, kind_ok) then return nil end
  if c.role ~= self_slot.role then return nil end
  return (self_slot == link.a) and link.b or link.a, link
end

local function link_label(col, un)
  return "Colony " .. tostring(col.id) .. " (crate " .. tostring(un) .. ")"
end

-- Drop-down data for the crate panel: unpaired freight crates in other colonies of the same force/surface.
function M.link_candidates(c)
  if not (c and c.kind == crates.LINK and c.entity and c.entity.valid) then return {} end
  local e = c.entity
  local force, surface = e.force and e.force.name, e.surface.index
  local entries = {}
  for _, col in pairs(storage.colonies or {}) do
    for _, r in ipairs(M.link_crate_list(col)) do
      local ce = r.entity
      if ce and ce.valid then
        entries[#entries + 1] = {colony_id = col.id, un = ce.unit_number, force = ce.force and ce.force.name,
          surface = ce.surface.index, kind = r.kind, link = r.link, label = link_label(col, ce.unit_number)}
      end
    end
  end
  return links.candidates(entries, c.colony_id, force, surface)
end

local function link_notify(player, rec, key)
  if not (player and player.valid) then return end
  local e = rec and rec.entity
  player.create_local_flying_text{text = {"colony-message." .. key},
    position = (e and e.valid) and e.position or player.position}
end

-- A unit number belongs to at most one slot in the whole registry. Without this guard a half-unlinked crate
-- can be bound again while its old record still claims the same un, after which destruction cleans only one
-- of the two records (#52 re-review finding: double-claim). Read-only, O(MAX_LINKS).
local function unit_number_claimed(un)
  if not un then return false end
  for _, l in pairs(storage.links or {}) do
    if (l.a and l.a.un == un) or (l.b and l.b.un == un) then return true end
  end
  return false
end

-- The ONE validity gate for a pair, shared by the GUI bind path and the blueprint rebind path (#52 review
-- finding 3). Neither path may skip self-link, territory, force or surface checks by mutating slots directly.
-- `a` is the half being (re)bound and must not already be claimed by any link; `b` is the peer, whose un is
-- legitimately claimed by the record being rebound into, so only bind_link checks `b` itself.
-- Returns (colony_a, colony_b) on success or (nil, nil, reason_key) on refusal.
local function validate_link_pair(a, b)
  if not (a and b and a.kind == crates.LINK and b.kind == crates.LINK) then return nil, nil, "link-invalid" end
  local ea, eb = a.entity, b.entity
  if not (ea and ea.valid and ea.type ~= "entity-ghost" and eb and eb.valid and eb.type ~= "entity-ghost") then
    return nil, nil, "link-invalid" end
  if unit_number_claimed(ea.unit_number) then return nil, nil, "link-taken" end
  local ca, cb = M.colony_of(ea), M.colony_of(eb)
  if not (ca and cb) then return nil, nil, "link-outside" end
  if ca.id == cb.id then return nil, nil, "link-self" end
  if ea.force ~= eb.force or ea.surface.index ~= eb.surface.index then return nil, nil, "link-invalid" end
  return ca, cb, nil
end

-- Bind two unpaired freight crates. a = export (source), b = import (destination). Returns true, link_id on
-- success or false, reason_key on refusal; the GUI turns the key into a flying text via link_notify.
function M.bind_link(a, b, player)
  local ca, cb, why = validate_link_pair(a, b)
  if why then link_notify(player, a, why); return false, why end
  if a.link or b.link or unit_number_claimed(b.entity.unit_number) then
    link_notify(player, a, "link-taken"); return false, "link-taken" end
  storage.links = storage.links or {}; storage.next_link_id = storage.next_link_id or 1
  local n = 0
  for _ in pairs(storage.links) do n = n + 1 end
  if n >= links.MAX_LINKS then link_notify(player, a, "link-full"); return false, "link-full" end
  local id = storage.next_link_id; storage.next_link_id = id + 1
  storage.links[id] = {id = id,
    a = {colony_id = ca.id, un = a.entity.unit_number, role = links.EXPORT},
    b = {colony_id = cb.id, un = b.entity.unit_number, role = links.IMPORT}}
  a.link, a.role, b.link, b.role = id, links.EXPORT, id, links.IMPORT
  M.invalidate_demand(cb)
  work.wake_idle_colonists(ca); work.wake_idle_colonists(cb)
  link_notify(player, a, "link-made")
  return true, id
end

-- Clear a pair by either half's unit number. Destruction calls this from on_object_destroyed (where the
-- caller's own registry record is already gone), so the lookup walks the bounded link registry, not crates.
function M.unbind_link(un)
  if not un then return false end
  -- Clear the caller's own record FIRST, even when no registry entry contains this un. A dangling tag-carried
  -- id (an old/foreign blueprint) must never leave a crate that can neither bind nor be unlinked (#52 review
  -- finding 1): the GUI Unlink button is a no-op only if this loop is skipped.
  local cleared = false
  for _, c in pairs(storage.colonies or {}) do
    local rec = c.crates and c.crates[un]
    if rec and (rec.link ~= nil or rec.role ~= nil) then
      rec.link, rec.role = nil, nil
      M.invalidate_demand(c)
      cleared = true
    end
  end
  -- Remove EVERY record that claims this un, in numeric id order. A stale double-claim must not leave one
  -- record behind (and pairs() would pick an arbitrary one), which would strand a peer and desync MP peers.
  local matches = {}
  if storage.links then
    for lid, l in pairs(storage.links) do
      if (l.a and l.a.un == un) or (l.b and l.b.un == un) then matches[#matches + 1] = lid end
    end
  end
  if #matches == 0 then return cleared end
  table.sort(matches)
  for _, lid in ipairs(matches) do
    local l = storage.links[lid]
    if l then
      local peer_slot = (l.a and l.a.un == un) and l.b or l.a
      if peer_slot then
        local col = storage.colonies and storage.colonies[peer_slot.colony_id]
        local peer = col and col.crates and col.crates[peer_slot.un]
        if peer then peer.link, peer.role = nil, nil; M.invalidate_demand(col) end
      end
      storage.links[lid] = nil
    end
  end
  return true
end

-- Mirrored filter edits travel to the peer's registry through the same pair, never to a proximity neighbour.
function M.mirror_link_filters(c)
  local peer = M.link_peer(c)
  if not peer then return false end
  local col = storage.colonies[peer.colony_id]
  local rec = col and col.crates and col.crates[peer.un]
  if not rec then return false end
  rec.filters = links.mirror(c.filters)
  M.invalidate_demand(col)
  local own = storage.colonies and storage.colonies[c.colony_id]
  if own then M.invalidate_demand(own) end
  return true
end

-- Restore a tag-carried pair identity. A ghost can only carry the tag until revival (it has no live unit
-- number); a LIVE crate whose tag id has no registry record is stale (pair destroyed, or a blueprint string
-- imported from another save) and stays fully unpaired - committing that id would brick the crate because
-- bind_link refuses a "taken" half and there would be no record for Unlink to clear (#52 review finding 1).
-- Rebinding into a free slot goes through validate_link_pair, the same gate as bind_link (#52 finding 3).
function M.restore_link_fields(colony, c, un, payload)
  -- Copy-paste calls this on an EXISTING, already-bound crate with no (or a stale/duplicate) link payload.
  -- Hold the old identity and restore it on EVERY refusal path: copy-paste must never half-unlink a pair
  -- (#52 re-review finding). A fresh crate has nil old fields, so the same refusals leave it unpaired.
  local old_link, old_role = c.link, c.role
  local function keep() c.link, c.role = old_link, old_role end
  local id = links.validate_id(payload and payload.id)
  local role = links.validate_role(payload and payload.role)
  if not (id and role) then keep(); return end
  if not un then c.link, c.role = id, role; return end   -- ghost: carry the tag, bind on revival
  local link = storage.links and storage.links[id]
  if not link then keep(); return end                    -- stale id: leave the live crate as it was
  local a_live, b_live = M.link_slot_live(link.a), M.link_slot_live(link.b)
  if a_live and b_live then keep(); return end           -- duplicate paste: no new pair, keep the old one
  local free = a_live and link.b or (b_live and link.a or nil)
  if not free then keep(); return end                    -- both halves dead: inert
  local peer_slot = (free == link.a) and link.b or link.a
  local peer_col = storage.colonies and storage.colonies[peer_slot.colony_id]
  local peer = peer_col and peer_col.crates and peer_col.crates[peer_slot.un]
  local own_col, validated_peer_col = validate_link_pair(c, peer)
  if not own_col then keep(); return end                 -- no self / double-claim / cross-force / cross-surface
  free.colony_id, free.un = own_col.id, un
  c.link, c.role = id, free.role or role
  M.invalidate_demand(own_col)
  if validated_peer_col then M.invalidate_demand(validated_peer_col) end
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

-- Haul Stations (#94) are bulk storage (like Warehouses) with a Wooden Trailer depot on the crate record
-- (trailer_wear/trailers_out). They are just crates of kind `station`, so lists filter by that kind.
function M.station_list(colony)
  return M.crate_list(colony, crates.HAUL_STATION)
end

-- All bulk storage crates (Warehouses + Haul Stations), sorted by unit_number so stock reads are stable.
function M.storage_crates(colony)
  local out = {}
  for _, c in ipairs(M.crate_list(colony, crates.WAREHOUSE)) do out[#out + 1] = c end
  for _, c in ipairs(M.crate_list(colony, crates.HAUL_STATION)) do out[#out + 1] = c end
  for _, c in ipairs(M.crate_list(colony, crates.REFRIGERATOR)) do out[#out + 1] = c end
  table.sort(out, function(a, b) return (a.entity.unit_number or 0) < (b.entity.unit_number or 0) end)
  return out
end

-- Colony stock (Town Hall + warehouses + watchtower buffers) as one table: an assignment asks about a dozen items and each
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
  for _, c in ipairs(M.storage_crates(colony)) do
    local inv = c.entity.get_inventory(defines.inventory.chest)
    if inv then
      for _, s in ipairs(inv.get_contents()) do t[s.name] = (t[s.name] or 0) + s.count end
    end
  end
  for un, tower in pairs(colony.towers or {}) do
    if tower.valid then
      local inv = tower.get_inventory(defines.inventory.chest)
      if inv then
        for _, s in ipairs(inv.get_contents()) do t[s.name] = (t[s.name] or 0) + s.count end
      end
    else
      colony.towers[un] = nil
    end
  end
  -- Armories (#56 remainder) are worker-free depots: their gear is colony stock, like a watchtower buffer.
  for _, a in ipairs(M.armory_list(colony)) do
    for name, n in pairs(armory.contents(a)) do t[name] = (t[name] or 0) + n end
  end
  -- Patrol Posts carry spare gear like any colony building (#57).
  for _, p in pairs(colony.patrol_posts or {}) do
    local inv = p.entity and p.entity.valid and p.entity.get_inventory(defines.inventory.chest)
    if inv then for _, s in ipairs(inv.get_contents()) do t[s.name] = (t[s.name] or 0) + s.count end end
  end
  colony.stock_cache, colony.stock_tick = t, game.tick
  return t
end

-- Storage locations (Town Hall, Warehouses, Watchtowers):
-- Hall is central working storage, Warehouses are bulk storage, Watchtowers are forward buffer storage.
function M.storage_accepts(s, item)
  if not s then return false end
  if s.accept_all ~= false then return true end
  return s.allowed_items ~= nil and s.allowed_items[item] == true
end

M.STORAGE_TTL = 30           -- ticks a storage_list snapshot may be reused by find_haul_task (#54 bench)

function M.storage_list(colony)
  if colony.storage_cache and game.tick - (colony.storage_tick or -1e9) < M.STORAGE_TTL then
    return colony.storage_cache
  end
  local list = {}
  local hall = colony.hall
  if hall and hall.valid then
    local inv = hall.get_inventory(defines.inventory.chest)
    local contents = {}
    if inv then for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end end
    list[#list + 1] = {
      kind = "hall",
      entity = hall,
      pos = hall.position,
      available = contents,
      has_space = inv and not inv.is_full(),
      key = hall.unit_number,
      storage_priority = colony.storage_priority or 3,
      accept_all = true,
    }
  end
  for _, c in ipairs(M.storage_crates(colony)) do
    if c.entity and c.entity.valid then
      local inv = c.entity.get_inventory(defines.inventory.chest)
      local contents = {}
      if inv then for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end end
      local accept_all = c.accept_all ~= false
      local allowed_items = {}
      if not accept_all and c.filters then
        for _, f in pairs(c.filters) do
          if f and f.item then allowed_items[f.item] = true end
        end
      end
      list[#list + 1] = {
        kind = c.kind == crates.HAUL_STATION and "haul_station" or
          (c.kind == crates.REFRIGERATOR and "refrigerator" or "warehouse"),
        entity = c.entity,
        pos = c.entity.position,
        available = contents,
        has_space = inv and not inv.is_full(),
        key = c.entity.unit_number,
        storage_priority = c.priority or (c.kind == crates.HAUL_STATION and 3 or 2),
        crate = c,
        accept_all = accept_all,
        allowed_items = allowed_items,
      }
    end
  end
  for un, tower in pairs(colony.towers or {}) do
    if tower.valid then
      local inv = tower.get_inventory(defines.inventory.chest)
      local contents = {}
      if inv then for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end end
      list[#list + 1] = {
        kind = "watchtower",
        entity = tower,
        pos = tower.position,
        available = contents,
        has_space = inv and not inv.is_full(),
        key = un,
        storage_priority = 4,
        accept_all = true,
      }
    else
      colony.towers[un] = nil
    end
  end
  for _, a in ipairs(M.armory_list(colony)) do
    local inv = a.entity.get_inventory(defines.inventory.chest)
    local contents = {}
    if inv then for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end end
    list[#list + 1] = {
      kind = "armory", entity = a.entity, pos = a.entity.position, available = contents,
      has_space = inv and not inv.is_full(), key = a.entity.unit_number,
      storage_priority = a.priority or 3, accept_all = true,
    }
  end
  for un, p in pairs(colony.patrol_posts or {}) do
    if p.entity and p.entity.valid then
      local inv = p.entity.get_inventory(defines.inventory.chest)
      local contents = {}
      if inv then for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end end
      list[#list + 1] = {kind = "patrol_post", entity = p.entity, pos = p.entity.position,
        available = contents, has_space = inv and not inv.is_full(), key = un,
        storage_priority = 3, accept_all = true}
    end
  end
  colony.storage_cache, colony.storage_tick = list, game.tick
  return list
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
  for _, c in ipairs(M.storage_crates(colony)) do
    if c.entity and c.entity.valid then
      local inv = c.entity.get_inventory(defines.inventory.chest)
      if inv then for _, s in ipairs(inv.get_contents()) do stock[s.name] = (stock[s.name] or 0) + s.count end end
    end
  end
  for un, tower in pairs(colony.towers or {}) do
    if tower.valid then
      local inv = tower.get_inventory(defines.inventory.chest)
      if inv then for _, s in ipairs(inv.get_contents()) do stock[s.name] = (stock[s.name] or 0) + s.count end end
    else
      colony.towers[un] = nil
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
  for _, a in ipairs(M.armory_list(colony)) do
    local inv = a.entity.get_inventory(defines.inventory.chest)
    if inv then
      local contents = {}
      for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end
      huts_data[#huts_data + 1] = {name = a.entity.name, contents = contents}
    end
  end
  for _, p in pairs(colony.patrol_posts or {}) do
    local inv = p.entity and p.entity.valid and p.entity.get_inventory(defines.inventory.chest)
    if inv then
      local contents = {}
      for _, s in ipairs(inv.get_contents()) do contents[s.name] = s.count end
      huts_data[#huts_data + 1] = {name = p.entity.name, contents = contents}
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
    include_zero = quota.RESOURCES,
  }
  colony.ledger_cache, colony.ledger_tick = res, game.tick
  return res
end

-- --- harvest quotas (#84) --------------------------------------------------------------------------------
function M.global_quotas()
  -- Settings change rarely; a 300-tick cache stops base_quota_target from rebuilding a 25-item table
  -- (and reading every setting) nine times per assignment (#54 bench).
  if M._global_quotas_cache and game.tick - (M._global_quotas_tick or -1e9) < 300 then
    return M._global_quotas_cache
  end
  local g = {}
  if settings and settings.global then
    for item in pairs(quota.RESOURCES) do
      local s = settings.global["colony-quota-" .. item]
      if s and s.value and s.value > 0 then g[item] = s.value end
    end
  end
  M._global_quotas_cache, M._global_quotas_tick = g, game.tick
  return g
end

-- The recipe map is derived from the force's unlocked recipes, so it does not belong in storage's schema:
-- it is rebuilt lazily (and after a research finishes it is at most `GRAPH_TTL` ticks stale).
M.GRAPH_TTL = 1800

-- {product -> {ingredients, yield}} for what this force can actually make (#90). One recipe per product,
-- chosen by `supply_graph.build` (fewest ingredient types). Fluids are kept: they are inert in the quota
-- tables, but they are what a real chain passes through.
local function recipe_graph(force)
  if not (force and force.valid) then return nil end
  M.recipe_graph_cache = M.recipe_graph_cache or {}
  local cached = M.recipe_graph_cache[force.index]
  if cached and cached.recipes and cached.tick and game.tick - cached.tick < M.GRAPH_TTL then
    return cached.recipes
  end
  local list = {}
  for name, r in pairs(prototypes.recipe) do
    local fr = force.recipes[name]
    if fr and fr.enabled and not r.hidden then
      local products, ingredients = {}, {}
      for _, p in pairs(r.products or {}) do
        products[#products + 1] = {p.name, p.amount or p.amount_min or 1}
      end
      for _, i in pairs(r.ingredients or {}) do
        ingredients[#ingredients + 1] = {i.name, i.amount or i.amount_min or 1}
      end
      if #products > 0 and #ingredients > 0 then
        list[#list + 1] = {name = name, products = products, ingredients = ingredients}
      end
    end
  end
  local recipes = supply_graph.build(list)
  M.recipe_graph_cache[force.index] = {recipes = recipes, tick = game.tick}
  return recipes
end
M.recipe_graph = recipe_graph

-- Whole-colony demand: the direct seeds plus everything their recipes pull from one floor down (#90).
-- Cached for a short while because `quota_target` is asked for many items on every assignment, and the
-- propagation is a graph walk. `M.invalidate_demand` drops it when the colony's shape changes.
M.DEMAND_TTL = 30
local demand_cache = {}   -- [colony.id] = {tick =, table =}

function M.invalidate_demand(colony)
  if colony then demand_cache[colony.id] = nil end
end

function M.demand_table(colony)
  if not colony then return {} end
  local c = demand_cache[colony.id]
  if c and c.tick and game.tick - c.tick < M.DEMAND_TTL then return c.table end

  local seeds = {}
  -- Machine requests and demand crates, collected in one pass so the graph walk happens once.
  for _, m in pairs(colony.machines or {}) do
    if m.entity and m.entity.valid and m.enabled and m.requests then
      for _, req in pairs(m.requests) do
        if req.item then seeds[req.item] = (seeds[req.item] or 0) + (req.count or 0) end
      end
    end
  end
  for _, crate in ipairs(M.crate_list(colony, crates.DEMAND)) do
    for i = 1, crates.FILTER_ROWS do
      local f = crate.filters and crate.filters[i]
      if f and f.item then seeds[f.item] = (seeds[f.item] or 0) + (f.count or crates.DEFAULT_COUNT) end
    end
  end
  -- #52: an import freight crate's filters are B's want list, so B's #90 demand graph and quotas know the
  -- town wants those items. The export half deliberately does NOT seed A's demand: it ships surplus only.
  for _, crate in ipairs(M.link_crate_list(colony, links.IMPORT)) do
    -- Only a live, actually paired import half is a real want list. A stray unpaired paste with an import
    -- role must not inflate this colony's #90 demand (#52 review finding 6).
    if crate.link ~= nil then
      for i = 1, crates.FILTER_ROWS do
        local f = crate.filters and crate.filters[i]
        if f and f.item then seeds[f.item] = (seeds[f.item] or 0) + (f.count or crates.DEFAULT_COUNT) end
      end
    end
  end
  for _, h in pairs(colony.huts or {}) do
    if h.entity and h.entity.valid then
      local def = labour.HUTS[h.entity.name]
      for _, inp in ipairs(def and def.inputs or {}) do
        if inp.item then seeds[inp.item] = (seeds[inp.item] or 0) + inp.count end
      end
    end
  end

  local recipes = recipe_graph(colony.hall and colony.hall.force)
  local upstream = supply_graph.whole(supply_graph.propagate(recipes, seeds))
  local table_ = supply_graph.merge(seeds, upstream)
  demand_cache[colony.id] = {tick = game.tick, table = table_}
  return table_
end

-- Downstream demand for a resource, including everything that is produced from it (#90).
function M.resource_demand(colony, item)
  if not colony then return 0 end
  local t = M.demand_table(colony)
  return t[item] or 0
end

function M.base_quota_target(colony, item)
  if colony and colony.quotas and colony.quotas[item] ~= nil then
    return tonumber(colony.quotas[item]) or 0
  end
  local g = M.global_quotas()
  if g and g[item] then return tonumber(g[item]) or 0 end
  local res_def = quota.RESOURCES[item]
  if res_def then return res_def.default or quota.DEFAULT_QUOTA end
  return 0
end

function M.quota_target(colony, item)
  local base = M.base_quota_target(colony, item)
  if base <= 0 then return 0 end
  local extra = M.resource_demand(colony, item)
  return base + extra
end

function M.quota_met(colony, item)
  local tgt = M.quota_target(colony, item)
  if tgt <= 0 then return false end
  local count = M.stock_count(colony, item)
  return quota.met(tgt, count)
end

function M.set_quota(colony, item, target)
  colony.quotas = colony.quotas or {}
  colony.quotas[item] = target
  colony.ledger_cache = nil
  M.invalidate_demand(colony)
  for _, h in pairs(colony.huts or {}) do
    h.quota_met = nil
    h.quota_item = nil
  end
  work.wake_idle_colonists(colony)
end

-- Colony-wide material priorities (#91): [item] = {rank = 1..5, enabled = bool}
function M.material_rank(colony, item)
  if not colony then return material_priority.DEFAULT end
  return material_priority.rank(colony.ratings, item)
end

function M.material_enabled(colony, item)
  if not colony then return true end
  return material_priority.enabled(colony.ratings, item)
end

function M.set_material_rank(colony, item, rank)
  if not colony then return end
  colony.ratings = colony.ratings or {}
  colony.ratings[item] = colony.ratings[item] or {rank = material_priority.DEFAULT, enabled = true}
  local r = math.floor(tonumber(rank) or material_priority.DEFAULT)
  if r < 1 then r = 1 end
  if r > material_priority.MAX_RANK then r = material_priority.MAX_RANK end
  colony.ratings[item].rank = r
  work.wake_idle_colonists(colony)
end

function M.shift_material_rank(colony, item, delta)
  if not colony then return end
  colony.ratings = colony.ratings or {}
  material_priority.shift(colony.ratings, item, delta)
  work.wake_idle_colonists(colony)
end

function M.set_material_enabled(colony, item, on)
  if not colony then return end
  colony.ratings = colony.ratings or {}
  material_priority.set_enabled(colony.ratings, item, on)
  work.wake_idle_colonists(colony)
end

function M.overflow_allowed(colony, item)
  if not colony then return true end
  return quota.overflow_allowed(colony.overflow, item)
end

function M.set_overflow(colony, item, enabled)
  if not colony then return end
  colony.overflow = colony.overflow or {}
  colony.overflow[item] = enabled
  if enabled then
    work.wake_idle_colonists(colony)
  end
end

function M.hut_overflow_allowed(colony, h)
  if not (colony and h) then return false end
  local res = work.hut_resources(h)
  if not res then return false end
  for _, item in ipairs(res) do
    if M.overflow_allowed(colony, item) then return true end
  end
  return false
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
    if c.valid and st then
      -- M3 militia (#55): an on-duty militia is not "idle", but a lock change must still reach work.assign
      -- (which re-posts it or demobilises it according to the current lock). Without this the job is sticky.
      if st.state == "idle" or militia.is_duty(st) then
        work.assign(colony, un)
      elseif (st.state == "sleeping" or st.state == "to_bed") and not work.is_sleep_time(c.surface) then
        work.wake_up(colony, un, c)
      end
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
  -- Stock moved: both snapshots are stale. `storage_cache` is what a haul plan matches against (30 ticks, #54
  -- bench), so leaving it warm let the next plan offer goods this call had already removed.
  colony.stock_cache, colony.storage_cache = nil, nil
  local taken = 0
  local storages = M.storage_list(colony)
  table.sort(storages, function(a, b)
    local spa = a.storage_priority or 3
    local spb = b.storage_priority or 3
    if spa ~= spb then return spa < spb end
    return (a.key or 0) < (b.key or 0)
  end)
  for _, s in ipairs(storages) do
    if taken >= count then break end
    if s.entity and s.entity.valid then
      taken = taken + s.entity.remove_item{name = item, count = count - taken}
    end
  end
  if taken > 0 then
    for _, h in pairs(colony.huts or {}) do
      if h.quota_item == item then
        h.quota_item = nil
        h.quota_met = nil
      end
    end
  end
  return taken
end

function M.put_stock(colony, item, count)
  colony.stock_cache, colony.storage_cache = nil, nil   -- stock moved: both snapshots are stale
  local left = count
  local storages = M.storage_list(colony)
  table.sort(storages, function(a, b)
    local spa = a.storage_priority or 3
    local spb = b.storage_priority or 3
    if spa ~= spb then return spa < spb end
    return (a.key or 0) < (b.key or 0)
  end)
  for _, s in ipairs(storages) do
    if left <= 0 then break end
    if s.entity and s.entity.valid and M.storage_accepts(s, item) then
      left = left - s.entity.insert{name = item, count = left}
    end
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
  -- A founding Habitat Dome is both the core stock room (already counted by food_in/colony.hall) and a
  -- registered house; counting its chest here too would double it. Every other domes' chest is ordinary
  -- house stock and still counts.
  local core_entity = colony.hall and colony.hall.valid and colony.hall
  for _, h in ipairs(M.house_list(colony)) do
    if not (core_entity and h.kind == "dome" and h.entity == core_entity) then
      local stock = M.house_stock(h)
      for _, opt in ipairs(housing.FOOD) do n = n + (stock[opt.item] or 0) end
    end
  end
  -- Warehouses and hut stockpiles count too: food only waits there until a hauler clears it.
  for _, c in ipairs(M.storage_crates(colony)) do
    for _, item in ipairs(M.FOOD_ITEMS) do
      if prototypes.item[item] then n = n + c.entity.get_item_count(item) end
    end
  end
  for un, tower in pairs(colony.towers or {}) do
    if tower.valid then
      for _, item in ipairs(M.FOOD_ITEMS) do
        if prototypes.item[item] then n = n + tower.get_item_count(item) end
      end
    else
      colony.towers[un] = nil
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

-- Food ANYWHERE in the colony (hall + house shelves + crates + towers + huts), for the "empty larder" rule in
-- model/needs.lua (#D3). `food_in` is deliberately hall-only for UI text: a settled town keeps its food out in
-- the house shelves, so reading the hall alone would promote every food role while the colonists are fed.
function M.food_available(colony)
  return M.total_food(colony)
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
      if settings and settings.global and settings.global["colony-debug-log"] and settings.global["colony-debug-log"].value then
        log(string.format("[colony-kill-one] tick=%d colonist %s in %s lacks %s (starvation) shelf:%s",
          game.tick, tostring(id), h.entity.name, tostring(need_id), tostring(h.entity.get_item_count("raw-fish") or "?")))
      end
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
-- A new colonist at the hall, or at `at` (a house for a newborn, #88, or a Passenger Platform, #49).
-- `birth` swaps the arrival messaging for a birth and registers the child separately (storage.age).
local function spawn_colonist(colony, at, birth)
  local hall = colony.hall
  local pos = hall.surface.find_non_colliding_position("colony-colonist", at or hall.position, 10, 0.5)
  if not pos then return false end
  local c = hall.surface.create_entity{name = "colony-colonist", position = pos, force = hall.force}
  if not c then return false end
  colony.colonists[c.unit_number] = c
  colony.pop_cache, colony.pop_tick = nil, nil
  script.register_on_object_destroyed(c)
  if birth then   -- registered before the job assignment, so the newborn is never given work
    storage.age = storage.age or {}
    storage.age[c.unit_number] = {stage = "child", born = game.tick}
  end
  work.assign(colony, c.unit_number)
  if birth then
    colony.hall.force.print({"colony-message.child-born", gps(c)})
    rendering.draw_text{text = {"colony-message.child-born-popup"}, surface = c.surface,
      target = {entity = c, offset = {0, -2}}, color = {1, 0.85, 0.9}, scale = 0.9, alignment = "center",
      time_to_live = 180}
  else
    rendering.draw_text{text = {"colony-message.arrival-popup"}, surface = hall.surface,
      target = {entity = c, offset = {0, -2}}, color = {0.8, 1, 0.8}, scale = 0.9, alignment = "center",
      time_to_live = 180}
  end
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
  local base, parts = scenic.score{
    tree_cover = trees / (side * side),
    water_cover = water / tiles,
    built_cover = built / tiles,
  }
  -- Scenic Plazas (#48 slice B): a separate, capped term added AFTER the terrain score, so a town with no
  -- Plaza keeps exactly the old scenic number. Counted on the same four-evaluation cadence as the tile scan.
  local count = 0
  for _, pz in ipairs(M.plaza_list(colony)) do
    if plaza.in_radius(pz.entity.position, p, r) then count = count + 1 end
  end
  local pb = plaza.bonus(count)
  colony.plaza_count = count
  colony.scenic = math.min(1, base + pb)   -- with no Plaza pb == 0, so this is the old number bit-for-bit
  parts.plaza = pb
  colony.scenic_parts = parts
end

-- Specialization (#46): the town's land-shaped specialty from the huts the player built there. A town builds
-- docks near shore, farms on plants, woodcutters in woods, miners near ore - each hut is the geography. Count
-- them cheaply on the same cadence as the scenic sample; zero tile scans.
local function refresh_specialization(colony)
  local huts = {}
  for _, h in pairs(colony.huts or {}) do
    if h.entity and h.entity.valid then huts[#huts + 1] = {name = h.entity.name, job = h.job} end
  end
  for _, sp in pairs(colony.salt_pans or {}) do
    if sp.entity and sp.entity.valid then huts[#huts + 1] = {name = sp.entity.name} end
  end
  local census = specialization.census(huts)
  colony.spec_parts, colony.spec = specialization.score(census)
end

-- A colonist packs up and walks away (#29). The newest arrival goes first; children stay (#88). Unlike starvation
-- this leaves no body: destroying the entity is enough, because work's on_object_destroyed handler returns whatever
-- the colonist was carrying, frees its hut seat and drops its job label.
local function leave_one(colony)
  local un
  for id, c in pairs(colony.colonists) do
    local child = storage.age and storage.age[id] and storage.age[id].stage == "child"
    if c.valid and (not un or id > un) and not commute.is_commuter(id) and not tourism.is_visitor(id) and not child then un = id end   -- commuters, guests and children are not ours to lose
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
  if not colony.hall.valid then
    -- The colony is dormant, but its force may still be carrying the last Inspired research bonus. There is
    -- no hall to read the force from here, so sweep the forces we have durable records for; target_for()
    -- ignores invalid halls and drops the bonus to zero. Without this the modifier would never clear (M2).
    research_speed.apply_all()
    return
  end
  -- #63 review: self-heal old saves (and any core created before the unified init) without a schema bump. The
  -- plain core identity is captured while `colony.hall` is still live; the death handler then never has to read
  -- a possibly-pruned power sink to decide whether a dome may inherit the colony.
  if not colony.hall_un or not colony.hall_force then
    colony.hall_un = colony.hall.unit_number
    colony.hall_force = colony.hall.force and colony.hall.force.name
  end
  scheduler.after(M.interval(), "colony.evaluate", data)

  -- Cultural Insights (#51): the stat itself decays once per evaluation (12-evaluation half-life). The
  -- lifetime total on the panel never decays and never feeds desirability.
  tourism.decay(colony)

  -- Salt pans (#81): evaporation needs nobody. Each pan fills on its own clock, so this costs one comparison
  -- per pan per evaluation and never scans the map.
  for un, pan in pairs(colony.salt_pans or {}) do
    if not pan.entity.valid then
      colony.salt_pans[un] = nil              -- reading .unit_number off a dead entity would error
    elseif game.tick >= (pan.next_at or 0) then
      pan.next_at = game.tick + salt.TICKS_PER_SALT
      if not salt.full(pan.entity.get_item_count(salt.ITEM)) then
        pan.entity.insert{name = salt.ITEM, count = 1}
        stats.produced(colony, salt.ITEM, 1)
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
        stats.produced(colony, well.ITEM, 1)
      end
    end
  end

  -- Wildlife (#79): one evaluation's worth of herd work - prune the dead, nudge the wanderers, top the herd
  -- up slowly. Bounded by wildlife.CAP, so this never grows with the town.
  wildlife.tick(colony, game.tick)

  local pop = M.live_colonists(colony)
  local houses = M.house_list(colony)
  -- Water towers (#96): one pass builds the serve list; houses then drink from it nearest-first. Built once
  -- per evaluation, before the consumption loop, with fresh water counts.
  local towers
  do
    for _, t in ipairs(M.tower_list(colony)) do
      local inv = t.entity.get_inventory(defines.inventory.crafter_output)
      towers = towers or {}
      towers[#towers + 1] = {position = t.entity.position, water = inv and inv.get_item_count("colony-water") or 0,
        id = t.entity.unit_number, entity = t.entity}
    end
  end
  local caps = {}
  for i, h in ipairs(houses) do caps[i] = housing.TIERS[h.kind].capacity end
  local split = housing.assign(M.colonist_ids(colony), caps)   -- who lives where, sorted; the same fill as distribute()
  local occ, mouths = {}, {}
  for i, h in ipairs(houses) do
    local list = split[i] or {}
    occ[i] = #list
    local adults = 0
    for _, un in ipairs(list) do
      local rec = storage.age and storage.age[un]
      if not (rec and rec.stage == "child") then adults = adults + 1 end
    end
    mouths[i] = adults + (occ[i] - adults) * breeding.CHILD_RATE   -- children eat half (#88)
    h.mouths = mouths[i]
  end

  -- per-house consumption (items come out of the house's own inventory)
  local score_sum, rated = 0, 0
  local rotten = {}     -- houses that just ate nearly spoiled food (#47)
  for i, h in ipairs(houses) do
    -- Reset before the injection block: a house whose tower ran dry must not inherit last evaluation's service
    -- flag and keep its water haul request suppressed (#D1). Accepted tradeoff: the flag is only recomputed here
    -- on the evaluation cadence (600 ticks by default), so if a tower runs dry or is destroyed mid-interval the
    -- house keeps its water need suppressed for at most one interval. The next evaluation resets it and the
    -- emergency pantry / a haul offer then covers the gap; this avoids a per-tick tower rescan.
    h.tower_served = false
    local tier = housing.TIERS[h.kind]
    local stock, inv = M.house_stock(h)
    -- A stocked water tower within RADIUS pours straight into the house, ahead of the hall stock: the
    -- bottles never wait on a hauler (#96). Inject before `step` so the carry maths stays honest.
    if towers then
      local mouths_ = mouths[i] or 0
      if mouths_ > 0 then
        local occ_idx
        for _, need in ipairs(tier.needs) do
          if need.id == "water" then
            for j, opt in ipairs(need.options) do
              if opt.item == "colony-water" then occ_idx = j; break end
            end
            break
          end
        end
        if occ_idx then
          local per = 0
          for _, need in ipairs(tier.needs) do
            if need.id == "water" then
              for _, opt in ipairs(need.options) do if opt.item == "colony-water" then per = opt.per end end
              break
            end
          end
          local owed = ((h.acc and h.acc.water or 0) + mouths_ * per)
          local want = math.floor(owed + 1e-9)
          if want > 0 then
            local from = {}
            local got = tower_model.take(towers, h.entity.position, want, from)
            if got > 0 then
              -- Only a house that actually drank from the tower is marked served: `step` consumes exactly what
              -- was poured, leaving its own shelf empty, so the haul planner must skip the water need (#D1).
              h.tower_served = true
              for j, n in pairs(from) do
                local tinv = towers[j].entity.get_inventory(defines.inventory.crafter_output)
                if tinv then tinv.remove({name = "colony-water", count = n}) end
              end
              inv.insert({name = "colony-water", count = got})
              stock["colony-water"] = (stock["colony-water"] or 0) + got
            end
          end
        end
      end
    end
    local consumed, sat, score, crit = housing.step(tier, mouths[i], stock, M.is_powered(h), h.acc)
    h.stock_tick = nil   -- the shelves just changed: status lines must not read the old snapshot
    h.crit_unmet = crit
    if occ[i] > 0 and illness.rotten_meal(inv, consumed, MEAL_SET) then rotten[h.entity.unit_number] = true end
    for item, n in pairs(consumed) do if n > 0 then inv.remove{name = item, count = n}; stats.consumed(colony, item, n) end end
    h.score, h.sat, h.occupants = score, sat, occ[i]
    if occ[i] > 0 then
      if crit then
        -- Emergency pantry pull (#expectation): if house shelves are empty, colonists fetch critical food/supplies
        -- from central stock (Town Hall / Warehouses) so they never starve in bed while the Town Hall has supplies.
        local still_crit = false
        for _, need in ipairs(tier.needs) do
          if need.critical and not sat[need.id] then
            local met_need = false
            for _, opt in ipairs(need.options) do
              if opt.item and M.stock_count(colony, opt.item) > 0 then
                local want = math.max(1, math.ceil(mouths[i] * (opt.per or 1)))
                local taken = M.take_stock(colony, opt.item, want)
                if taken > 0 then
                  stats.consumed(colony, opt.item, taken)
                  met_need = true
                  sat[need.id] = true
                  break
                end
              end
            end
            if not met_need then still_crit = true end
          end
        end
        crit = still_crit
        h.crit_unmet = crit
        if not crit then
          local met = 0
          for _, n in ipairs(tier.needs) do if sat[n.id] then met = met + 1 end end
          score = #tier.needs > 0 and (met / #tier.needs) or 1
          h.score = score
        end
      end

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
  -- Natural reproduction (#88): an opposite-sex pair in one house, provisions met, a free bed, birth cooldown.
  for i, h in ipairs(houses) do
    local members = split[i]
    if members and #members > 0 then
      local tier = housing.TIERS[h.kind]
      local tick = game.tick
      local states = {}
      for _, un in ipairs(members) do
        local rec = storage.age and storage.age[un]
        states[#states + 1] = {sex = breeding.sex_of(un), stage = (rec and rec.stage) or "adult"}
      end
      local ok = breeding.eligible(states, h.crit_unmet, tier.capacity - occ[i], tick, h.breed_ready)
      if ok and breeding.roll_birth(h.entity.unit_number, tick, 3) then
        local child = spawn_colonist(colony, h.entity.position, true)
        if child then h.breed_ready = tick + breeding.COOLDOWN_TICKS end
      end
    end
  end
  -- Children grow up (#88): at CHILD_TICKS they become ordinary colonists and join the workforce.
  if storage.age and colony.colonists then
    local grown = {}
    for un in pairs(colony.colonists) do
      local rec = storage.age[un]
      if rec and rec.stage == "child" and game.tick >= (rec.born or 0) + breeding.CHILD_TICKS then
        grown[#grown + 1] = un
      end
    end
    table.sort(grown)
    for _, un in ipairs(grown) do
      storage.age[un].stage = "adult"
      local g = colony.colonists[un]
      if g and g.valid then
        rendering.draw_text{text = {"colony-message.grew-up"}, surface = g.surface,
          target = {entity = g, offset = {0, -2}}, color = {1, 1, 0.8}, scale = 0.9,
          alignment = "center", time_to_live = 150}
        work.assign(colony, un)
      end
    end
  end
  colony.recreation = M.serve_taverns(colony, houses, occ)
  M.serve_theatres(colony, houses, occ)   -- #48 slice B: may raise recreation and inspiration quality in place
  M.compute_inspiration(colony, split, houses)
  illness.evaluate(colony, rotten)
  local kept = {}
  for _, a in ipairs(colony.deaths) do if a < 40 then kept[#kept + 1] = a + 1 end end
  colony.deaths = kept

  pop = M.live_colonists(colony)
  if (colony.scenic_n or 0) <= 0 then
    sample_scenic(colony)
    refresh_specialization(colony)
    colony.scenic_n = M.SCENIC_EVERY
  else colony.scenic_n = colony.scenic_n - 1 end
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local pollution = scenic.pollution_ratio(colony.hall.surface.get_pollution(colony.hall.position))
  colony.pollution = pollution
  local tents = 0
  for _, h in ipairs(houses) do if h.kind == "tent" then tents = tents + 1 end end
  local open_jobs = 0
  for _, hut in pairs(colony.huts or {}) do
    if hut.entity and hut.entity.valid then
      local _, _, allowed, workers = work.hut_info(hut)
      open_jobs = open_jobs + math.max((allowed or 0) - (workers or 0), 0)
    end
  end
  local privacy = 1           -- houses want to be empty or hold a single colonist (#88)
  if #houses > 0 then
    local sum = 0
    for i = 1, #houses do sum = sum + (occ[i] == 0 and 1 or 1 / occ[i]) end
    privacy = sum / #houses
  end
  -- Commute (#93): the mean walk from a colonist's house to the hut they work at. Only workers count, so a
  -- town with nothing to do scores 0 (no bonus, never a penalty). Unit numbers are sorted before summing
  -- because float addition is order-sensitive and two runs of the same save must agree to the last bit.
  local work_walk = 0
  do
    local units = {}
    for un, c in pairs(colony.colonists or {}) do
      local st = storage.unit_state and storage.unit_state[un]
      local hut = st and st.hut
      if c.valid and hut and hut.entity and hut.entity.valid then units[#units + 1] = un end
    end
    table.sort(units)
    local sum, n = 0, 0
    for _, un in ipairs(units) do
      local home = M.house_of_colonist(colony, un)
      local hut = storage.unit_state[un].hut
      if home and home.valid then
        local a, b = home.position, hut.entity.position
        local dx, dy = a.x - b.x, a.y - b.y
        sum = sum + math.sqrt(dx * dx + dy * dy)
        n = n + 1
      end
    end
    if n > 0 then work_walk = desirability.commute_score(sum / n) end
  end
  colony.commute = work_walk
  local d, parts = desirability.compute({
    food_ratio = M.total_food(colony) / target,
    free_housing_ratio = capacity > 0 and math.max(capacity - pop - (colony.away or 0), 0) / capacity or 0,
    scenic = colony.scenic or 0, leisure = rated > 0 and score_sum / rated or 0, recreation = colony.recreation or 0,
    pollution = pollution, deaths = colony.deaths,
    sickness = pop > 0 and (colony.sick_count or 0) / pop or 0,
    tents = tents, open_jobs = open_jobs, privacy = privacy, commute = work_walk,
    tourism = colony.insights or 0, hospitality = #tourism.here(colony),
    death_halflife = mortality_model.halflife(desirability.defaults.death_halflife, #M.cemetery_list(colony) > 0),
  })
  colony.d, colony.d_parts = d, parts
  -- Migrants are the bootstrap mechanism: brisk arrivals while the colony is small, then five times slower
  -- once it can sustain itself. (One lone settler cannot keep a house stocked for long, and a colony that can
  -- never refill starves: migration is for starting out, breeding is the long-term growth, #88.)
  local bootstrap = pop < M.BOOTSTRAP_SETTLERS
  if colony.accept_migrants ~= false and d > desirability.defaults.migrate_in and pop + (colony.away or 0) < capacity
      and (M.total_food(colony) > 0 or pop == 0)
      and (bootstrap or game.tick >= (colony.next_migrant or 0)) then
    local c = spawn_colonist(colony)
    if c then
      colony.next_migrant = game.tick + M.interval() * 5
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
  -- #51: live_colonists already excludes Spa visitors, so they must NOT be subtracted again here (doing so
  -- under-reports homeless residents on a host that has visitors, and the #49 rail departure never fires).
  local homeless = M.live_colonists(colony) - #commute.here(colony) - M.capacity(colony) - transit.waiting_count(colony)
  if homeless > 0 then transit.depart(colony, 0, homeless) end
  commute.evaluate(colony)
  tourism.evaluate(colony)
  M.check_milestones(colony.hall.force)
  feedback.ensure(colony)
  -- Sleepers whose individual check was lost (save/load mid-walk) are woken here. Idle colonists already
  -- re-assign themselves on their `work.retry` timer, so walking the whole town here would double the
  -- assignment rate - and this loop runs for every colonist every evaluation (#22 caught the cost).
  -- The idle nudge is therefore a rotating batch (`WAKE_LIMIT_EVAL`), not a sweep: the retry timer is the
  -- guarantee, this only stops a returning colonist waiting out the full backoff.
  if not work.is_sleep_time(colony.hall.surface) then
    for un, c in pairs(colony.colonists or {}) do
      local st = storage.unit_state and storage.unit_state[un]
      if c.valid and st and (st.state == "sleeping" or st.state == "to_bed") then
        work.wake_up(colony, un, c)
      end
    end
    work.wake_idle_colonists(colony, nil, work.WAKE_LIMIT_EVAL)
  end
  -- Inspired research (#48 slice A): one idempotent pass over the force's colonies per evaluation. Uses the
  -- `colony.inspiration` cache computed above; no per-tick scan and no new storage schema.
  research_speed.apply(colony.hall.force)
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

-- A fresh colony record. Shared by Hall and founding-dome builds so both cores start with identical state;
-- only the core entity (`hall`, which may be a dome) and the `domes` registry differ. `hall_un`/`hall_force` are
-- plain data so the death handler can tell whether the core itself died and which force may inherit it,
-- without reading an entity that may already have been pruned from the house registry.
local function new_colony(id, e)
  return {id = id, surface_index = e.surface.index, hall = e, hall_un = e.unit_number, hall_force = e.force.name,
    houses = {}, machines = {}, huts = {},
    towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, armories = {},
    patrol_posts = {}, patrols = {},   -- M3 Stage 3 (#57): waypoint records and active patrol leases (schema 41)
    pools = {}, taverns = {}, theatres = {}, plazas = {}, plaza_count = 0, platforms = {}, spas = {}, insights = 0, insights_total = 0, last_insight_tick = 0,
    cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, overflow = {}, ratings = {},
    colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, storage_priority = 3}
end

-- Register a colony house (kind from M.HOUSES). Extracted from the generic house branch in on_built so a
-- Habitat Dome core can be a house too without that branch ever seeing a core entity.
local function register_house(colony, e, kind)
  local h = {entity = e, kind = kind, acc = {}, inflight = {}, logistics_enabled = true, priority = 3}
  if housing.needs_power(housing.TIERS[kind]) then
    h.sink = e.surface.create_entity{name = "colony-power-sink", position = e.position, force = e.force}
  end
  colony.houses[e.unit_number] = h
  script.register_on_object_destroyed(e)
end

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
      if not planet.may_build_hall(e.surface) then
        refund(ev, e, M.HALL, {"colony-message.core-hostile-hall"})
        e.destroy()
        return
      end
    elseif name == M.DOME then
      -- A Habitat Dome may found a colony (no owner) or extend one (has an owner); only the surface rule gates it.
      if not planet.may_found(e.surface, M.DOME) then
        refund(ev, e, M.DOME, {"colony-message.core-hostile-hall"})
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
    elseif (M.CRATES[name] or name == M.COMPOST_BIN or name == M.SALT_PAN or name == M.WELL or name == M.WATER_TOWER or name == M.MOTOR_POOL or name == M.TAVERN or name == M.THEATRE or name == M.PLAZA or name == M.PLATFORM or name == M.CEMETERY or name == M.CANTEEN or name == M.SPA or name == M.LEDGER or M.HOUSES[name] or labour.HUTS[name]) and not core.is_core(name) then
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
    local owner = territory.owner_at(e.surface.index, e.position)
    if owner then
      local colony = storage.colonies[owner]
      if colony and e.ghost_prototype and #construct.cost(e.ghost_prototype.items_to_place_this) > 0 then
        local gk = e.surface.index .. ":" .. e.position.x .. "," .. e.position.y
        colony.ghosts = colony.ghosts or {}
        colony.ghosts[gk] = e
        work.wake_idle_colonists(colony)
      end
    end
    return
  end

  if core.is_core(name) then
    -- A core may only be founded where its prototype can live: a plain Hall needs a life-friendly surface,
    -- while a Habitat Dome is the pressurized core hostile worlds and space platforms need.
    if not planet.may_found(e.surface, name) or (name == M.HALL and not planet.may_build_hall(e.surface)) then
      refund(ev, e, name, {"colony-message.core-hostile-hall"})
      e.destroy()
      return
    end
    if name == M.HALL then
      local owner = territory.owner_at(e.surface.index, e.position)
      if owner then refund(ev, e, name, {"colony-message.hall-too-close"}); e.destroy(); return end   -- no overlapping halls
      local id = storage.next_colony_id; storage.next_colony_id = id + 1
      local colony = new_colony(id, e)
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
    else
      -- Habitat Dome (#63): no owner -> FOUND a colony whose core (`colony.hall`) is the dome itself; with an
      -- owner -> a second territory emitter and a house of that colony (no new colony, no numeric id change).
      local owner = territory.owner_at(e.surface.index, e.position)
      if owner then
        local colony = storage.colonies[owner]
        -- #63 review: a second emitter joins an existing town, so it must belong to that town's force. The
        -- plain `hall_force` is authoritative; the live hall (if any) is only a fallback for an old save.
        local live_force = colony.hall and colony.hall.valid and colony.hall.force and colony.hall.force.name
        if e.force.name ~= colony.hall_force and e.force.name ~= live_force then
          refund(ev, e, M.DOME, {"colony-message.outside-territory"})
          e.destroy()
          return
        end
        colony.domes = colony.domes or {}
        colony.domes[e.unit_number] = {entity = e, colony_id = colony.id}
        register_house(colony, e, "dome")
        colony.forage_seeded = nil   -- the dome claims new chunks; seed them once (no-op on bare platforms)
        M.seed_forage(colony)
        rendering.draw_circle{color = {0.1, 0.4, 0.15, 0.5}, width = 2, filled = false, radius = territory.DOME_RADIUS,
          target = e, surface = e.surface, only_in_alt_mode = true}
        M.refresh_all_cursor_overlays()
      else
        local id = storage.next_colony_id; storage.next_colony_id = id + 1
        local colony = new_colony(id, e)
        colony.domes = {[e.unit_number] = {entity = e, colony_id = id}}
        storage.colonies[id] = colony
        register_house(colony, e, "dome")
        M.seed_forage(colony)   -- no forage tiles on a platform; a plain no-op there
        local founder = ev.player_index and game.get_player(ev.player_index)
        if founder then founder.create_local_flying_text{text = {"colony-message.colony-founded"}, position = e.position} end
        e.force.print({"colony-message.colony-founded-hint", gps(e)})
        M.check_milestones(e.force)
        feedback.ensure(colony)
        rendering.draw_circle{color = {0.1, 0.4, 0.15, 0.5}, width = 2, filled = false, radius = territory.DOME_RADIUS,
          target = e, surface = e.surface, only_in_alt_mode = true}
        scheduler.after(M.interval(), "colony.evaluate", {colony_id = id})
        scheduler.after(construct.SCAN_TICKS, "construct.scan", {colony_id = id})   -- #37 ghosts + damage
        scheduler.after(work.MACHINE_SWEEP_TICKS, "work.machine_sweep", {colony_id = id})   -- #75 machine output
        M.refresh_all_cursor_overlays()
      end
    end
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
    -- A Watchtower doubles as a tooled guard post (#56): the rifles in its stock room open the posts. It is
    -- registered unmanned (limit 0) until the player mans it; labour.HUTS makes the limit buttons work as-is.
    if not colony.huts[e.unit_number] then
      colony.huts[e.unit_number] = {entity = e, job = "guard", colony_id = colony.id,
        workers = {}, inflight = {}, wear = 0, limit = 0, logistics_enabled = true, priority = 3}
    end
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
    local kind = M.CRATES[name]
    colony.crates[e.unit_number] = {entity = e, kind = kind, colony_id = colony.id,
      filters = {}, inflight = {}, logistics_enabled = true,
      priority = 3,
      accept_all = ((kind == crates.WAREHOUSE or kind == crates.HAUL_STATION or kind == crates.REFRIGERATOR) and true or nil),
      trailer_wear = 0, trailers_out = 0}
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
  elseif name == M.ARMORY then
    -- Armory (#56 remainder): a worker-free gear depot. Default limit 0 = inert; a player mans it in the
    -- docked panel, at which point haulers fill its chest and militia equip from it, claiming posts as they go.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    armory.register(storage.colonies[owner], e, dict)
    rendering.draw_circle{color = {0.75, 0.35, 0.2, 0.5}, width = 2, filled = false,
      radius = armory.EQUIP_RANGE, target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
  elseif name == M.PATROL_POST then
    -- Patrol Post (#57): a 2x2 waypoint marker, built inside territory. The waypoints themselves are plain
    -- data on colony.patrol_posts (schema [41]); idle militia are recruited onto the ordered route by a
    -- staggered patrol.dispatch timer, never by a per-tick scan.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    patrol.register_post(storage.colonies[owner], e, dict)
  elseif name == M.WATER_TOWER then
    -- Water Tower (#96): a worker-free assembler with a locked recipe (the bottling recipe). It bottles the
    -- fluid water the player pipes in and hands it straight to the houses around it at evaluation time, so no
    -- hauler ever makes the drinking-water run. No per-building state to persist; blueprint revival is plain.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.water_towers = colony.water_towers or {}
    colony.water_towers[e.unit_number] = {entity = e, colony_id = colony.id}
    script.register_on_object_destroyed(e)
  elseif name == M.LEDGER then
    -- Colony Ledger (#92): a constant combinator the colony writes. It has no worker and no inventory, so
    -- the registry record only carries the entity and the publish mode (blueprint tags restore the mode).
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    ledger_signal.register(storage.colonies[owner], e, dict)
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
  elseif name == M.SPA then
    -- Spa (#51): a worker-free 2-visitor amenity. Built inside territory like every other colony building;
    -- it has no inventory logic and no per-tick work, it only gives this town a place to host tourists.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.spas = colony.spas or {}
    colony.spas[e.unit_number] = {entity = e, colony_id = colony.id}
    rendering.draw_circle{color = {0.8, 0.5, 0.85, 0.5}, width = 2, filled = false, radius = 24,
      target = e, surface = e.surface, only_in_alt_mode = true}
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
  elseif name == M.THEATRE then
    -- Theatre (#48 slice B): no workers, no ale, no hauling - its 16-tile ring Inspires houses at quality 1.5.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.theatres = colony.theatres or {}
    colony.theatres[e.unit_number] = {entity = e, colony_id = colony.id, houses = 0, inspired = 0}
    rendering.draw_circle{color = {0.95, 0.45, 0.75, 0.5}, width = 2, filled = false, radius = theatre.RADIUS,
      target = e, surface = e.surface, only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
  elseif name == M.PLAZA then
    -- Scenic Plaza (#48 slice B): free decoration. It only joins the hall's four-evaluation scenic sample.
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.plazas = colony.plazas or {}
    colony.plazas[e.unit_number] = {entity = e, colony_id = colony.id}
    script.register_on_object_destroyed(e)
  elseif (M.HOUSES[name] or labour.HUTS[name]) and not core.is_core(name) then
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
      local default_priority = (name == "colony-toolsmith") and 2 or 3
      local hut = {entity = e, job = labour.HUTS[name].job, colony_id = colony.id, workers = {}, inflight = {}, wear = 0,
        logistics_enabled = true, priority = default_priority}
      if hut.job == "research" then
        e.custom_status = {
          diode = defines.entity_status_diode.red,
          label = {"colony-gui-hut.lab-unstaffed"}
        }
      end
      colony.huts[e.unit_number] = hut
      script.register_on_object_destroyed(e)
      local r = (hut.job == "forage" and M.FORAGE_RADIUS)
        or (hut.job == "forest" and forest.RADIUS)
        or M.HUT_RADIUS
      rendering.draw_circle{color = {0.45, 0.45, 0.15, 0.5}, width = 2, filled = false, radius = r,
        target = e, surface = e.surface, only_in_alt_mode = true}
      return
    end
    register_house(colony, e, M.HOUSES[name])
  elseif dict and gui.MACHINE_GUIS[e.type] then
    -- A machine carries no colony prototype of ours, so only a blueprint tags can say it was opted in.
    local colony = M.colony_of(e)
    if colony then M.apply_tags(colony, e, dict) end
  end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)
-- #63: platform construction robots raise this event (scripted builds do not, per s23). on_built already
-- reads `ev.entity or ev.created_entity`, so the unproven field name needs no special adapter here.
events.on(defines.events.on_space_platform_built_entity, on_built)
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
  if not (item_name == M.WATCHTOWER or core.is_core(item_name) or M.HOUSES[item_name] or labour.HUTS[item_name]
      or M.CRATES[item_name] or item_name == M.COMPOST_BIN or item_name == M.SALT_PAN
      or item_name == M.WELL or item_name == M.WATER_TOWER or item_name == M.ARMORY or item_name == M.PATROL_POST or item_name == M.MOTOR_POOL or item_name == M.TAVERN or item_name == M.THEATRE or item_name == M.PLAZA or item_name == M.PLATFORM or item_name == M.CEMETERY or item_name == M.CANTEEN or item_name == M.SPA or item_name == M.PLOT) then return end

  local surface = player.surface
  local list = {}
  for _, colony in pairs(storage.colonies or {}) do
    if colony.surface_index == surface.index then
      if colony.hall and colony.hall.valid then
        local hall_radius = territory.core_radius(colony.hall.name) or territory.HALL_RADIUS
        local r_fill = rendering.draw_circle{
          color = {0.008, 0.032, 0.012, 0.04},   -- premultiplied: a faint wash, the terrain stays readable
          filled = true,
          radius = hall_radius,
          target = colony.hall,
          surface = surface,
          players = {player},
        }
        local r_border = rendering.draw_circle{
          color = {0.1, 0.4, 0.15, 0.5},
          width = 2,
          filled = false,
          radius = hall_radius,
          target = colony.hall,
          surface = surface,
          players = {player},
        }
        table.insert(list, r_fill)
        table.insert(list, r_border)
      end
      for _, d in ipairs(M.dome_list(colony)) do
        local dome = d.entity
        -- #63 review: the founding dome is also the core and was drawn above; emitters lists it twice by
        -- design (core + registry) and every consumer dedupes it.
        if dome and dome.valid and dome ~= colony.hall then
          local dome_radius = territory.core_radius(dome.name) or territory.DOME_RADIUS
          local r_fill = rendering.draw_circle{
            color = {0.008, 0.032, 0.012, 0.04},   -- premultiplied: a faint wash, the terrain stays readable
            filled = true,
            radius = dome_radius,
            target = dome,
            surface = surface,
            players = {player},
          }
          local r_border = rendering.draw_circle{
            color = {0.1, 0.4, 0.15, 0.5},
            width = 2,
            filled = false,
            radius = dome_radius,
            target = dome,
            surface = surface,
            players = {player},
          }
          table.insert(list, r_fill)
          table.insert(list, r_border)
        end
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
  -- #52 review finding 2: this event is deferred to the end of the tick, and crate_list prunes a dead crate
  -- record on the very next haul assignment. Unbind by unit number FIRST, independently of whether the
  -- crate registry record survived, or a mined half would leave a dead slot and a "taken" peer forever.
  if storage.links and next(storage.links) then M.unbind_link(un) end
  for _, colony in pairs(storage.colonies) do
    -- Habitat Domes (#63): a dome is both a territory emitter and a house, so handle it here before the
    -- generic house branch. Its death shrinks territory automatically (emitters skips invalid entities).
    -- The `hall_un` arm covers a dead core whose records were already pruned by dome_list/house_list earlier
    -- in the tick, before this deferred event fires.
    if (colony.domes and colony.domes[un]) or un == colony.hall_un then
      if colony.domes then colony.domes[un] = nil end
      local h = colony.houses and colony.houses[un]
      if h then
        if h.sink and h.sink.valid then h.sink.destroy() end
        colony.houses[un] = nil
      end
      if un == colony.hall_un then
        -- The core itself died. Keep the colony id alive by promoting the lowest-unit-number live dome on
        -- the same surface and force; never promote a non-dome. `hall_force` is a plain string captured at
        -- founding: the sink that used to name the force may already have been pruned by house_list, which
        -- would silently turn a LuaForce guard into "no guard at all". Otherwise leave the dead entity in
        -- `colony.hall` and let M.evaluate's dormancy path handle it.
        -- A hall-founded town that never built a dome has no `domes` table at all; its hall death still
        -- enters this branch now that hall_un is set for both core types, so the loop must be nil-safe.
        local next_core, next_un = nil, nil
        for dun, dr in pairs(colony.domes or {}) do
          local e = dr.entity
          if e and e.valid and e.name == M.DOME and e.surface.index == colony.surface_index
              and e.force and e.force.name == colony.hall_force and (not next_un or dun < next_un) then
            next_core, next_un = e, dun
          end
        end
        if next_core then
          colony.hall = next_core
          colony.hall_un = next_core.unit_number
        end
      end
      M.refresh_all_cursor_overlays()
      return
    end
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
    if colony.armories and colony.armories[un] then
      colony.armories[un] = nil   -- equipped claims die with the depot; gear already drawn stays with its owner
      return
    end
    if colony.water_towers and colony.water_towers[un] then
      colony.water_towers[un] = nil
      return
    end
    if colony.ledgers and colony.ledgers[un] then
      colony.ledgers[un] = nil   -- the timer chain notices there is nothing left to publish and stops
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
    if colony.theatres and colony.theatres[un] then
      colony.theatres[un] = nil
      return
    end
    if colony.plazas and colony.plazas[un] then
      colony.plazas[un] = nil
      return
    end
    if colony.canteens and colony.canteens[un] then
      colony.canteens[un] = nil
      return
    end
    if colony.spas and colony.spas[un] then
      colony.spas[un] = nil   -- tourists already visiting finish their stay; no new ones are wanted
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
      if colony.huts then colony.huts[un] = nil end
      M.refresh_all_cursor_overlays()
      return
    end
    if colony.plots and colony.plots[un] then
      colony.plots[un] = nil
      return
    end
    if colony.crates and colony.crates[un] then
      colony.crates[un] = nil   -- #52: the unbind already happened unconditionally at the top of this handler
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
    if colony.huts and colony.huts[un] then
      colony.huts[un] = nil
      return
    end
    if colony.machines and colony.machines[un] then
      colony.machines[un] = nil
      colony.machine_dirty = true
      return
    end
  end
end)

work.bind(M); gui.bind(M, ledger_signal); feedback.bind(M); transit.bind(M); mortality.bind(M); shelter.bind(M); commute.bind(M, transit); illness.bind(M)   -- avoids a require cycle (runtime require is illegal)
-- #51: the tourism adapter owns the trip's engine side; transit calls back into it on board/alight/loss.
tourism.bind(M, transit); transit.bind_tourism(tourism)
ledger_signal.bind(M)
-- M3 militia (#55): bind the combat adapter and hand it to work/command so they can delegate militia units
-- and preserve gear across whistle leases without a runtime require cycle.
militia.bind(M); work.bind_militia(militia); command.bind_militia(militia)
-- M3 Stage 3: the patrol adapter and the whistle's preemption hook (a manual order ends a patrol cleanly).
patrol.bind(M); command.bind_patrol(patrol); patrol.bind_militia(militia)
-- M3 Stage 2: the Armory depot/aura adapter and the single multiplexed damage handler (#56 + #61).
armory.bind(M); shelter.bind_armory(armory)

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
  local type = (e.type == "entity-ghost") and e.ghost_type or e.type
  -- An opted-in ammo-turret (#59) gets one row for the magazine it shoots. Unknown/modded names get no
  -- auto-row (the player sets one by hand), so a turret never changes town evolution unless opted in.
  if type == "ammo-turret" then
    local name = (e.type == "entity-ghost") and e.ghost_name or e.name
    return turret_model.default_request(name)
  end
  local recipe = (type == "assembling-machine" or type == "furnace")
    and (e.get_recipe() or (type == "furnace" and e.previous_recipe and e.previous_recipe.name
      and prototypes.recipe[e.previous_recipe.name]))
  if recipe then
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" and #out < M.REQUEST_ROWS then out[#out + 1] = {item = ing.name, count = math.max(ing.amount * 5, 5)} end
    end
  end
  return out
end

-- Defaults for a newly-created machine record (#59). Ordinary machines collect output at building priority
-- 4; ammo-turrets have no output inventory (never steal loaded magazines) and use priority 3 inside the
-- `request` band. Rules live in model/turret.lua; this just hands the adapter the two numbers it needs.
function M.machine_defaults(e)
  if e.type == "ammo-turret" then
    local d = turret_model.defaults(e.name)
    return d.collect, d.priority
  end
  return true, 4
end

function M.set_machine(colony, e, enabled)
  if not (colony and e and e.valid and e.type ~= "entity-ghost") then return nil end
  local m = colony.machines[e.unit_number]
  if enabled then
    if not m then
      local collect, priority = M.machine_defaults(e)
      m = {entity = e, requests = {}, collect = collect, inflight = {}, need = nil, has_output = nil,
        priority = priority}
    end
    m.entity = e
    m.enabled = true
    -- A record poisoned by an older save/tag cannot survive a re-enable (or the load-time rebadge, which
    -- calls back through here): a turret is never a provider, whatever its stored collect flag says.
    if e.type == "ammo-turret" then m.collect = false end
    m.need, m.has_output = nil, nil      -- the sweep rediscovers both within a pass
    colony.machines[e.unit_number] = m
    if next(m.requests) == nil then m.requests = M.default_requests(e) end
    colony.machine_dirty = true
    M.invalidate_demand(colony)          -- the new request changes what the whole chain wants (#90)
    script.register_on_object_destroyed(e)   -- so the registry (and the cached list) is pruned
    if not (m.badge and m.badge.valid) then
      m.badge = rendering.draw_sprite{sprite = M.BADGE_SPRITE, target = {entity = e, offset = {0, -1.3}},
        surface = e.surface, x_scale = 0.3, y_scale = 0.3, only_in_alt_mode = true}
    end
  elseif m then
    m.enabled = false
    m.need, m.has_output = nil, nil
    colony.machine_dirty = true
    M.invalidate_demand(colony)
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
      local batched = made - left            -- fertilizer that actually landed (bin full: the spoilage stays in the bin)
      if left > 0 then
        b.entity.insert{name = compost.SOURCE, count = left * compost.SPOILAGE_PER_FERTILIZER}
      end
      stats.consumed(colony, compost.SOURCE, batched * compost.SPOILAGE_PER_FERTILIZER)
      stats.produced(colony, compost.PRODUCT, batched)
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
  if un then
    for _, colony in pairs(storage.colonies) do
      local m = colony.machines and colony.machines[un]
      if m and m.enabled and m.entity.type ~= "entity-ghost" then return colony, "machine", m end
      local c = colony.crates and colony.crates[un]
      if c and c.entity.type ~= "entity-ghost" then return colony, "crate", c end
      local l = colony.ledgers and colony.ledgers[un]
      if l and l.entity.type ~= "entity-ghost" then return colony, "ledger", l end
    end
  end
  if e.type == "entity-ghost" and e.tags then
    local colony = M.colony_of(e)
    local payload = tags.decode(e.tags)
    if payload and payload.machine then
      return colony, "machine", payload.machine
    elseif payload and payload.crate then
      return colony, "crate", payload.crate
    elseif payload and payload.ledger then
      return colony, "ledger", payload.ledger
    end
  end
end

-- Tag dictionary to write into a blueprint for this entity, or nil if the colony does not serve it.
function M.entity_tags(e)
  local _, kind, rec = M.find_record(e)
  if kind == "machine" then return tags.dictionary(tags.machine(rec)) end
  if kind == "crate" then return tags.dictionary(tags.crate(rec)) end
  if kind == "ledger" then return tags.dictionary(tags.ledger(rec)) end
end

-- Copy rows out of a registry record into a fresh table: two machines must never share the same row list.
local function copy_rows(rows)
  local out = {}
  for row, r in pairs(rows or {}) do
    if r and r.item then out[row] = {item = r.item, count = r.count} end
  end
  return out
end

-- Restore settings a blueprint/copy carried. The payload is untrusted, so the model validates it.
function M.apply_tags(colony, e, dict)
  local payload = tags.decode(dict)
  if not (payload and colony and e and e.valid) then return false end
  local e_type = (e.type == "entity-ghost") and e.ghost_type or e.type
  local e_name = (e.type == "entity-ghost") and e.ghost_name or e.name
  if payload.machine then
    if not gui.MACHINE_GUIS[e_type] then return false end
    -- #59: the payload is untrusted. A forged tag (or a tag that merely omits `collect`, which tags.decode
    -- defaults to true) must never make an ammo-turret a provider: its "output inventory" is its ammo
    -- inventory, so haulers would strip the loaded rounds. The rule is pure, in model/turret.lua.
    local safe_collect = turret_model.safe_collect(e_type, payload.machine.collect)
    if e.type == "entity-ghost" then
      local m = {collect = safe_collect, requests = copy_rows(payload.machine.requests),
        priority = payload.machine.priority or turret_model.priority_default(e_type, 4)}
      e.tags = tags.dictionary(tags.machine(m))
      return true
    end
    local m = M.set_machine(colony, e, true)
    if not m then return false end
    m.collect, m.requests = safe_collect, copy_rows(payload.machine.requests)
    if payload.machine.priority then m.priority = payload.machine.priority
    elseif e_type == "ammo-turret" then m.priority = turret_model.DEFAULT_BUILDING_PRIORITY end
    m.need, m.has_output = nil, nil
    return true
  elseif payload.crate then
    if e.type == "entity-ghost" then
      local kind = M.CRATES[e_name]
      if kind then
        local c = {kind = kind, filters = copy_rows(payload.crate.filters),
                   accept_all = payload.crate.accept_all, priority = payload.crate.priority or 3,
                   logistics_enabled = true}
        if kind == crates.LINK then M.restore_link_fields(colony, c, nil, payload.crate.link) end
        e.tags = tags.dictionary(tags.crate(c))
        return true
      end
      return false
    end
    local c = colony.crates and colony.crates[e.unit_number]
    if not c then return false end
    c.filters = copy_rows(payload.crate.filters)
    if payload.crate.accept_all ~= nil then c.accept_all = payload.crate.accept_all end
    if payload.crate.priority then c.priority = payload.crate.priority end
    if c.kind == crates.LINK then M.restore_link_fields(colony, c, e.unit_number, payload.crate.link) end
    return true
  elseif payload.ledger then
    if e.type == "entity-ghost" then
      if e_name ~= M.LEDGER then return false end
      e.tags = tags.dictionary(tags.ledger(payload.ledger))
      return true
    end
    local rec = colony.ledgers and colony.ledgers[e.unit_number]
    if not rec then return false end
    -- Publish straight away so the wire flips on the same tick the blueprint lands.
    ledger_signal.set_mode(colony, rec, payload.ledger.mode)
    return true
  end
  return false
end

-- Copy the colony half of copy-paste. The engine copies the entity's own settings; the registry is ours, so
-- a plain (un-opted-in) source clears the destination rather than leaving it serving silently.
function M.copy_settings(src, dst)
  if not (src and src.valid and dst and dst.valid) then return false end
  local colony = M.colony_of(dst)
  if not colony then return false end
  local _, kind, rec = M.find_record(src)
  local dst_type = (dst.type == "entity-ghost") and dst.ghost_type or dst.type
  local dst_name = (dst.type == "entity-ghost") and dst.ghost_name or dst.name
  if dst_name == M.LEDGER then
    local mode = (kind == "ledger" and rec) and rec.mode or "stock"
    if dst.type == "entity-ghost" then
      dst.tags = tags.dictionary(tags.ledger({mode = mode}))
      return true
    end
    local drec = colony.ledgers and colony.ledgers[dst.unit_number]
    return drec and ledger_signal.set_mode(colony, drec, mode) or false
  end
  if gui.MACHINE_GUIS[dst_type] then
    -- #59: a turret's "output inventory" IS its ammo inventory, so collect=true would let haulers strip the
    -- rounds back out. Copying rows from another machine is fine; copying its collect/priority is not.
    local is_turret = (dst_type == "ammo-turret")
    if dst.type == "entity-ghost" then
      if kind == "machine" and rec then
        local m = {collect = is_turret and false or rec.collect, requests = copy_rows(rec.requests),
          priority = is_turret and turret_model.DEFAULT_BUILDING_PRIORITY or (rec.priority or 4)}
        dst.tags = tags.dictionary(tags.machine(m))
      else
        dst.tags = nil
      end
      return true
    end
    local m = M.set_machine(colony, dst, kind == "machine")
    if not m then return false end
    -- Not `x and y or z`: collect is a boolean, so that idiom turns a copied false back into true.
    if kind == "machine" and rec then
      m.collect, m.requests = rec.collect, copy_rows(rec.requests)
      if rec.priority ~= nil then m.priority = rec.priority end
    else
      m.collect, m.requests = true, {}
      m.priority = 4
    end
    if is_turret then
      m.collect = false                                    -- never a provider, whatever was copied
      m.priority = turret_model.DEFAULT_BUILDING_PRIORITY
    end
    m.need, m.has_output = nil, nil
    return true
  end
  local is_crate = (dst.type == "entity-ghost") and M.CRATES[dst_name] or (colony.crates and colony.crates[dst.unit_number])
  if is_crate then
    local src_link = (kind == "crate" and rec and rec.kind == crates.LINK)
      and {id = rec.link, role = rec.role} or nil
    if dst.type == "entity-ghost" then
      if kind == "crate" and rec then
        local c = {kind = M.CRATES[dst_name], filters = copy_rows(rec.filters),
                   accept_all = rec.accept_all, priority = rec.priority or 3, logistics_enabled = true}
        if M.CRATES[dst_name] == crates.LINK then M.restore_link_fields(colony, c, nil, src_link) end
        dst.tags = tags.dictionary(tags.crate(c))
      else
        dst.tags = nil
      end
      return true
    end
    local c = colony.crates and colony.crates[dst.unit_number]
    if c then
      c.filters = (kind == "crate" and rec) and copy_rows(rec.filters) or {}
      if kind == "crate" and rec then
        if rec.accept_all ~= nil then c.accept_all = rec.accept_all end
        if rec.priority ~= nil then c.priority = rec.priority end
      end
      if c.kind == crates.LINK then M.restore_link_fields(colony, c, dst.unit_number, src_link) end
      return true
    end
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
  local changed = false
  for _, name in ipairs(milestones.due(facts, researched)) do
    local t = force.technologies[name]
    if t then
      t.researched = true
      changed = true
      force.print({"colony-message.milestone", {"technology-name." .. name}, {"technology-description." .. name}})
    end
  end
  -- Setting `researched` from script is ours to make consistent: a milestone's unlock effects may not have been
  -- applied by the engine yet, and the same helper covers recipes added to an already-researched technology.
  if changed then tech.sync_force(force) end
end

-- Huts short of a tool, merged per tool and sorted: {{tool=, short=}}. A tool already on its way counts.
function M.tool_gaps(colony)
  local gaps = {}
  for _, h in pairs(colony.huts) do
    if h.entity.valid then
      local def, tools = work.hut_info(h)
      if def.tool then
        local inflight = 0
        if def.tools then
          for _, t in ipairs(def.tools) do inflight = inflight + (h.inflight[t] or 0) end
        else
          inflight = h.inflight[def.tool] or 0
        end
        local short = math.min(def.capacity, h.limit or def.capacity) - tools - inflight
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

function M.stats(colony)
  local pop = M.live_colonists(colony)
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local food = M.total_food(colony)
  local tents, cabins, homesteads, townhouses, apartments, arcologies = 0, 0, 0, 0, 0, 0
  for _, h in ipairs(M.house_list(colony)) do
    if h.kind == "tent" then tents = tents + 1
    elseif h.kind == "cabin" then cabins = cabins + 1
    elseif h.kind == "homestead" then homesteads = homesteads + 1
    elseif h.kind == "townhouse" then townhouses = townhouses + 1
    elseif h.kind == "apartment" then apartments = apartments + 1
    elseif h.kind == "arcology" then arcologies = arcologies + 1
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
    tents = tents, cabins = cabins, homesteads = homesteads, townhouses = townhouses, apartments = apartments,
    arcologies = arcologies, domes = #M.dome_list(colony),
    huts = huts, machines = machines, towers = towers, chunks = chunks,
    crates = #M.crate_list(colony), ghosts = ghosts, damaged = damaged,
    d = colony.d or 0, parts = colony.d_parts or {},
    scenic = colony.scenic or 0, pollution = colony.pollution or 0,
    fallen = colony.fallen or 0, buried = colony.buried or 0,
    away = colony.away or 0, commuters_here = #commute.here(colony),
    insights = colony.insights or 0, insights_total = colony.insights_total or 0, visitors = #tourism.here(colony),
    sick = colony.sick_count or 0, sick_lung = colony.sick_lung or 0, sick_poison = colony.sick_poison or 0,
    sick_swamp_fever = colony.sick_swamp_fever or 0}
end

return M
