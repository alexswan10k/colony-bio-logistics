---@diagnostic enable: undefined-field, missing-fields
-- PURE: Nurseries (#69, design §9.1). Off-world colonies have no organic migration, so their growth comes
-- from natural reproduction in a pressurised Nursery. Without one within RADIUS of a house, a hostile-world
-- or platform house cannot breed; with one, the birth chance is doubled. Nauvis/Gleba keep the normal chance.
local breeding = require("scripts.model.breeding")

local M = {}

M.NURSERY = "colony-nursery"
M.RADIUS = 24
M.EXOTIC_MULT = 2

---@param exotic boolean|nil
---@param has_nursery boolean|nil
---@return number birth chance per eligible house per evaluation
function M.birth_chance(exotic, has_nursery)
  if not exotic then return breeding.BREED_P end
  return has_nursery and breeding.BREED_P * M.EXOTIC_MULT or 0
end

---@param pos table|nil
---@param centre table|nil
---@param radius number|nil
---@return boolean
function M.in_radius(pos, centre, radius)
  if not (pos and centre) then return false end
  local dx, dy = pos.x - centre.x, pos.y - centre.y
  local r = radius or M.RADIUS
  return dx * dx + dy * dy <= r * r
end

return M
