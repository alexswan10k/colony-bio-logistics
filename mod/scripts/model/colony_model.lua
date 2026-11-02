-- PURE colony simulation step (food -> desirability -> migration/leaving/starvation). Used by tests and sim/ balance runs.
-- A colony is a plain table; step() mutates it and returns events. One step = one "evaluation interval".
local desirability = require("scripts.model.desirability")
local M = {}

function M.new(o)
  local c = {
    pop = o.pop or 4, capacity = o.capacity or 16, food_stock = o.food_stock or 0,
    foragers_output = o.foragers_output or 0,       -- food items produced per interval
    food_per_colonist = o.food_per_colonist or 1,   -- consumed per interval
    target_stock_intervals = o.target_stock_intervals or 5,
    scenic = o.scenic or 0.3, leisure = o.leisure or 0, pollution = o.pollution or 0,
    deaths = {}, offworld = o.offworld or false, nurseries = o.nurseries or 0,
    migrants_per_step = o.migrants_per_step or 1, leave_rate = o.leave_rate or 0.1,
    birth_rate = o.birth_rate or 0.1, critical_mass = o.critical_mass or 10,
    params = o.params or desirability.defaults,
  }
  return c
end

-- How many colonists pack up and leave in one interval (#29). Nobody leaves while D is at or above
-- `leave_below`; below it a trickle starts immediately (at least one colonist, so the player sees it), and
-- the trickle grows with how far below the line the colony is, up to `leave_rate` of the population.
-- Lives here rather than in the adapter so sim/ balance runs and the game agree.
function M.leave_count(pop, d, p)
  p = p or desirability.defaults
  if pop <= 0 or d >= p.leave_below then return 0 end
  local span = p.leave_span or 0.5
  local severity = math.min((p.leave_below - d) / span, 1)
  return math.min(pop, math.max(1, math.ceil(pop * (p.leave_rate or 0.1) * severity)))
end

function M.step(c)
  local ev = {migrated = 0, left = 0, starved = 0, born = 0}
  -- production & consumption
  c.food_stock = c.food_stock + c.foragers_output
  local need = c.pop * c.food_per_colonist
  if c.food_stock >= need then c.food_stock = c.food_stock - need
  else
    local short = need - c.food_stock; c.food_stock = 0
    ev.starved = math.min(c.pop, math.ceil(short / c.food_per_colonist / 2))   -- half the shortfall dies
    c.pop = c.pop - ev.starved
    for _ = 1, ev.starved do c.deaths[#c.deaths + 1] = 0 end
  end
  -- age deaths, drop negligible ones
  local kept = {}
  for _, a in ipairs(c.deaths) do if a < 40 then kept[#kept + 1] = a + 1 end end
  c.deaths = kept
  -- desirability
  local target = math.max(c.pop * c.food_per_colonist * c.target_stock_intervals, 1)
  local d, parts = desirability.compute({
    food_ratio = c.food_stock / target,
    free_housing_ratio = (c.capacity - c.pop) / math.max(c.capacity, 1),
    scenic = c.scenic, leisure = c.leisure, pollution = c.pollution, deaths = c.deaths,
  }, c.params)
  c.d, c.d_parts = d, parts
  local free = c.capacity - c.pop
  if not c.offworld then
    if d > c.params.migrate_in and free > 0 then
      ev.migrated = math.min(free, c.migrants_per_step); c.pop = c.pop + ev.migrated
    end
  elseif c.nurseries > 0 and c.pop >= c.critical_mass and d > c.params.migrate_in and free > 0 then
    ev.born = math.min(free, math.max(1, math.floor(c.pop * c.birth_rate))); c.pop = c.pop + ev.born
  end
  if d < c.params.leave_below and c.pop > 0 then
    ev.left = M.leave_count(c.pop, d, c.params); c.pop = math.max(0, c.pop - ev.left)
  end
  return ev
end

function M.run(c, steps)
  local hist = {}
  for i = 1, steps do
    local ev = M.step(c)
    hist[i] = {step = i, pop = c.pop, food = c.food_stock, d = c.d, ev = ev}
  end
  return hist
end

return M
