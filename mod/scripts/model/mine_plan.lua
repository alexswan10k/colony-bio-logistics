-- PURE: which ore a Miner's Hut works first (design §4.1, issue #74).
-- Lower rank = mined first; 0 = the hut ignores that ore. Ores sharing a rank fall back to distance, so
-- the default (everything rank 1) is exactly the old nearest-first behaviour: a hut only stops grabbing
-- the closest rock when the player says which rock matters.
local M = {}

M.ORES = {"iron-ore", "copper-ore", "coal", "stone"}
M.MAX_RANK = 4
M.DEFAULT = 1

M.INDEX = {}
for i, ore in ipairs(M.ORES) do M.INDEX[ore] = i end

local function clamp_rank(r)
  r = math.floor(tonumber(r) or 0)
  if r < 0 then return 0 end
  if r > M.MAX_RANK then return M.MAX_RANK end
  return r
end

function M.valid(ore) return M.INDEX[ore] ~= nil end

-- Effective rank of `ore` (0 = off). Missing values fall back to the default, so huts built before this
-- feature (no `ores` table) keep mining everything nearest-first.
function M.rank(priority, ore)
  local r = priority and priority[ore]
  if r == nil then r = M.DEFAULT end
  return clamp_rank(r)
end

function M.enabled(priority, ore) return M.rank(priority, ore) > 0 end

function M.set(priority, ore, rank) priority[ore] = clamp_rank(rank) end

-- Move one ore up (-1) or down (+1); 0 switches it off.
function M.shift(priority, ore, delta)
  M.set(priority, ore, M.rank(priority, ore) + delta)
  return priority
end

-- Effective priorities as a complete {ore -> rank} table (defaults filled in) for the GUI.
function M.effective(priority)
  local out = {}
  for _, ore in ipairs(M.ORES) do out[ore] = M.rank(priority, ore) end
  return out
end

-- Enabled ores, most important first. Ties keep M.ORES order so the pick is deterministic.
function M.order(priority)
  local out = {}
  for _, ore in ipairs(M.ORES) do
    local r = M.rank(priority, ore)
    if r > 0 then out[#out + 1] = {ore = ore, rank = r} end
  end
  table.sort(out, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return M.INDEX[a.ore] < M.INDEX[b.ore]
  end)
  local names = {}
  for i, e in ipairs(out) do names[i] = e.ore end
  return names
end

-- Group enabled ores by rank: returns array of {rank = r, ores = {ore, ...}} sorted best rank (1) to worst.
function M.by_rank(priority)
  local groups = {}
  for rank = 1, M.MAX_RANK do
    local list = {}
    for _, ore in ipairs(M.ORES) do
      if M.rank(priority, ore) == rank then list[#list + 1] = ore end
    end
    if #list > 0 then groups[#groups + 1] = {rank = rank, ores = list} end
  end
  return groups
end

return M
