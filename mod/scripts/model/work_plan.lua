-- PURE: choose a job for an idle colonist. Two rules, in order:
--   1. Logistics first: keep a share of the colony hauling while there is haul work, or houses starve.
--   2. Staff the player's labour huts: a hut with tools and a free slot wants at least one worker
--      (building a hut and filling it with tools IS the player's instruction until #17's priority matrix).
--      The food ratio shifts the rest of the workforce toward foraging when stocks run low.
local M = {}
M.JOBS = {"haul", "forage", "chop", "mine"}   -- haul first: wins ties (keeps houses supplied)
M.HAUL_SHARE = 0.3

-- food_ratio = stock/target; returns the share of non-hauling colonists each hut job should get.
function M.desired_shares(food_ratio)
  if food_ratio < 0.5 then return {forage = 0.6, chop = 0.2, mine = 0.2}
  elseif food_ratio < 1 then return {forage = 0.4, chop = 0.3, mine = 0.3}
  else return {forage = 0.2, chop = 0.4, mine = 0.4} end
end

-- How many colonists should be hauling at this population (at least one, or nothing gets delivered).
function M.haul_target(pop)
  if pop <= 0 then return 0 end
  return math.max(1, math.floor(M.HAUL_SHARE * pop + 0.5))
end

-- s = {food_ratio=, counts={job->n}, slots={job->free tooled slots}, capacity={job->tooled slots},
--      pop=, haul=bool}. `pop` excludes the colonist being assigned. Returns a job name or nil.
function M.choose(s)
  local counts, slots, capacity = s.counts or {}, s.slots or {}, s.capacity or {}
  local pop = s.pop or 0
  if s.haul and pop > 0 and (counts.haul or 0) < M.haul_target(pop) then return "haul" end
  local shares = M.desired_shares(s.food_ratio)
  local best, best_gap
  for _, job in ipairs(M.JOBS) do
    if job ~= "haul" and (slots[job] or 0) > 0 then
      local wanted = math.max(shares[job] * (1 - M.HAUL_SHARE) * pop, math.min(1, capacity[job] or 0))
      local gap = wanted - (counts[job] or 0)
      if not best_gap or gap > best_gap then best, best_gap = job, gap end
    end
  end
  if best then return best end
  if s.haul and pop > 0 then return "haul" end   -- no free hut slot: haul rather than stand around
  return nil
end

return M
