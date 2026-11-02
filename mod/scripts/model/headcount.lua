-- PURE: workforce headcount quotas and targets (#73).
-- Allows the player to steer the colony's workforce by setting target headcounts per job
-- from the Town Hall without having to micro-manage individual house rosters.
local M = {}
local jobs = require("scripts.model.jobs")

-- Target headcount for job (nil = automatic).
function M.target(targets, job)
  if targets and targets[job] ~= nil then
    local n = tonumber(targets[job])
    if n and n >= 0 then return math.floor(n) end
  end
  return nil
end

-- Set target for job (nil or "auto" or negative = automatic).
function M.set_target(targets, job, val)
  if not targets then return end
  if val == nil or val == "auto" or (tonumber(val) and tonumber(val) < 0) then
    targets[job] = nil
  else
    targets[job] = math.max(0, math.floor(tonumber(val) or 0))
  end
  return targets[job]
end

-- Move target up or down. If currently nil (auto), delta > 0 sets to current_count + 1 (min 1);
-- delta < 0 sets to 0. If currently numeric, shifts by delta; < 0 wraps back to nil (auto).
function M.shift_target(current_target, delta, current_count)
  delta = tonumber(delta) or 0
  if current_target == nil then
    if delta > 0 then
      return math.max(1, math.floor((current_count or 0) + 1))
    elseif delta < 0 then
      return 0
    else
      return nil
    end
  else
    local n = math.floor(current_target + delta)
    if n < 0 then
      return nil
    else
      return n
    end
  end
end

-- True if job has an explicit headcount target that has been reached or exceeded.
function M.is_capped(targets, job, current_count)
  local tgt = M.target(targets, job)
  if tgt == nil then return false end
  return (current_count or 0) >= tgt
end

-- Deficit under target (> 0 means job needs more workers). Nil if auto.
function M.deficit(targets, job, current_count)
  local tgt = M.target(targets, job)
  if tgt == nil then return nil end
  return math.max(0, tgt - (current_count or 0))
end

-- Effective targets dictionary for all jobs.
function M.effective(targets)
  local out = {}
  for _, job in ipairs(jobs.JOBS) do
    out[job] = M.target(targets, job)
  end
  return out
end

return M
