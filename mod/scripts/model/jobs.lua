-- PURE model: priority-matrix job selection (RimWorld-style). Lower rank number = higher priority; nil/0 = disabled.
-- Note design doc inconsistency: 5 job types vs "ranked 1 to 4" (issue #17). JOBS list is the single source of truth.
local M = {}
M.JOBS = {"guard", "doctor", "construct", "haul", "harvest"}

-- priorities: {job -> rank|nil}; available: {job -> count of open tasks}. Ties broken by M.JOBS order. Returns job name or nil.
function M.pick(priorities, available)
  local best, best_rank
  for _, job in ipairs(M.JOBS) do
    local rank = priorities[job]
    if rank and rank > 0 and (available[job] or 0) > 0 then
      if not best_rank or rank < best_rank then best, best_rank = job, rank end
    end
  end
  return best
end

return M
