---@diagnostic enable: undefined-field, missing-fields
-- PURE: Vulcanus integration (#70). An off-world surface has no pollutant type at all (s22_dome: nil on
-- Vulcanus/Fulgora/Aquilo and on platforms), so ambient risk here is driven by planet identity and distance
-- to a pressurized Habitat Dome -- never by pollution, temperature or any other unreadable surface property.
--   * Heat Stroke: an on-duty colonist working in the open on Vulcanus bakes after a long enough shift;
--     a dome's conditioned air makes its immediate surroundings safe. Fatal untreated, cured at a Clinic.
-- Every number lives here so the adapter only reads surfaces and the illness model only reads these rules.
local M = {}

M.PLANET = "vulcanus"
M.DISEASE = "heat_stroke"

M.DOME_SAFE = 6       -- tiles from a live Habitat Dome: conditioned air, no heat risk
M.HEAT_SCALE = 18     -- extra tiles past the safe ring for full exposure
M.HEAT_RATE = 0.03    -- chance per evaluation at full exposure
M.FATAL_AFTER = 20    -- evaluations untreated before it kills

-- Exposure in [0, 1]. `nearest_dome` is the distance in tiles to the closest live dome on the colonist's
-- own surface, or nil when there is none. No dome means the full open-air risk; nil/zero/negative distances
-- are treated as inside the safe ring. Plain floats, no rounding -- the illness roll does the comparison.
function M.exposure(nearest_dome)
  if nearest_dome == nil then return 1 end
  if nearest_dome <= M.DOME_SAFE then return 0 end
  return math.min(1, (nearest_dome - M.DOME_SAFE) / M.HEAT_SCALE)
end

return M
