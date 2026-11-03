-- PURE: permanent death (#53, design §2.4). Every colonist death is final and is counted against the colony it
-- belonged to, whatever killed it: starvation, a train, a biter, a fire. A death feeds the desirability death
-- penalty (model/desirability.lua). The dead are buried in a Cemetery with a free plot, else where they fell.
-- A colony with a Cemetery mourns each death for half as long.
local M = {}

M.CEMETERY_PLOTS = 12
M.BURIED_HALFLIFE = 3     -- intervals; desirability.defaults.death_halflife (6) without a cemetery

local ROLLING = {["locomotive"] = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true}
local VEHICLE = {["car"] = true, ["spider-vehicle"] = true}
local DAMAGE = {fire = "fire", poison = "poison", explosion = "explosion", acid = "acid"}

-- What killed a colonist, as a locale key under [colony-death]. `d` = {cause_type = the killer's prototype type
-- or nil, enemy = the killer is on the enemy force, damage_type = the final blow's damage type or nil}. The
-- killer is checked before the damage type: a train hit is "impact" damage, a biter's bite is "physical".
function M.cause(d)
  local t = d and d.cause_type
  if t and ROLLING[t] then return "train" end
  if t and VEHICLE[t] then return "vehicle" end
  if d and d.enemy then return "enemy" end
  return DAMAGE[d and d.damage_type] or "unknown"
end

-- Which cemetery takes the next grave: the first, in the order given, with a free plot; nil if all are full.
-- cemeteries = array of {graves = n}.
function M.plot(cemeteries)
  for i, c in ipairs(cemeteries or {}) do
    if (c.graves or 0) < M.CEMETERY_PLOTS then return i end
  end
  return nil
end

-- Half-life (in evaluation intervals) of the death penalty for a colony.
function M.halflife(base, has_cemetery)
  if has_cemetery then return math.min(base, M.BURIED_HALFLIFE) end
  return base
end

return M
