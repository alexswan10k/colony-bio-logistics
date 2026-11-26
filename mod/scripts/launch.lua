-- Adapter: the exact character-in-platform launch path (#69). A colonist is a `unit` but a cargo pod only
-- seats a `character`, so the volunteer is swapped for a real character, the pod is created at the platform
-- hub, the character is seated, and a surface destination starts the ascent. On descent the character becomes
-- a colonist again in a colony on the landing surface. Engine facts are pinned by s27_launch_probe.
-- All rules come from model/launch.lua and model/training.lua; this file only owns live entities and events.
local events = require("scripts.events")
local launch = require("scripts.model.launch")
local training = require("scripts.model.training")
local planet = require("scripts.planet")
local M = {}

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

-- Move all plain per-unit state (roster, lock, labels, carry sprites, age, sickness) to a new unit number.
local function move_state(from, to, colony)
  if from == to then return end
  colony.colonists[to], colony.colonists[from] = colony.colonists[from], nil
  if storage.unit_state then
    storage.unit_state[to], storage.unit_state[from] = storage.unit_state[from], nil
  end
  for _, key in ipairs(launch.TRANSFER_KEYS) do
    local t = storage[key]
    if t and t[from] then t[to], t[from] = t[from], nil end
  end
  if colony.locks then colony.locks[to], colony.locks[from] = colony.locks[from], nil end
  colony.pop_cache, colony.pop_tick = nil, nil
end

local function take_rations(colony, hall)
  for item, n in pairs(training.RATIONS) do
    local need = n
    if hall.valid then need = need - hall.remove_item{name = item, count = need} end
    if need > 0 then
      for _, cr in ipairs(colony_mod.storage_crates(colony)) do
        local e = cr.entity
        if e and e.valid then
          need = need - e.remove_item{name = item, count = need}
          if need <= 0 then break end
        end
      end
    end
    if need > 0 then return false end
  end
  return true
end

---@param colony table
---@return boolean
local function dispatch(colony)
  local hall = colony and colony.hall
  if not (hall and hall.valid) then return false end
  local surface = hall.surface
  if not (planet.is_platform(surface) and surface.platform) then return false end
  local hub = surface.platform.hub
  if not (hub and hub.valid) or #colony_mod.training_list(colony) == 0 then return false end
  if not launch.can_launch(colony_mod.live_colonists(colony), game.tick, colony.launch_ready, true, true) then
    return false
  end

  local ids = {}
  for un, e in pairs(colony.colonists) do
    local rec = storage.age and storage.age[un]
    local st = storage.unit_state and storage.unit_state[un]
    if e.valid and not (rec and rec.stage == "child") and not (colony.locks and colony.locks[un])
        and not (st and st.job == "militia")
        and not (storage.tourists and storage.tourists[un]) then
      ids[#ids + 1] = un
    end
  end
  table.sort(ids)
  local un = ids[1]
  if not un then return false end
  if not take_rations(colony, hall) then return false end

  local pos = surface.find_non_colliding_position(launch.CHARACTER, hall.position, 10, 0.5)
  local ch = pos and surface.create_entity{name = launch.CHARACTER, position = pos, force = hall.force}
  if not (ch and ch.valid) then return false end
  move_state(un, ch.unit_number, colony)

  local ok, pod = pcall(function() return hub.create_cargo_pod() end)
  if not ok or not pod then
    move_state(ch.unit_number, un, colony)
    ch.destroy()
    return false
  end
  pod.set_passenger(ch)
  for item, n in pairs(launch.manifest()) do pod.insert{name = item, count = n} end

  -- Prefer the planet the platform last visited; otherwise the lowest-numbered other surface.
  local preferred
  local loc = surface.platform.last_visited_space_location
  local loc_name = loc and loc.name or nil
  local surfaces = {}
  for _, s in pairs(game.surfaces) do
    if s.valid and s.index ~= surface.index then
      surfaces[#surfaces + 1] = {index = s.index, name = s.name}
      if loc_name and s.name == loc_name then preferred = s.index end
    end
  end
  table.sort(surfaces, function(a, b) return a.index < b.index end)
  local dest = launch.destination(surfaces, preferred)
  if dest then
    pod.cargo_pod_destination = {type = defines.cargo_destination.surface, surface = dest,
      position = {x = 0, y = 0}}
  end

  storage.launches = storage.launches or {}
  storage.launches[pod.unit_number] = {home = colony.id, un = ch.unit_number}
  colony.launch_ready = game.tick + training.LAUNCH_TICKS
  colony.stock_cache, colony.storage_cache, colony.ledger_cache = nil, nil, nil
  return true
end
M.dispatch = dispatch

-- On descent the passenger is a character again: swap it back into the colony's unit roster on the landing
-- surface (or the home colony if the pod landed somewhere without a town) and return the pod item to stock.
events.on(defines.events.on_cargo_pod_finished_descending, function(ev)
  local pod = ev and ev.cargo_pod
  if not (pod and pod.valid) then return end
  local rec = storage.launches and storage.launches[pod.unit_number]
  if not rec then return end
  storage.launches[pod.unit_number] = nil
  local ch = pod.get_passenger()
  if not (ch and ch.valid) then return end
  local surface = pod.surface
  local ids = {}
  for id, c in pairs(storage.colonies or {}) do
    if c.hall and c.hall.valid and c.hall.surface == surface then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local target = storage.colonies[ids[1]] or storage.colonies[rec.home]
  if not target then return end
  local at = surface.find_non_colliding_position("colony-colonist", ch.position, 8, 0.5) or ch.position
  local unit = surface.create_entity{name = "colony-colonist", position = at, force = ch.force}
  if not (unit and unit.valid) then return end
  script.register_on_object_destroyed(unit)
  move_state(ch.unit_number, unit.unit_number, target)
  ch.destroy()
  if target.hall and target.hall.valid then target.hall.insert{name = launch.POD_ITEM, count = 1} end
  target.stock_cache, target.ledger_cache = nil, nil
end)

return M
