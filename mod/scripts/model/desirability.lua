-- PURE model (no Factorio API). PROPOSAL for decision #16 - weights/scales are tunable params, not truth.
-- All inputs normalised to 0..1. D roughly in [-1.5, 1]; migration enters above `params.migrate_in`.
local M = {}

M.defaults = {
  w_food = 0.35, w_housing = 0.20, w_scenic = 0.20, w_leisure = 0.25,
  w_recreation = 0.15,        -- share of the town served by a stocked Tavern (#48): a bonus, so 0 costs nothing
  w_pollution = 0.6,
  pollution_cap = 1.0,        -- pollution normalised so 1.0 = "terrible"
  death_penalty = 0.15,       -- per recent death
  death_halflife = 6,         -- intervals
  migrate_in = 0.15, leave_below = -0.10,
  leave_rate = 0.10,          -- at worst, this fraction of the town packs up per interval
  leave_span = 0.50,          -- how far below leave_below D has to fall for the full rate (#29)
}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
M.clamp = clamp

-- inputs: food_ratio (stock / target stock), free_housing_ratio, scenic, leisure, recreation (0..1), pollution (0..1+),
-- deaths = list of ages (intervals), death_halflife = optional override (a Cemetery shortens mourning, #53)
function M.compute(inp, p)
  p = p or M.defaults
  local death_pen = 0
  local halflife = inp.death_halflife or p.death_halflife
  for _, age in ipairs(inp.deaths or {}) do death_pen = death_pen + p.death_penalty * 0.5 ^ (age / halflife) end
  local parts = {
    food = p.w_food * clamp(inp.food_ratio, 0, 1),
    housing = p.w_housing * clamp(inp.free_housing_ratio, 0, 1),
    scenic = p.w_scenic * clamp(inp.scenic or 0, 0, 1),
    leisure = p.w_leisure * clamp(inp.leisure or 0, 0, 1),
    recreation = (p.w_recreation or 0) * clamp(inp.recreation or 0, 0, 1),
    pollution = -p.w_pollution * clamp(inp.pollution or 0, 0, p.pollution_cap),
    deaths = -death_pen,
  }
  local d = 0
  for _, v in pairs(parts) do d = d + v end
  return d, parts
end

return M
