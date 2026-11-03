-- Colony feedback (adapter): say what is wrong where the player is already looking. Every few seconds each
-- house, hut and Town Hall gets a status line on its tooltip (custom_status), and anything that is costing
-- the colony - a house about to starve, a hut that cannot get its tool, nothing left to harvest, no food at
-- all - goes into the native alert bar, clickable to the building. Rules are in model/advice.lua; this file
-- only reads the world and writes statuses and alerts. The same short cadence drives the hall workshop.
local scheduler = require("scripts.scheduler")
local advice = require("scripts.model.advice")
local housing = require("scripts.model.housing")
local workshop = require("scripts.model.workshop")
local jobs = require("scripts.model.jobs")
local motor = require("scripts.model.motor")
local recreation = require("scripts.model.recreation")
local mortality = require("scripts.model.mortality")
local illness = require("scripts.model.illness")
local transit = require("scripts.transit")
local work = require("scripts.work")
local M = {}

M.TICKS = 300            -- status / alert refresh per colony
M.REALERT_TICKS = 1800   -- an unchanged alert is re-posted this often, in case the alert bar dropped it

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

local DIODE = {green = defines.entity_status_diode.green, amber = defines.entity_status_diode.yellow,
  red = defines.entity_status_diode.red}
local NEED_ICON = {food = "colony-forage", water = "colony-water", heat = "wood", electricity = "small-electric-pole",
  comfort = "colony-furniture"}

local function item(name) return {"?", {"item-name." .. name}, {"entity-name." .. name}, name} end
local function need(id) return {"colony-gui.need-" .. id} end

local function house_status(h)
  local tier = housing.TIERS[h.kind]
  local sat = housing.available(tier, colony_mod.house_stock_cached(h), colony_mod.is_powered(h))
  local r = advice.house{occupants = h.occupants or 0, capacity = tier.capacity, sat = sat, needs = tier.needs,
    hungry = h.hungry, starve_after = colony_mod.STARVE_AFTER}
  if not r then return nil end
  if r.key == "house-starving" then
    local seconds = math.ceil(r.args[2] * colony_mod.interval() / 60)
    return r, {"colony-status." .. r.key, need(r.args[1]), seconds}, NEED_ICON[r.args[1]]
  elseif r.key == "house-lacking" then
    return r, {"colony-status." .. r.key, need(r.args[1])}
  end
  local key = (r.key == "house-ok" and h.inspired) and "house-ok-inspired" or r.key
  return r, {"colony-status." .. key, r.args[1], r.args[2]}
end

-- A hut short of its tool, where the hall workshop could make one: which ingredient is missing, if any.
local function craft_gap(colony, tool, stock)
  if not (workshop.RECIPES[tool] and colony.hall.force.recipes[tool] and colony.hall.force.recipes[tool].enabled) then
    return nil
  end
  local item_name, n = next(workshop.missing(tool, stock))
  return {item = item_name, n = n}
end

local function hut_status(colony, h, stock, haul_rank)
  local def, tools, allowed, workers = work.hut_info(h)
  if h.job == "heal" then     -- a Clinic (#47) answers to the sick, not to sites
    local r = advice.clinic{medicine = h.entity.get_item_count(illness.MEDICINE), sick = colony.sick_count or 0,
      doctors = workers}
    return r, {"colony-status." .. r.key, r.args[1], r.args[2], r.args[3]}, illness.MEDICINE
  end
  local inputs_missing = false
  if not def.tool and workers == 0 then
    local inv = h.entity.get_inventory(defines.inventory.chest)
    inputs_missing = true
    for _, it in ipairs(def.keep or {}) do
      if inv and inv.get_item_count(it) > 0 then inputs_missing = false end
    end
  end
  local stuck = (colony.no_site[h.entity.unit_number] or 0) > game.tick
  local reason, arg = advice.hut{needs_tool = def.tool ~= nil, tool = def.tool, tools = tools, capacity = def.capacity,
    limit = h.limit, workers = workers, inflight = def.tool and (h.inflight[def.tool] or 0) or 0,
    hall_stock = def.tool and (stock[def.tool] or 0) or 0, sites = stuck and 0 or nil,
    inputs_missing = inputs_missing, haul_rank = haul_rank}
  if not reason then
    return {level = "green"}, {"colony-status.hut-working", workers, allowed}
  end
  if reason == "no-tool-in-hall" then
    local gap = craft_gap(colony, arg, stock)
    if gap and not gap.item then
      return {level = "amber"}, {"colony-status.hut-tool-crafting", item(arg)}
    elseif gap then
      return {level = "red"}, {"colony-status.hut-tool-ingredients", item(arg), gap.n, item(gap.item)}, arg
    end
    return {level = "red"}, {"colony-advice.hut-no-tool-in-hall", item(arg)}, arg
  end
  local level = (reason == "no-sites" or reason == "haul-off") and "red" or "amber"
  return {level = level}, {"colony-advice.hut-" .. reason}, h.entity.name
end

local function hall_status(colony)
  local pop, capacity = colony_mod.live_colonists(colony), colony_mod.capacity(colony)
  -- Under attack (#61) outranks everything: the alert points the player at the town while colonists hide.
  if colony.alarms and #colony.alarms > 0 then
    local hiding = 0
    for un in pairs(colony.colonists) do
      local st = storage.unit_state[un]
      if st and (st.state == "sheltered" or st.state == "to_shelter") then hiding = hiding + 1 end
    end
    return {level = "red"}, {"colony-advice.under-attack", hiding}, "gun-turret"
  end
  local problem
  if (jobs.effective(colony.priority).haul or 1) == 0 then problem = {"colony-advice.haul-off"}
  elseif pop > 0 and colony_mod.total_food(colony) <= 0 then problem = {"colony-advice.no-food"} end
  if problem then return {level = "red"}, problem, "colony-forage" end
  local g = advice.growth{pop = pop, capacity = capacity, d = colony.d or 0, parts = colony.d_parts or {},
    accept = colony.accept_migrants}
  local args = {}
  if g.args[1] then args[1] = {"colony-advice.factor-" .. g.args[1]} end
  return g, {"colony-status." .. g.key, args[1]}
end

local function set_status(e, level, label)
  e.custom_status = {diode = DIODE[level] or DIODE.amber, label = label}
end

-- Post new or changed alerts, re-post stale ones, clear the ones whose problem went away.
local function sync_alerts(colony, problems)
  local old = colony.alerted or {}
  local players = {}
  for _, p in pairs(colony.hall.force.connected_players) do
    if p.mod_settings["colony-alerts"].value then players[#players + 1] = p end
  end
  local now = {}
  for un, pr in pairs(problems) do
    local prev = old[un]
    local sig = serpent.line(pr.message)
    if prev and prev.sig == sig and game.tick - prev.at < M.REALERT_TICKS then
      now[un] = prev
    else
      for _, p in ipairs(players) do
        p.remove_alert{entity = pr.entity, type = defines.alert_type.custom}
        p.add_custom_alert(pr.entity, {type = "item", name = pr.icon}, pr.message, true)
      end
      now[un] = {entity = pr.entity, sig = sig, at = game.tick}
    end
  end
  for un, prev in pairs(old) do
    if not now[un] and prev.entity.valid then
      for _, p in ipairs(players) do p.remove_alert{entity = prev.entity, type = defines.alert_type.custom} end
    end
  end
  colony.alerted = now
end

function M.update(colony)
  local problems = {}
  local function report(e, r, label, icon)
    set_status(e, r.level, label)
    if r.level == "red" and icon and prototypes.item[icon] then
      problems[e.unit_number] = {entity = e, icon = icon, message = label}
    end
  end
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local r, label, icon = house_status(h)
    if r then report(h.entity, r, label, icon or h.entity.name) end
  end
  local stock = colony_mod.stock_table(colony)
  local haul_rank = jobs.effective(colony.priority).haul or 1
  for _, h in pairs(colony.huts) do
    if h.entity.valid and h.job ~= "research" then   -- labs keep their own staffed/unstaffed status
      local r, label, icon = hut_status(colony, h, stock, haul_rank)
      report(h.entity, r, label, icon)
    end
  end
  for _, p in ipairs(colony_mod.pool_list(colony)) do
    local contents = {}
    for _, c in ipairs(p.entity.get_inventory(defines.inventory.chest).get_contents()) do
      contents[c.name] = (contents[c.name] or 0) + c.count
    end
    local out = 0
    for _, t in pairs(storage.trucks or {}) do if t.pool == p then out = out + 1 end end
    local r = advice.pool{cars = contents[motor.CAR] or 0, fuel = motor.fuel_count(contents), tank = p.tank, out = out}
    report(p.entity, r, {"colony-status." .. r.key, r.args[1], r.args[2], r.args[3]})
  end
  for _, t in ipairs(colony_mod.tavern_list(colony)) do
    local ale = t.entity.get_item_count(recreation.ITEM)
    local r = advice.tavern{ale = ale, houses = t.houses or 0, inspired = t.inspired or 0}
    report(t.entity, r, {"colony-status." .. r.key, r.args[1], r.args[2], r.args[3]})
  end
  for _, p in ipairs(colony_mod.platform_list(colony)) do
    local r = advice.platform{stop = transit.stop_of(p) ~= nil, waiting = transit.waiting_count(colony, p)}
    report(p.entity, r, {"colony-status." .. r.key, r.args[1]})
  end
  for _, c in ipairs(colony_mod.canteen_list(colony)) do
    local meals = 0
    for _, item in ipairs(colony_mod.MEAL_ITEMS) do meals = meals + c.entity.get_item_count(item) end
    local r = advice.canteen{meals = meals, commuters = colony.commuters_here or 0, open = colony.deficit or 0}
    report(c.entity, r, {"colony-status." .. r.key, r.args[1], r.args[2]})
  end
  for _, c in ipairs(colony_mod.cemetery_list(colony)) do
    local r = advice.cemetery{graves = c.graves, plots = mortality.CEMETERY_PLOTS}
    report(c.entity, r, {"colony-status." .. r.key, r.args[1], r.args[2]})
  end
  local r, label, icon = hall_status(colony)
  report(colony.hall, r, label, icon)
  sync_alerts(colony, problems)
end

function M.tick(data)
  local colony = storage.colonies[data.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  colony.feedback_at = game.tick
  scheduler.after(M.TICKS, "feedback.tick", data)
  colony_mod.workshop(colony)
  M.update(colony)
end
scheduler.register("feedback.tick", M.tick)

-- Start the chain for a colony, or restart one that was lost. Safe to call as often as you like.
function M.ensure(colony)
  if colony.feedback_at and game.tick - colony.feedback_at <= M.TICKS * 2 then return end
  colony.feedback_at = game.tick
  scheduler.after(1, "feedback.tick", {colony_id = colony.id})
end

return M
