-- Colony adapter (#24 #25 #28 #29): Town Hall claims territory, housing is territory-restricted,
-- periodic evaluation (scheduler, not per-tick) computes desirability and spawns migrants.
-- Rules live in scripts.model.*; this file only talks to the engine.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local desirability = require("scripts.model.desirability")
local work = require("scripts.work")
local M = {}

M.HALL, M.TENT = "colony-town-hall", "colony-housing-tent"
M.CLAIM_RADIUS = 1              -- chunks, Chebyshev => 3x3 chunks
M.TENT_CAPACITY = 4
M.INTERVAL = 600                -- ticks between evaluations
M.FOOD_PER_COLONIST = 1         -- food items per interval
M.FOOD_ITEMS = {"colony-forage", "raw-fish", "yumako", "jellynut", "bioflux", "yumako-mash", "jelly"}
M.TARGET_STOCK_INTERVALS = 5

local function name_of(e) return e.type == "entity-ghost" and e.ghost_name or e.name end

local function refund(ev, e, name)
  local player = ev.player_index and game.get_player(ev.player_index)
  if player then
    player.insert{name = name, count = 1, quality = e.quality}
    player.create_local_flying_text{text = {"colony-message.outside-territory"}, position = e.position}
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

local function take_food(colony, amount)
  local hall = colony.hall
  for _, item in ipairs(M.FOOD_ITEMS) do
    if amount <= 0 then break end
    if prototypes.item[item] then amount = amount - hall.remove_item{name = item, count = amount} end
  end
end

function M.live_colonists(colony)
  local n = 0
  for id, c in pairs(colony.colonists) do
    if c.valid then n = n + 1 else colony.colonists[id] = nil end
  end
  return n
end

function M.capacity(colony)
  local n = 0
  for id, e in pairs(colony.housing) do
    if e.valid then n = n + M.TENT_CAPACITY else colony.housing[id] = nil end
  end
  return n
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
  if not colony.hall.valid then return end    -- hall gone; colony dormant (cleanup handled on destroy)
  scheduler.after(M.INTERVAL, "colony.evaluate", data)

  local pop = M.live_colonists(colony)
  local capacity = M.capacity(colony)
  -- consumption (shortfall kills one colonist per interval)
  local need = pop * M.FOOD_PER_COLONIST
  local stock = M.food_in(colony)
  if need > 0 then
    if stock >= need then take_food(colony, need)
    else
      take_food(colony, stock)
      for id, c in pairs(colony.colonists) do
        if c.valid then c.die(); colony.colonists[id] = nil; table.insert(colony.deaths, 0); pop = pop - 1; break end
      end
    end
  end
  local kept = {}
  for _, a in ipairs(colony.deaths) do if a < 40 then kept[#kept + 1] = a + 1 end end
  colony.deaths = kept

  stock = M.food_in(colony)
  local target = math.max(pop * M.FOOD_PER_COLONIST * M.TARGET_STOCK_INTERVALS, 1)
  local d, parts = desirability.compute({
    food_ratio = stock / target,
    free_housing_ratio = capacity > 0 and (capacity - pop) / capacity or 0,
    scenic = 0.3, leisure = 0, pollution = 0, deaths = colony.deaths,
  })
  colony.d, colony.d_parts = d, parts
  if d > desirability.defaults.migrate_in and pop < capacity then
    if spawn_colonist(colony) and settings.global["colony-debug-log"].value then
      game.print("[colony " .. colony.id .. "] migrant arrived, D=" .. string.format("%.2f", d))
    end
  end
end
scheduler.register("colony.evaluate", M.evaluate)

local function on_built(ev)
  local e = ev.entity or ev.created_entity
  if not (e and e.valid) then return end
  local name = name_of(e)
  if name == M.HALL and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    if owner then refund(ev, e, name); e.destroy(); return end   -- no overlapping halls
    local id = storage.next_colony_id; storage.next_colony_id = id + 1
    storage.colonies[id] = {id = id, surface_index = e.surface.index, hall = e, housing = {}, colonists = {}, deaths = {}, claimed = {}, no_site = {}}
    territory.claim_around(e.surface.index, id, e.position, M.CLAIM_RADIUS)
    local cx, cy = territory.chunk_of(e.position)
    rendering.draw_rectangle{color = {0.2, 0.8, 0.3, 0.8}, width = 3, filled = false, surface = e.surface,
      left_top = {(cx - M.CLAIM_RADIUS) * 32, (cy - M.CLAIM_RADIUS) * 32},
      right_bottom = {(cx + M.CLAIM_RADIUS + 1) * 32, (cy + M.CLAIM_RADIUS + 1) * 32}}
    script.register_on_object_destroyed(e)
    scheduler.after(M.INTERVAL, "colony.evaluate", {colony_id = id})
  elseif name == M.TENT and e.type ~= "entity-ghost" then
    local owner = territory.owner_at(e.surface.index, e.position)
    if not owner then refund(ev, e, name); e.destroy(); return end
    storage.colonies[owner].housing[e.unit_number] = e
  end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)
events.on(defines.events.script_raised_built, on_built)
events.on(defines.events.script_raised_revive, on_built)

work.bind(M)   -- avoids a require cycle (runtime require is illegal)

return M
