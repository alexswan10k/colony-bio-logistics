-- Permanent death adapter (#53). Rules are in model/mortality.lua. Every colonist death goes through M.record:
-- starvation calls it directly (colony.kill_one), anything else that kills a colonist (a train, a biter, a fire)
-- arrives through on_entity_died. The death joins colony.deaths (the desirability penalty) and colony.fallen, and
-- the colonist is buried in the colony's first Cemetery with a free plot, else under a Grave where it fell.
local events = require("scripts.events")
local mortality = require("scripts.model.mortality")
local M = {}

M.COLONIST = "colony-colonist"
M.GRAVE = "colony-grave"

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

-- Record one death in `colony`. `pos`/`surface` = where it fell (nil when there is no body, e.g. a wrecked
-- coach). `cause` = what killed it ("starved" or a [colony-death] key), kept as colony.last_death; `quiet` when
-- the caller has already said what happened.
function M.record(colony, pos, surface, cause, quiet)
  table.insert(colony.deaths, 0)
  colony.last_death = cause
  colony.fallen = (colony.fallen or 0) + 1
  colony.pop_cache, colony.pop_tick, colony.house_index = nil, nil, nil
  local cemeteries = colony_mod.cemetery_list(colony)
  local i = mortality.plot(cemeteries)
  local where
  if i then
    local c = cemeteries[i]
    c.graves = (c.graves or 0) + 1
    colony.buried = (colony.buried or 0) + 1
    where = c.entity
  elseif pos and surface then
    local g = surface.create_entity{name = M.GRAVE, position = pos,
      force = colony.hall.valid and colony.hall.force or "player"}
    where = g or {position = pos, surface = surface}
  end
  if not quiet and colony.hall.valid then
    local at = where and colony_mod.gps(where.position, where.surface) or ""
    colony.hall.force.print({i and "colony-message.died-buried" or "colony-message.died",
      {"entity-name." .. M.COLONIST}, {"colony-death." .. cause}, at})
  end
end

-- The colony whose roster holds unit `un`, or nil (a colonist already struck off: starvation, or one leaving).
local function owner_of(un)
  for _, colony in pairs(storage.colonies) do
    if colony.colonists[un] then return colony end
  end
end

events.on(defines.events.on_entity_died, function(ev)
  local e = ev.entity
  if e.name ~= M.COLONIST then return end
  local un = e.unit_number
  local colony = un and owner_of(un)
  if not colony then return end
  colony.colonists[un] = nil
  if colony.locks then colony.locks[un] = nil end
  local killer = ev.cause and ev.cause.valid and ev.cause
  local cause = mortality.cause{
    cause_type = killer and killer.type,
    enemy = ev.force ~= nil and ev.force.name == "enemy",
    damage_type = ev.damage_type and ev.damage_type.name,
  }
  M.record(colony, e.position, e.surface, cause)
end)

return M
