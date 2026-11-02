-- PURE: how scenic a colony's surroundings are (#29). The adapter only counts things in the world; this
-- turns those counts into the 0..1 `scenic` term of the desirability formula, and the pollution reading into
-- its 0..1 `pollution` term. Both are deliberately boring so sim/ can tune them without a game.
local M = {}

-- A forest of ~35% tree cover already scores full marks; a lake of 15% water likewise. Paving is a real
-- penalty because the colony paves its own centre, which gives the player a reason to leave greenery.
M.TREE_FULL = 0.35
M.WATER_FULL = 0.15
M.BUILT_FULL = 0.50
M.WEIGHTS = {tree = 0.70, water = 0.30, built = 0.60}

-- Pollution at the hall that counts as "terrible" (get_pollution() units). Mining pollutes 2 per trip
-- (work.MINE_POLLUTION), so a big mine is felt but has to work at it.
M.POLLUTION_BAD = 300

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
M.clamp = clamp

local BUILT = {
  ["stone-path"] = true, ["landfill"] = true, ["tutorial-grid"] = true, ["lab-dark-1"] = true,
  ["lab-dark-2"] = true, ["lab-white"] = true, ["foundation"] = true, ["ice-platform"] = true,
}
-- Substrings rather than a full tile list: it covers vanilla concrete variants, Space Age soils and
-- anything a mod adds that calls itself paving.
local BUILT_PARTS = {"concrete", "hazard", "artificial", "platform", "paving"}

function M.is_built(name)
  if not name then return false end
  if BUILT[name] then return true end
  for _, part in ipairs(BUILT_PARTS) do
    if name:find(part, 1, true) then return true end
  end
  return false
end

function M.is_water(name)
  return name ~= nil and name:find("water", 1, true) ~= nil
end

-- census = {tree_cover=, water_cover=, built_cover=} as fractions of the sampled area (0..1, may exceed).
-- Returns scenic (0..1) and its parts so the GUI/debug overlay can explain the number.
function M.score(census)
  local tree = clamp((census.tree_cover or 0) / M.TREE_FULL, 0, 1)
  local water = clamp((census.water_cover or 0) / M.WATER_FULL, 0, 1)
  local built = clamp((census.built_cover or 0) / M.BUILT_FULL, 0, 1)
  local parts = {tree = M.WEIGHTS.tree * tree, water = M.WEIGHTS.water * water,
    built = -M.WEIGHTS.built * built}
  local total = 0
  for _, v in pairs(parts) do total = total + v end
  return clamp(total, 0, 1), parts
end

-- get_pollution() at the hall -> 0..1 for the desirability formula.
function M.pollution_ratio(pollution, bad)
  return clamp((pollution or 0) / (bad or M.POLLUTION_BAD), 0, 1)
end

return M
