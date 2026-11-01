-- PURE: choose a job for an idle colonist so the colony tracks desired labour shares.
-- Shares shift toward foraging when food stock is below target. No priority UI yet (see jobs.lua for the later matrix).
local M = {}
M.JOBS = {"haul", "forage", "chop", "mine"}   -- haul first: wins ties (keeps houses supplied)
M.HAUL_SHARE = 0.3

-- food_ratio = stock/target; counts = {job -> colonists currently on it}; returns job name.
function M.desired_shares(food_ratio)
  if food_ratio < 0.5 then return {forage = 0.6, chop = 0.2, mine = 0.2}
  elseif food_ratio < 1 then return {forage = 0.4, chop = 0.3, mine = 0.3}
  else return {forage = 0.2, chop = 0.4, mine = 0.4} end
end

function M.choose(food_ratio, counts, disabled)
  local shares, total = M.desired_shares(food_ratio), 0
  for j, v in pairs(shares) do shares[j] = v * (1 - M.HAUL_SHARE) end
  shares.haul = M.HAUL_SHARE
  for _, j in ipairs(M.JOBS) do total = total + (counts[j] or 0) end
  local best, best_gap
  for _, j in ipairs(M.JOBS) do
    if not (disabled and disabled[j]) then
      local gap = shares[j] - (total > 0 and (counts[j] or 0) / total or 0)
      if not best_gap or gap > best_gap then best, best_gap = j, gap end
    end
  end
  return best
end

return M
