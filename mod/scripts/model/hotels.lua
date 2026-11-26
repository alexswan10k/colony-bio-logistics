---@diagnostic enable: undefined-field, missing-fields
-- PURE: Grand Hotel tier (#69, design §6.3). The top of the Spa -> Resort -> Grand Hotel tourism ladder:
-- eight visitors at once, three Cultural Insights per visitor brought home, and an ale upkeep that a Spa and
-- a Resort do not have. A Grand Hotel only earns its premium while it can serve every guest a drink.
local M = {}

M.GRAND = "colony-grand-hotel"
M.CAPACITY = 8
M.INSIGHT_MULT = 3
M.ALE = "colony-ale"
M.ALE_PER_VISITOR = 1

---@param ale integer|nil
---@param visitors integer|nil
---@return integer guests who can actually be served
function M.served(ale, visitors)
  return math.max(0, math.min(visitors or 0, ale or 0))
end

-- A Grand Hotel with too little ale earns only the Resort rate (or the Spa rate if it has neither bonus).
---@param served integer|nil
---@param guests integer|nil
---@return boolean
function M.premium(served, guests)
  return (guests or 0) > 0 and (served or 0) >= guests
end

return M
