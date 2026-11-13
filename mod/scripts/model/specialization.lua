---@diagnostic enable: undefined-field, missing-fields
-- PURE: which specialization a colony has earned (#46). Each type (coast / fertile / forest / industrial) is
-- scored from the hut composition the player chooses to build there - a town builds docks near shore,
-- farm huts on farmland, woodcutters in forests and miners beside ore, because those buildings are gated by
-- the terrain they want. The dominant type (unique) names the specialization; the work loop turns it into a
-- small per-trip yield bonus. The live hut counts are read on demand, no tile sampling.
local M = {}

M.MINERS_FULL = 3            -- this many mining huts registers the town as industrial
M.MIN_COAST = 1              -- docks or salt pans needed to call it a coast town
M.MIN_FERTILE = 1            -- farm huts needed to call it a farm town
M.MIN_FOREST = 1             -- woodcutters/foresters/hunters needed to call it a forest town
M.ORDER = {"coast", "fertile", "forest", "industrial"}   -- tie-break: coast wins an exact tie, deterministic

local JOB_TO_SPEC = {
  fish = "coast",
  farm = "fertile",
  chop = "forest",
  forest = "forest",
  hunt = "forest",
  mine = "industrial",
}

local NAME_TO_SPEC = {
  ["colony-salt-pan"] = "coast",
}

-- huts: array of {name=, job=} (adapter walks colony.huts and salt pans). Returns per-type hut counts, not tile sampling.
function M.census(huts)
  local c = {coast = 0, fertile = 0, forest = 0, industrial = 0}
  for _, h in ipairs(huts or {}) do
    local spec = JOB_TO_SPEC[h.job] or NAME_TO_SPEC[h.name]
    if spec then c[spec] = c[spec] + 1 end
  end
  return c
end

-- census = {coast=, fertile=, forest=, industrial=} as *hut counts*. Returns (parts, dominant).
-- Each part is huts / its own bar, clamped to 1; the bar for industrial is higher (miners stack).
function M.score(census)
  local c = census or {}
  local parts = {
    coast = math.min(1, (c.coast or 0) / M.MIN_COAST),
    fertile = math.min(1, (c.fertile or 0) / M.MIN_FERTILE),
    forest = math.min(1, (c.forest or 0) / M.MIN_FOREST),
    industrial = math.min(1, (c.industrial or 0) / M.MINERS_FULL),
  }
  local best, best_v, tie = nil, -1, false
  for _, k in ipairs(M.ORDER) do
    local v = parts[k]
    if v > best_v then best, best_v, tie = k, v, false
    elseif v == best_v then tie = true end
  end
  if best and not tie and best_v >= 1 then return parts, best end
  return parts, nil
end

-- Dominant specialization only (nil on a tie or when nothing is routed to a job).
function M.dominant(census)
  local _, best = M.score(census)
  return best
end

-- Per-trip yield bonus (+1 item) for the matching job. Kept small:
--   coast -> fishing, forest -> chopping, industrial -> mining, fertile -> farming.
function M.bonus(spec, job)
  if spec == "coast" and job == "fish" then return 1 end
  if spec == "forest" and job == "chop" then return 1 end
  if spec == "industrial" and job == "mine" then return 1 end
  if spec == "fertile" and job == "farm" then return 1 end
  return 0
end

return M
