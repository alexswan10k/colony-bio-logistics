---@diagnostic enable: undefined-field, missing-fields
-- PURE model (no Factorio API). PROPOSAL for decision #16 - weights/scales are tunable params, not truth.
-- All inputs normalised to 0..1. D roughly in [-1.5, 1]; migration enters above `params.migrate_in`.
local M = {}

M.defaults = {
  w_food = 0.35, w_housing = 0.20, w_scenic = 0.20, w_leisure = 0.25,
  w_recreation = 0.15,        -- share of the town served by a stocked Tavern (#48): a bonus, so 0 costs nothing
  w_pollution = 0.6,
  w_sickness = 0.3,           -- share of the town that is ill (#47): a penalty
  pollution_cap = 1.0,        -- pollution normalised so 1.0 = "terrible"
  death_penalty = 0.15,       -- per recent death
  death_halflife = 6,         -- intervals
  migrate_in = 0.15, leave_below = -0.10,
  leave_rate = 0.10,          -- at worst, this fraction of the town packs up per interval
  leave_span = 0.50,          -- how far below leave_below D has to fall for the full rate (#29)
  w_tents = 0.05,             -- every tent drags desirability down; a tent town plateaus
  tent_cap = 8,               -- ...but the penalty stops growing at this many tents, so tents alone are not a doom spiral
  w_jobs = 0.35,              -- open job slots are a big pull factor (jobs draw people in)
  jobs_full = 6,              -- open slots needed for the full bonus
  w_privacy = 0.15,           -- bonus for houses that are empty or hold a single colonist
  w_commute = 0.05,            -- short walks to work are a small pull (#93): a bonus, so no jobs costs nothing
  commute_far = 48,            -- tiles at which the commute bonus reaches zero
}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
M.clamp = clamp

-- How pleasant a commute is, 0..1: 1 = the colonist works next door, 0 = `far` tiles or worse (#93).
-- Only colonists with a job are averaged, so a town with nothing to do scores 0 (no bonus, never a penalty).
function M.commute_score(avg_dist, far)
  far = far or M.defaults.commute_far
  if not avg_dist or avg_dist <= 0 then return 1 end
  if far <= 0 then return 0 end
  return clamp(1 - avg_dist / far, 0, 1)
end

-- inputs: food_ratio (stock / target stock), free_housing_ratio, scenic, leisure, recreation (0..1), pollution (0..1+),
-- sickness (share of the town ill, 0..1), tents (number of tents), open_jobs (unfilled hut slots),
-- privacy (0..1: houses that are empty or single-occupancy pull), commute (0..1: see `commute_score`),
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
    sickness = -(p.w_sickness or 0) * clamp(inp.sickness or 0, 0, 1),
    tents = -p.w_tents * math.min(math.max(inp.tents or 0, 0), p.tent_cap),
    jobs = p.w_jobs * clamp((inp.open_jobs or 0) / p.jobs_full, 0, 1),
    privacy = p.w_privacy * clamp(inp.privacy or 0, 0, 1),
    commute = (p.w_commute or 0) * clamp(inp.commute or 0, 0, 1),
  }
  local d = 0
  for _, v in pairs(parts) do d = d + v end
  return d, parts
end

return M
