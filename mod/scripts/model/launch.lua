---@diagnostic enable: undefined-field, missing-fields
-- PURE: the exact character-in-platform launch path (#69, design §9.2). A colonist is a `unit` but a cargo pod
-- seats a `character`, so the adapter swaps the unit for a real character, seats it, and launches a pod. These
-- are the rules around that swap; the adapter owns the live entities and events. No Factorio globals here.
local M = {}

M.CHARACTER = "character"          -- the vanilla prototype a cargo pod accepts as a passenger
M.POD_ITEM = "colony-cryo-pod"
M.MANIFEST = {[M.POD_ITEM] = 1}
M.TRANSFER_KEYS = {"unit_labels", "carry_sprites", "sick", "age"}   -- per-unit plain tables migrated on swap

-- A launch needs a platform hub, a training centre, a volunteer and a free destination surface. The last two
-- are facts supplied by the adapter; the rule only decides whether the numbers allow it.
---@param pop integer|nil
---@param tick number|nil
---@param ready_at number|nil
---@param has_hub boolean|nil
---@param has_center boolean|nil
---@return boolean
function M.can_launch(pop, tick, ready_at, has_hub, has_center)
  if not (has_hub and has_center) then return false end
  return (pop or 0) > 4 and (ready_at == nil or tick == nil or tick >= ready_at)
end

-- What the pod carries: one packed colonist (itself a Cryo-Colonist Pod item).
---@return ItemCount
function M.manifest()
  local out = {}
  for item, n in pairs(M.MANIFEST) do out[item] = n end
  return out
end

return M
