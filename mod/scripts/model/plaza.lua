---@diagnostic enable: undefined-field, missing-fields
-- PURE: Scenic Plazas (#48 slice B). Each Plaza inside the Town Hall's scenic sample radius adds a small,
-- flat amount to the colony's scenic score. Decorative and free: no workers, no upkeep, no consumable. The
-- adapter adds the result as a SEPARATE term AFTER desirability's existing sum so an untouched town is
-- bit-for-bit unchanged. No Factorio globals; positions here are plain {x=, y=} tables.
local M = {}

M.STEP = 0.2   -- scenic score added per in-radius Plaza
M.CAP = 0.4    -- ...but two Plazas are enough; extras are free decoration, not more scenery

-- Is `pos` within `radius` of `centre`? Squared distance <= radius^2. Missing arguments read as "no", so a
-- half-built panel with a nil position can never throw or (worse) count as in range.
function M.in_radius(pos, centre, radius)
  if not pos or not centre or not radius then return false end
  local dx, dy = pos.x - centre.x, pos.y - centre.y
  return dx * dx + dy * dy <= radius * radius
end

-- Scenic score for `count` in-radius Plazas: max(0, min(CAP, count * STEP)). Plain float, no rounding.
function M.bonus(count)
  return math.max(0, math.min(M.CAP, (count or 0) * M.STEP))
end

return M
