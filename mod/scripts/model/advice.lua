-- PURE: turns plain facts about the colony into "what is holding it back" lines for the panels.
-- Each result is {level = "red"|"amber", key = locale key under colony-advice, args = {...}}; the GUI
-- adapter gathers the facts and renders the lines, so the rules here stay testable offline.
local desirability = require("scripts.model.desirability")
local M = {}

local function add(out, level, key, ...) out[#out + 1] = {level = level, key = key, args = {...}} end

-- Colony-wide blockers, most severe first. facts:
--   pop, capacity, food, haul_rank (0 = hauling off), haulers (colonists on haul now), houses,
--   hall_stock {item -> n}, tool_gaps {{tool=, short=}} (huts that lack that tool), idle
function M.colony(f)
  local out = {}
  if (f.haul_rank or 1) == 0 then add(out, "red", "haul-off") end
  if f.pop > 0 and f.food <= 0 then add(out, "red", "no-food") end
  if (f.houses or 0) == 0 then add(out, "red", "no-houses")
  elseif f.pop >= f.capacity then add(out, "amber", "no-beds") end
  for _, g in ipairs(f.tool_gaps or {}) do
    if (f.hall_stock[g.tool] or 0) <= 0 then add(out, "amber", "no-tool", g.tool, g.short) end
  end
  if f.pop > 0 and (f.haul_rank or 1) > 0 and (f.haulers or 0) == 0 then add(out, "amber", "no-haulers") end
  return out
end

-- Why a hut has fewer workers than its capacity, or nil when it is simply working. facts:
--   needs_tool, tool, tools, capacity, limit, workers, hall_stock (of the tool), inflight (tool on the way),
--   inputs_missing (supply-gated hut lacks inputs), sites (nil = not applicable), haul_rank
function M.hut(f)
  if (f.limit or f.capacity) == 0 then return "paused" end
  -- Stock limit reached: the hut stands down and its workers haul or work elsewhere (not a fault).
  if f.quota_item then return "quota-met", f.quota_item end
  -- A supply-gated hut with nothing to make (a Toolsmith when every hut is tooled and a spare is in stock).
  if f.nothing_to_do then return "nothing-to-do" end
  if f.sites ~= nil and f.sites == 0 then return "no-sites" end
  if f.needs_tool and f.tools == 0 then
    if (f.inflight or 0) > 0 then return "tool-coming" end
    if (f.hall_stock or 0) <= 0 then return "no-tool-in-hall", f.tool end
    if (f.haul_rank or 1) == 0 then return "haul-off" end
    return "tool-waiting"
  end
  if f.inputs_missing then return "no-inputs" end
  if f.workers == 0 and f.tools > 0 then return "no-workers" end
  return nil
end

-- One house's status for its tooltip and the alert bar, or nil before its first evaluation. facts:
--   occupants, capacity, sat {need_id -> bool}, needs {{id=, critical=}}, hungry (evaluations a critical
--   need has gone unmet), starve_after. Returns {level = "green"|"amber"|"red", key = ..., args = {...}}.
function M.house(f)
  if not f.sat then return nil end
  if (f.occupants or 0) == 0 then return {level = "amber", key = "house-empty", args = {}} end
  for _, need in ipairs(f.needs) do
    if need.critical and not f.sat[need.id] then
      return {level = "red", key = "house-starving", args = {need.id, math.max((f.starve_after or 1) - (f.hungry or 0), 1)}}
    end
  end
  for _, need in ipairs(f.needs) do
    if not f.sat[need.id] then return {level = "amber", key = "house-lacking", args = {need.id}} end
  end
  return {level = "green", key = "house-ok", args = {f.occupants, f.capacity}}
end

-- Why the population is or is not growing, as {level, key, args}. facts: pop, capacity, d, parts (from
-- desirability.compute), accept (false = migrants switched off). The weakest factor is the one furthest
-- below its best, so the player is pointed at the single thing that would help most.
function M.growth(f, p)
  p = p or desirability.defaults
  if f.d < p.leave_below and (f.pop or 0) > 0 then return {level = "red", key = "growth-leaving", args = {M.weakest(f.parts, p)}} end
  if f.accept == false then return {level = "amber", key = "growth-closed", args = {}} end
  if (f.capacity or 0) <= 0 then return {level = "red", key = "growth-no-houses", args = {}} end
  if f.pop >= f.capacity then return {level = "amber", key = "growth-no-beds", args = {}} end
  if f.d <= p.migrate_in then return {level = "amber", key = "growth-low", args = {M.weakest(f.parts, p)}} end
  return {level = "green", key = "growth-ok", args = {}}
end

local BEST = {food = "w_food", housing = "w_housing", scenic = "w_scenic", leisure = "w_leisure"}
local ORDER = {"food", "housing", "leisure", "scenic", "pollution", "deaths"}
function M.weakest(parts, p)
  p = p or desirability.defaults
  local worst, gap = "food", -1
  for _, k in ipairs(ORDER) do
    local v = (parts or {})[k] or 0
    local g = BEST[k] and (p[BEST[k]] - v) or -v
    if g > gap + 1e-9 then worst, gap = k, g end
  end
  return worst
end

-- A Motor Pool's tooltip (#60). facts: cars (parked), fuel (items), tank (trips already burnt), out (trucks
-- on the road). Never red: a pool with nothing in it costs the colony nothing, haulers just walk.
function M.pool(f)
  if (f.out or 0) > 0 then return {level = "green", key = "pool-out", args = {f.out, f.cars or 0, f.fuel or 0}} end
  if (f.cars or 0) == 0 then return {level = "amber", key = "pool-no-cars", args = {}} end
  if (f.fuel or 0) == 0 and (f.tank or 0) == 0 then return {level = "amber", key = "pool-no-fuel", args = {}} end
  return {level = "green", key = "pool-ready", args = {f.cars, f.fuel or 0}}
end

-- A Tavern's tooltip (#48). facts: ale (on tap), houses and inspired (served at the last evaluation). Amber, never
-- red: a dry Tavern only means nobody gets the bonus.
function M.tavern(f)
  if (f.ale or 0) <= 0 then return {level = "amber", key = "tavern-dry", args = {}} end
  if (f.houses or 0) == 0 then return {level = "amber", key = "tavern-idle", args = {f.ale}} end
  return {level = "green", key = "tavern-serving", args = {f.houses, f.inspired or 0, f.ale}}
end

-- A Passenger Platform's tooltip (#49). facts: stop (a train stop is in reach), waiting (colonists queued).
function M.platform(f)
  if not f.stop then return {level = "amber", key = "platform-no-stop", args = {}} end
  if (f.waiting or 0) > 0 then return {level = "green", key = "platform-waiting", args = {f.waiting}} end
  return {level = "green", key = "platform-idle", args = {}}
end

-- A Clinic's tooltip (#47). facts: medicine (on hand), sick (in town), doctors (on duty). Red when people are sick
-- and nothing is being done about it.
function M.clinic(f)
  if (f.sick or 0) > 0 and (f.medicine or 0) <= 0 then return {level = "red", key = "clinic-no-medicine", args = {}} end
  if (f.sick or 0) > 0 and (f.doctors or 0) == 0 then return {level = "amber", key = "clinic-no-doctor", args = {f.sick}} end
  if (f.sick or 0) > 0 then return {level = "green", key = "clinic-treating", args = {f.doctors, f.sick, f.medicine}} end
  if (f.medicine or 0) <= 0 then return {level = "amber", key = "clinic-no-medicine", args = {}} end
  return {level = "green", key = "clinic-idle", args = {f.medicine}}
end

-- A Canteen's tooltip (#50). facts: meals (food on hand), commuters (at work here), open (commuters still wanted).
function M.canteen(f)
  if (f.meals or 0) <= 0 then return {level = "amber", key = "canteen-empty", args = {}} end
  if (f.commuters or 0) > 0 then return {level = "green", key = "canteen-serving", args = {f.commuters, f.meals}} end
  if (f.open or 0) > 0 then return {level = "green", key = "canteen-idle", args = {f.meals, f.open}} end
  return {level = "green", key = "canteen-full", args = {f.meals}}
end

-- A Cemetery's tooltip (#53). facts: graves, plots. Green with room; amber when full, because the next dead
-- are then buried where they fall.
function M.cemetery(f)
  if (f.graves or 0) >= (f.plots or 0) then return {level = "amber", key = "cemetery-full", args = {f.graves or 0}} end
  return {level = "green", key = "cemetery-room", args = {f.graves or 0, f.plots}}
end

-- State of one machine request row. have = in the machine, inflight = on a hauler, stock = colony stock.
function M.request(f)
  if f.have >= f.count then return "stocked" end
  if (f.inflight or 0) > 0 then return "delivering" end
  if (f.stock or 0) <= 0 then return "no-stock" end
  if (f.haul_rank or 1) == 0 then return "haul-off" end
  return "queued"
end

return M
