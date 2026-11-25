---@diagnostic enable: undefined-field, missing-fields
-- PURE: Cryo-Colonist Pods (#69, design §9.2). A pod is a colonist in cold storage: its 20-minute spoil timer
-- IS the life-support budget. A refill recipe with `result_is_always_fresh` resets the timer from rations and
-- water, so a pod waiting on a platform never has to be thrown away. An unpacked pod becomes a colonist in a
-- Habitat Dome with a free bed. All rules here are plain numbers; the adapter owns live inventories and units.
local M = {}

M.POD = "colony-cryo-pod"
M.SHELF_TICKS = 20 * 60 * 60
M.REFILL_AT = 0.5       -- below this spoil fraction a pod is fine; at/above it, refill before launching

---@param spoil_percent number|nil
---@return boolean
function M.needs_refill(spoil_percent)
  return (spoil_percent or 0) >= M.REFILL_AT
end

-- Whether a pod can be unpacked here: a free bed and a pod in stock. The adapter removes exactly one pod
-- after this check and spawns an adult colonist at the dome.
---@param stock ItemCount|nil
---@param beds_free integer|nil
---@return boolean
function M.can_unpack(stock, beds_free)
  return (beds_free or 0) >= 1 and (stock and (stock[M.POD] or 0) > 0 or false)
end

return M
