---@diagnostic enable: undefined-field, missing-fields
-- PURE: Resorts (#69, design §6.3). A worker-free, consumable-free amenity that hosts four tourists (a Spa
-- holds two) and doubles the Cultural Insights a completed visit pays home. It is an UPGRADE of the tourism
-- slice, not a second tourism system: the same coach trips, visit timers and payout predicate apply. All
-- numbers live here so the offline tests can pin them; the adapter only counts buildings and sets flags.
local M = {}

M.RESORT = "colony-resort"
M.CAPACITY = 4                  -- visitors per Resort (a Spa holds 2)
M.INSIGHT_MULT = 2              -- insights per rider when the host visit was at a Resort
M.W_HOSPITALITY = 0.10          -- host desirability per visitor (a Spa is 0.05)
M.HOSPITALITY_CAP = 4

---@param spas integer|nil
---@param resorts integer|nil
---@param visiting integer|nil
---@param inbound integer|nil
---@param waiting integer|nil
---@return integer free visitor places at a host after all reservations
function M.host_capacity(spas, resorts, visiting, inbound, waiting)
  return math.max(0, 2 * (spas or 0) + M.CAPACITY * (resorts or 0)
    - (visiting or 0) - (inbound or 0) - (waiting or 0))
end

---@param has_resort boolean|nil
---@param visitors integer|nil
---@return number hospitality stat fed to desirability (a Resort host gets double weight)
function M.hospitality(has_resort, visitors)
  return has_resort and (visitors or 0) * 2 or (visitors or 0)
end

---@param has_resort boolean|nil
---@param paid integer|nil
---@return integer
function M.insights(has_resort, paid)
  return has_resort and (paid or 0) * M.INSIGHT_MULT or (paid or 0)
end

return M
