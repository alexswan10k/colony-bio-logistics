-- PURE: choose a job for an idle colonist, driven by the colony's priority matrix (design §4.1, #27).
--   1. Logistics first: while hauling is enabled and below its share, keep the colony hauling or houses starve.
--   2. Otherwise take the best-ranked enabled harvest job that still has a free tooled slot. Jobs sharing a
--      rank are one group and split the workforce by the food ratio (so the default matrix behaves as before).
--   3. If no harvest slot is free, haul (rather than stand around); idle only if hauling is off too.
local M = {}
local jobs = require("scripts.model.jobs")
local construct = require("scripts.model.construct")

M.JOBS = jobs.JOBS          -- haul first: wins ties (keeps houses supplied)
M.HAUL_SHARE = 0.3
M.HARVEST = {"forage", "farm", "chop", "mine", "hunt", "fish"}

-- food_ratio = stock/target; returns the share of non-hauling colonists each hut job should get.
function M.desired_shares(food_ratio)
  if food_ratio < 0.5 then return {forage = 0.3, hunt = 0.1, fish = 0.1, farm = 0.25, chop = 0.15, mine = 0.1}
  elseif food_ratio < 1 then return {forage = 0.2, hunt = 0.1, fish = 0.1, farm = 0.2, chop = 0.2, mine = 0.2}
  else return {forage = 0.1, hunt = 0.1, fish = 0.1, farm = 0.15, chop = 0.3, mine = 0.25} end
end

-- How many colonists should be hauling at this population (at least one, or nothing gets delivered).
function M.haul_target(pop)
  if pop <= 0 then return 0 end
  return math.max(1, math.floor(M.HAUL_SHARE * pop + 0.5))
end

-- s = {food_ratio=, counts={job->n}, slots={job->free tooled slots}, capacity={job->tooled slots},
--      pop=, haul=bool, priority={job->rank}}. `pop` excludes the colonist being assigned.
-- Returns a job name or nil.
function M.choose(s)
  local counts, slots, capacity = s.counts or {}, s.slots or {}, s.capacity or {}
  local pop = s.pop or 0
  local priority = s.priority
  local haul_on = jobs.enabled(priority, "haul")

  if haul_on and s.haul and pop > 0 and (counts.haul or 0) < M.haul_target(pop) then return "haul" end

  -- Construction (#37): build/repair when it ranks at least as high as the best harvest job, capped to a
  -- share of the colony so a wall never costs the town its dinner.
  local c_rank = jobs.rank(priority, "construct")
  if c_rank > 0 and (slots.construct or 0) > 0 and (counts.construct or 0) < construct.builders(pop) then
    local harvest_rank = jobs.best_rank(priority, M.HARVEST, slots)
    if not harvest_rank or c_rank <= harvest_rank then return "construct" end
  end

  local rank = jobs.best_rank(priority, M.HARVEST, slots)
  if rank then
    local shares = M.desired_shares(s.food_ratio)
    local best, best_gap
    for _, job in ipairs(M.HARVEST) do
      if (slots[job] or 0) > 0 and jobs.rank(priority, job) == rank then
        local wanted = math.max(shares[job] * (1 - M.HAUL_SHARE) * pop, math.min(1, capacity[job] or 0))
        local gap = wanted - (counts[job] or 0)
        if not best_gap or gap > best_gap then best, best_gap = job, gap end
      end
    end
    if best then return best end
  end

  if haul_on and s.haul and pop > 0 then return "haul" end
  return nil
end

return M
