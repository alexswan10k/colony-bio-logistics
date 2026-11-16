---@diagnostic enable: undefined-field, missing-fields
-- PURE: hand-feeding ammo into vanilla ammo-turrets (#59, design §5.2). A gun turret is opted into colony
-- logistics exactly like any other machine (marker drag / supply panel); its one request row defaults to the
-- magazine it shoots. All the rules live here so the adapter only reads values and touches engine objects.
-- Colonist *weapon* ammo (rifles, magazine-per-10-engagements, model/garrison.lua) is a separate subsystem.
local M = {}

-- Known vanilla ammo-turret entity names -> their default item. Modded or unknown names get no auto-row:
-- the player sets one by hand in the existing 3-row supply panel instead of us guessing. Distinct prototype
-- types (electric/laser, fluid, artillery) are deliberately out of this first slice.
M.AMMO_FOR = {
  ["gun-turret"] = "firearm-magazine",
  ["flamethrower-turret"] = "flamethrower-ammo",
  ["rocket-turret"] = "rocket",
}

-- Per-item default target. 10 matches one full firearm-magazine stack and the vanilla gun-turret inventory.
M.DEFAULT_TARGET = {
  ["firearm-magazine"] = 10,
  ["flamethrower-ammo"] = 10,
  ["rocket"] = 10,
}

-- Turret ammo outranks ordinary external machines (default 4) inside the same `request` band, but stays far
-- below houses' `critical` band (1). The player can still change it with the existing +/- buttons.
M.DEFAULT_BUILDING_PRIORITY = 3

-- The default ammo for an entity name, or nil for unknown/modded turrets. Direct lookup only: no pairs().
function M.ammo_for(name)
  return M.AMMO_FOR[name]
end

-- A fresh default request row for an entity name: one row for known turrets, none otherwise. Machine rows
-- are copied per entity, so every call returns a NEW table (no shared mutable rows between turrets).
function M.default_request(name)
  local item = M.ammo_for(name)
  if not item then return {} end
  return {{item = item, count = M.DEFAULT_TARGET[item]}}
end

-- The whole machine-record default for an ammo-turret. `collect=false` matters: a turret has no output
-- inventory and must never have its loaded ammo emptied back into storage. Fresh tables on every call.
function M.defaults(name)
  return {requests = M.default_request(name), collect = false, priority = M.DEFAULT_BUILDING_PRIORITY}
end

-- Integer deficit still wanted: target minus what is present minus what is already on a hauler. Nil-safe,
-- so an inflight claim counts as "already on its way" and two haulers never claim the same magazines.
function M.want(count, inflight, target)
  return math.max(0, (target or 0) - (count or 0) - (inflight or 0))
end

return M
