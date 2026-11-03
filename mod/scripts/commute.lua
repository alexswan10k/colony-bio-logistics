-- Commuter outposts adapter (#50). Rules are in model/commute.lua; the ride is scripts/transit.lua.
-- storage.commuters[unit_number] = {home = colony id, ends = tick}: a commuter at work in an outpost. It is a
-- colonist of the outpost while it is there (so the outpost's huts and haulers just use it), and its home colony
-- counts it in `colony.away`, which holds its bed. Everything here runs once per colony evaluation.
local commute = require("scripts.model.commute")
local housing = require("scripts.model.housing")
local transit_model = require("scripts.model.transit")
local work = require("scripts.work")
local M = {}

local colony_mod, transit   -- injected by scripts.colony via M.bind
function M.bind(c, t) colony_mod, transit = c, t end

local FOOD_ITEMS = {}
for _, opt in ipairs(housing.FOOD) do FOOD_ITEMS[#FOOD_ITEMS + 1] = opt.item end
M.FOOD_ITEMS = FOOD_ITEMS

function M.is_commuter(un) return storage.commuters ~= nil and storage.commuters[un] ~= nil end

-- Commuters at work in `colony`, in unit-number order.
function M.here(colony)
  local out = {}
  if not storage.commuters then return out end
  for un, c in pairs(colony.colonists) do
    if c.valid and storage.commuters[un] then out[#out + 1] = un end
  end
  table.sort(out)
  return out
end

local function meals_in(canteen)
  local n = 0
  for _, item in ipairs(FOOD_ITEMS) do n = n + canteen.entity.get_item_count(item) end
  return n
end

-- Meals on hand in the colony's canteens.
function M.meals(colony)
  local n = 0
  for _, c in ipairs(colony_mod.canteen_list(colony)) do n = n + meals_in(c) end
  return n
end

-- Food in the outpost's Town Hall: the canteen's larder. Without it an empty outpost could never reopen, since
-- only commuters can haul food into the canteen.
local function larder(colony)
  local n = 0
  for _, item in ipairs(FOOD_ITEMS) do n = n + colony_mod.stock_count(colony, item) end
  return n
end

-- Take `n` meals, the canteens first and then the hall's larder, food that spoils first going first.
local function serve(colony, n)
  for _, c in ipairs(colony_mod.canteen_list(colony)) do
    for _, item in ipairs(FOOD_ITEMS) do
      if n <= 0 then return end
      local have = c.entity.get_item_count(item)
      if have > 0 then n = n - c.entity.remove_item{name = item, count = math.min(have, n)} end
    end
  end
  for _, item in ipairs(FOOD_ITEMS) do
    if n <= 0 then return end
    n = n - colony_mod.take_stock(colony, item, n)
  end
end

-- A platform of `colony` that serves a train stop, or nil.
local function platform(colony)
  for _, p in ipairs(colony_mod.platform_list(colony)) do
    if transit.stop_of(p) then return p end
  end
end

-- Job slots of every hut in the colony (what commuters are wanted for): its capacity under the player's limit,
-- not just the posts with a tool on hand - an empty outpost has nobody to fetch the tools yet.
local function slots(colony)
  local n = 0
  for _, h in pairs(colony.huts or {}) do
    if h.entity.valid then
      local def = work.hut_info(h)
      n = n + math.min(def.capacity, h.limit or def.capacity)
    end
  end
  return n
end

-- A commuter whose way home is gone (no platform, or the train never came) walks: it leaves the outpost and
-- turns up at its own Town Hall.
local function walk_home(colony, un)
  local rec = storage.commuters[un]
  storage.commuters[un] = nil
  local e = colony.colonists[un]
  colony.colonists[un] = nil
  if colony.locks then colony.locks[un] = nil end
  colony.pop_cache, colony.pop_tick = nil, nil
  if e and e.valid then e.destroy() end
  local home = rec and storage.colonies[rec.home]
  if home and home.hall.valid then
    home.away = math.max((home.away or 0) - 1, 0)
    colony_mod.spawn_colonist(home)
    return true
  end
  return false
end

-- Riders boarding at their home town for work: their beds stay theirs (transit.lua calls this).
function M.left_home(home, n) home.away = (home.away or 0) + n end

-- Commuters stepping off at an outpost: entities just spawned for them.
function M.arrived(outpost, home_id, entities)
  storage.commuters = storage.commuters or {}
  local ends = game.tick + (storage.shift_override or commute.SHIFT_TICKS)
  for _, e in ipairs(entities) do storage.commuters[e.unit_number] = {home = home_id, ends = ends} end
  outpost.deficit = math.max((outpost.deficit or 0) - #entities, 0)
end

-- Commuters back home (off a train, or a commute that found no outpost and came back).
function M.back_home(home, n) home.away = math.max((home.away or 0) - n, 0) end

-- A commuter at work died: it was the home town's colonist, so the death and the freed bed are the home's.
function M.died(un)
  local rec = storage.commuters and storage.commuters[un]
  if not rec then return nil end
  storage.commuters[un] = nil
  local home = storage.colonies[rec.home]
  if home then home.away = math.max((home.away or 0) - 1, 0) end
  return home
end

-- Commuters riding out to work right now, on every coach.
local function outbound()
  local n = 0
  for _, rec in pairs(storage.coaches or {}) do
    for _, g in ipairs(rec.groups or {}) do if g.kind == "commute" then n = n + g.n end end
  end
  return n
end

-- Colonists of `colony` bound for or waiting at a platform to commute.
local function waiting(colony)
  local n = 0
  for un in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if st and st.commute and (st.state == "to_platform" or st.state == "waiting_train") then n = n + 1 end
  end
  return n
end

-- Commuters every outpost on `surface` still wants, less those already riding or waiting to go.
local function wanted_elsewhere(colony)
  local want, queued = 0, 0
  for _, other in pairs(storage.colonies) do
    if other.hall.valid and other.hall.surface == colony.hall.surface then
      queued = queued + waiting(other)
      if other ~= colony and platform(other) then want = want + (other.deficit or 0) end
    end
  end
  return math.max(want - outbound() - queued, 0)
end

-- The outpost side: feed the commuters, end shifts, send the stranded home on foot, and work out how many
-- more commuters it wants.
local function run_outpost(colony)
  local here = M.here(colony)
  local meals = M.meals(colony) + larder(colony)
  local take, owed, fed = commute.eat(meals, #here, colony_mod.FOOD_PER_COLONIST, colony.meal_owed)
  serve(colony, take)
  colony.meal_owed = owed
  local night = work.is_sleep_time(colony.hall.surface)
  local p = platform(colony)
  local working, walked = 0, 0
  for _, un in ipairs(here) do
    local rec = storage.commuters[un]
    local st = storage.unit_state[un]
    local leaving = st and st.home
    if leaving then
      if (st.state == "to_platform" or st.state == "waiting_train") and game.tick - (st.wait_since or game.tick) >= commute.STRANDED_TICKS then
        if walk_home(colony, un) then walked = walked + 1 end
      elseif not (st.platform and st.platform.entity.valid) then
        if walk_home(colony, un) then walked = walked + 1 end
      end
    elseif commute.shift_over(game.tick, rec.ends, night, fed) then
      local home = storage.colonies and storage.colonies[rec.home]
      if not (home and home.hall.valid) then
        if walk_home(colony, un) then walked = walked + 1 end
      elseif not (p and work.send_to_platform(colony, un, p, {home = rec.home, wait_since = game.tick}, "going home 🚉")) then
        if walk_home(colony, un) then walked = walked + 1 end
      end
    else
      working = working + 1
    end
  end
  if walked > 0 and colony.hall.valid then colony.hall.force.print({"colony-message.commuters-walked", walked}) end
  local open = meals > take and not night and p ~= nil
  colony.deficit = open and commute.deficit(slots(colony), working + 0, 0) or 0
  colony.commuters_here = working
end

-- The home side: idle colonists set off for the platform while outposts on the line want hands.
local function run_home(colony)
  if work.is_sleep_time(colony.hall.surface) then return end
  local p = platform(colony)
  if not p then return end
  local idle = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.state == "idle" and not M.is_commuter(un) then idle[#idle + 1] = un end
  end
  if #idle == 0 then return end
  table.sort(idle)
  local n = commute.to_send(#idle, wanted_elsewhere(colony), waiting(colony), transit_model.WAIT_CAP)
  local sent = 0
  for i = 1, n do
    if work.send_to_platform(colony, idle[i], p, {commute = true}, "commuting 🚉") then sent = sent + 1 end
  end
  if sent > 0 then colony.hall.force.print({"colony-message.commuters-bound", sent}) end
end

function M.evaluate(colony)
  if #colony_mod.canteen_list(colony) > 0 then run_outpost(colony) else colony.deficit, colony.commuters_here = 0, 0 end
  run_home(colony)
end

return M
