---@diagnostic enable: undefined-field, missing-fields
-- PURE: Space Platform EVA Crew (#69, design §9.3). A colonist on a platform needs a jetpack issued from a
-- built EVA Airlock to work at full speed outside the dome; without either, work spells take twice as long.
-- The airlock also bounds where an EVA task can happen. All rules are numbers/positions; the adapter owns
-- the live registry and inventories. A ground colony never reads these rules.
local M = {}

M.JETPACK = "colony-eva-jetpack"
M.AIRLOCK = "colony-eva-airlock"
M.RADIUS = 24
M.PENALTY = 0.5

---@param on_platform boolean|nil
---@param ready boolean|nil an airlock exists and a jetpack is in stock
---@return number
function M.work_mult(on_platform, ready)
  return on_platform and not ready and M.PENALTY or 1
end

---@param base number
---@param on_platform boolean|nil
---@param ready boolean|nil
---@return number
function M.work_ticks(base, on_platform, ready)
  return math.ceil(base * M.work_mult(on_platform, ready))
end

---@param pos table|nil
---@param airlock table|nil
---@return boolean
function M.in_radius(pos, airlock)
  if not (pos and airlock) then return false end
  local dx, dy = pos.x - airlock.x, pos.y - airlock.y
  return dx * dx + dy * dy <= M.RADIUS * M.RADIUS
end

return M
