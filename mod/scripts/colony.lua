-- Colony adapter (#24 #25 #28 #29): Town Hall claims territory, housing is territory-restricted,
-- periodic evaluation (scheduler, not per-tick) computes desirability and spawns migrants.
-- Rules live in scripts.model.*; this file only talks to the engine.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local farm = require("scripts.model.farm")
local desirability = require("scripts.model.desirability")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local work = require("scripts.work")
local gui = require("scripts.gui")
local M = {}

M.HALL = "colony-town-hall"
M.WATCHTOWER = "colony-watchtower"
M.PLOT = "colony-farm-plot"
M.TOWER_RADIUS = 1              -- chunks a watchtower claims around itself (design §2.1)
M.HUT_RADIUS = 30               -- working radius around a labour hut (harvesting also needs territory)
M.REGROW_TICKS = 2400           -- a harvested forage patch grows back in place after this long...
M.REGROW_JITTER = 1800          -- ...plus up to this much, so a grove does not regrow in lockstep
M.FORAGE_PER_CHUNK = 3          -- natural forage patches seeded per already-generated territory chunk
M.FORAGE_TILES = {["grass-1"] = true, ["grass-2"] = true, ["grass-3"] = true, ["grass-4"] = true}
M.HOUSES = {["colony-housing-tent"] = "tent", ["colony-housing-cabin"] = "cabin"}
M.CLAIM_RADIUS = 1              -- chunks, Chebyshev => 3x3 chunks
M.STARVE_AFTER = 4              -- consecutive evaluations with unmet critical need before a colonist dies
M.POWERED_ENERGY = 10000        -- J in the hidden sink buffer that counts as 'powered'
M.FOOD_PER_COLONIST = 1         -- food items per interval
M.FOOD_ITEMS = {"colony-forage", "colony-produce", "raw-fish", "yumako", "jellynut", "bioflux", "yumako-mash", "jelly"}
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

function M.food_in(colony)
  local hall = colony.hall
  if not (hall and hall.valid) then return 0 end
  local n = 0
  for _, item in ipairs(M.FOOD_ITEMS) do
    if prototypes.item[item] then n = n + hall.get_item_count(item) end
  end
  return n
end

function M.live_colonists(colony)
  local n = 0
  for id, c in pairs(colony.colonists) do
    if c.valid then n = n + 1 else colony.colonists[id] = nil end
  end
  return n
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

function M.is_powered(h)
  return h.sink ~= nil and h.sink.valid and h.sink.energy >= M.POWERED_ENERGY
end

-- Total food on hand (hall + house buffers); used by work planning and desirability.
function M.total_food(colony)
  local n = M.food_in(colony)
  for _, h in ipairs(M.house_list(colony)) do
    local stock = M.house_stock(h)
    for _, opt in ipairs(housing.FOOD) do n = n + (stock[opt.item] or 0) end
  end
  return n
end

local function kill_one(colony)
  for id, c in pairs(colony.colonists) do
    if c.valid then c.die(); colony.colonists[id] = nil; table.insert(colony.deaths, 0); return true end
  end
  return false
end

local function spawn_colonist(colony)
  local hall = colony.hall
  local pos = hall.surface.find_non_colliding_position("colony-colonist", hall.position, 10, 0.5)
  if not pos then return false end
  local c = hall.surface.create_entity{name = "colony-colonist", position = pos, force = hall.force}
  if not c then return false end
  colony.colonists[c.unit_number] = c
  script.register_on_object_destroyed(c)
  work.assign(colony, c.unit_number)
  return true
end

function M.evaluate(data)
  local colony = storage.colonies[data.colony_id]
  if not colony then return end
  if not colony.hall.valid then return end    -- hall gone; colony dormant
  scheduler.after(M.interval(), "colony.evaluate", data)

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
    for item, n in pairs(consumed) do if n > 0 then inv.remove{name = item, count = n} end end
    h.score, h.sat, h.occupants = score, sat, occ[i]
    if occ[i] > 0 then
      score_sum = score_sum + score; rated = rated + 1
      if crit then
        h.hungry = (h.hungry or 0) + 1
        if h.hungry >= M.STARVE_AFTER then kill_one(colony); h.hungry = 0 end
      else h.hungry = 0 end
    end
  end
  local kept = {}
  for _, a in ipairs(colony.deaths) do if a < 40 then kept[#kept + 1] = a + 1 end end
  colony.deaths = kept

  pop = M.live_colonists(colony)
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local d, parts = desirability.compute({
    food_ratio = M.total_food(colony) / target,
    free_housing_ratio = capacity > 0 and (capacity - pop) / capacity or 0,
    scenic = 0.3, leisure = rated > 0 and score_sum / rated or 0, pollution = 0, deaths = colony.deaths,
  })
  colony.d, colony.d_parts = d, parts
  local pop_target = math.min(capacity, colony.pop_target or capacity)
  if colony.accept_migrants ~= false and d > desirability.defaults.migrate_in and pop < pop_target then
    if spawn_colonist(colony) and settings.global["colony-debug-log"].value then
      game.print("[colony " .. colony.id .. "] migrant arrived, D=" .. string.format("%.2f", d))
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
  for cx, col in pairs(storage.colony_chunks[colony.surface_index] or {}) do
    for cy, owner in pairs(col) do
      if owner == colony.id and s.is_chunk_generated({x = cx, y = cy}) then
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
  if name == M.HALL and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    if owner then refund(ev, e, name); e.destroy(); return end   -- no overlapping halls
    local id = storage.next_colony_id; storage.next_colony_id = id + 1
    local colony = {id = id, surface_index = e.surface.index, hall = e, houses = {}, machines = {}, huts = {},
      towers = {}, colonists = {}, deaths = {}, claimed = {}, no_site = {}}
    storage.colonies[id] = colony
    territory.claim_around(e.surface.index, id, e.position, M.CLAIM_RADIUS)
    M.seed_forage(colony)   -- the claimed land already has berries on it
    local cx, cy = territory.chunk_of(e.position)
    rendering.draw_rectangle{color = {0.2, 0.8, 0.3, 0.8}, width = 3, filled = false, surface = e.surface,
      left_top = {(cx - M.CLAIM_RADIUS) * 32, (cy - M.CLAIM_RADIUS) * 32},
      right_bottom = {(cx + M.CLAIM_RADIUS + 1) * 32, (cy + M.CLAIM_RADIUS + 1) * 32}}
    script.register_on_object_destroyed(e)
    scheduler.after(M.interval(), "colony.evaluate", {colony_id = id})
  elseif name == M.PLOT and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    local tile = e.surface.get_tile(e.position)
    if not owner or not farm.plantable(tile.name) then
      refund(ev, e, name, owner and {"colony-message.bad-farmland"} or nil)
      e.destroy()
      return
    end
    local colony = storage.colonies[owner]
    colony.plots = colony.plots or {}
    colony.plots[e.unit_number] = {entity = e, colony_id = colony.id, stage = farm.FALLOW}
    e.graphics_variation = farm.FALLOW
    script.register_on_object_destroyed(e)
  elseif name == M.WATCHTOWER and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    colony.towers[e.unit_number] = e
    territory.claim_around(e.surface.index, colony.id, e.position, M.TOWER_RADIUS)
    local cx, cy = territory.chunk_of(e.position)
    rendering.draw_rectangle{color = {0.2, 0.8, 0.3, 0.6}, width = 2, filled = false, surface = e.surface,
      left_top = {(cx - M.TOWER_RADIUS) * 32, (cy - M.TOWER_RADIUS) * 32},
      right_bottom = {(cx + M.TOWER_RADIUS + 1) * 32, (cy + M.TOWER_RADIUS + 1) * 32},
      only_in_alt_mode = true}
    script.register_on_object_destroyed(e)
  elseif (M.HOUSES[name] or labour.HUTS[name]) and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    local colony = storage.colonies[owner]
    if labour.HUTS[name] then
      local hut = {entity = e, job = labour.HUTS[name].job, colony_id = colony.id, workers = {}, inflight = {}, wear = 0}
      colony.huts[e.unit_number] = hut
      rendering.draw_circle{color = {0.9, 0.9, 0.3, 0.5}, width = 2, filled = false, radius = M.HUT_RADIUS,
        target = e, surface = e.surface, only_in_alt_mode = true}
      return
    end
    local h = {entity = e, kind = M.HOUSES[name], acc = {}, inflight = {}}
    if housing.needs_power(housing.TIERS[h.kind]) then
      h.sink = e.surface.create_entity{name = "colony-power-sink", position = e.position, force = e.force}
    end
    colony.houses[e.unit_number] = h
  end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)
events.on(defines.events.script_raised_built, on_built)
events.on(defines.events.script_raised_revive, on_built)

-- A watchtower's claim is re-derived when it is destroyed, so removing one shrinks the territory back to
-- what the hall and the remaining towers cover instead of leaving orphaned chunks owned forever.
function M.recompute_territory(colony)
  territory.release_colony(colony.id)
  if colony.hall.valid then
    territory.claim_around(colony.surface_index, colony.id, colony.hall.position, M.CLAIM_RADIUS)
  end
  for _, t in pairs(colony.towers or {}) do
    if t.valid then territory.claim_around(colony.surface_index, colony.id, t.position, M.TOWER_RADIUS) end
  end
end

events.on(defines.events.on_object_destroyed, function(ev)
  local un = ev.useful_id
  if not un then return end
  for _, colony in pairs(storage.colonies) do
    if colony.towers and colony.towers[un] then
      colony.towers[un] = nil
      M.recompute_territory(colony)
      return
    end
    if colony.plots and colony.plots[un] then
      colony.plots[un] = nil
      return
    end
  end
end)

work.bind(M); gui.bind(M)   -- avoids a require cycle (runtime require is illegal)

-- ---------- opt-in machine registry (#34) ----------
-- The badge is alt-mode only: a small Town Hall icon over every machine the colony serves, so the player
-- can see coverage without opening each one. Rendering objects whose entity target is destroyed are
-- destroyed by the engine, so no cleanup is needed when a machine is mined.
M.BADGE_SPRITE = "entity/colony-town-hall"   -- SpritePath: the Town Hall's icon

function M.set_machine(colony, e, enabled)
  local m = colony.machines[e.unit_number]
  if enabled then
    m = m or {entity = e, requests = {}, collect = true, inflight = {}}
    m.entity = e
    m.enabled = true
    colony.machines[e.unit_number] = m
    if not (m.badge and m.badge.valid) then
      m.badge = rendering.draw_sprite{sprite = M.BADGE_SPRITE, target = {entity = e, offset = {0, -1.3}},
        surface = e.surface, x_scale = 0.3, y_scale = 0.3, only_in_alt_mode = true}
    end
  elseif m then
    m.enabled = false
    if m.badge and m.badge.valid then m.badge.destroy() end
    m.badge = nil
  end
  return m
end

-- Colony overview for the Town Hall panel (#38). Plain data, computed on demand (GUI refresh only).
function M.stats(colony)
  local pop = M.live_colonists(colony)
  local capacity = M.capacity(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local food = M.total_food(colony)
  local tents, cabins = 0, 0
  for _, h in ipairs(M.house_list(colony)) do
    if h.kind == "tent" then tents = tents + 1 else cabins = cabins + 1 end
  end
  local chunks = 0
  for _, col in pairs(storage.colony_chunks[colony.surface_index] or {}) do
    for _, owner in pairs(col) do if owner == colony.id then chunks = chunks + 1 end end
  end
  local huts, machines = 0, 0
  for _, h in pairs(colony.huts) do if h.entity.valid then huts = huts + 1 end end
  for _, m in pairs(colony.machines) do if m.enabled and m.entity.valid then machines = machines + 1 end end
  local towers = 0
  for _, t in pairs(colony.towers or {}) do if t.valid then towers = towers + 1 end end
  return {pop = pop, capacity = capacity, food = food, food_target = target, food_ratio = food / target,
    tents = tents, cabins = cabins, huts = huts, machines = machines, towers = towers, chunks = chunks,
    d = colony.d or 0, parts = colony.d_parts or {}}
end

return M
