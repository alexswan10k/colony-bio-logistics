-- PURE model: per-colony priority matrix (design §4.1, issues #17/#27).
-- Lower rank = more important; 0 = the role is switched off. Ranks may repeat: jobs sharing a rank form
-- one priority group and split the workforce by work_plan.desired_shares, so the default matrix keeps the
-- old food-ratio behaviour while letting the player force a role ahead of everything else.
local M = {}

-- Implemented roles. Guard/doctor join this list when those jobs land (#47).
M.JOBS = {"haul", "forage", "chop", "mine", "farm", "hunt", "fish", "preserve", "construct"}
M.MAX_RANK = 4
-- Haul rank 1, the harvest roles and construction in one rank-2 group: harvesting splits by food ratio,
-- and construction is capped to its own share of the workforce (construct.builders) rather than a food share.
M.DEFAULT = {haul = 1, forage = 2, chop = 2, mine = 2, farm = 2, hunt = 2, fish = 2, preserve = 2,
  construct = 2}

function M.defaults()
  local out = {}
  for _, job in ipairs(M.JOBS) do out[job] = M.DEFAULT[job] end
  return out
end

local function clamp_rank(r)
  r = math.floor(tonumber(r) or 0)
  if r < 0 then return 0 end
  if r > M.MAX_RANK then return M.MAX_RANK end
  return r
end

-- Effective rank of `job` (0 = disabled). Missing/unknown stored values fall back to the default,
-- so colonies saved before the matrix existed keep working without a migration.
function M.rank(priority, job)
  local r = priority and priority[job]
  if r == nil then r = M.DEFAULT[job] end
  return clamp_rank(r)
end

function M.enabled(priority, job) return M.rank(priority, job) > 0 end

function M.set(priority, job, rank) priority[job] = clamp_rank(rank) end

-- Move one job up (-1) or down (+1) a rank; 0 disables it. Ranks may collide: that is how groups form.
function M.shift(priority, job, delta)
  M.set(priority, job, M.rank(priority, job) + delta)
  return priority
end

-- Effective matrix as a complete {job -> rank} table (defaults filled in) for the GUI.
function M.effective(priority)
  local out = {}
  for _, job in ipairs(M.JOBS) do out[job] = M.rank(priority, job) end
  return out
end

-- Lowest enabled rank among `jobs` that still have a free tooled slot; nil if none can be worked.
function M.best_rank(priority, jobs_list, slots)
  local best
  for _, job in ipairs(jobs_list) do
    if (slots[job] or 0) > 0 then
      local r = M.rank(priority, job)
      if r > 0 and (not best or r < best) then best = r end
    end
  end
  return best
end

-- Generic picker for the design's five abstract roles (kept from #17): best-ranked job with open tasks.
-- priorities: {job -> rank|nil}; available: {job -> count of open tasks}. Ties broken by M.JOBS order.
function M.pick(priorities, available)
  local best, best_rank
  for _, job in ipairs({"guard", "doctor", "construct", "haul", "harvest"}) do
    local rank = priorities[job]
    if rank and rank > 0 and (available[job] or 0) > 0 then
      if not best_rank or rank < best_rank then best, best_rank = job, rank end
    end
  end
  return best
end

return M
