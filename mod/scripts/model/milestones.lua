---@diagnostic enable: undefined-field, missing-fields
-- PURE: colony milestones. Each is a scripted-trigger technology that unlocks the next band of buildings once
-- the force's biggest colony reaches it, so a new player starts with the Town Hall and a handful of huts
-- instead of twenty recipes, and the native tech tree shows what comes next and what it takes.
local M = {}

-- In order: each milestone is the prerequisite of the next, and the thresholds only ever rise.
M.LIST = {
  {tech = "colony-settlement", halls = 1},
}

local function met(m, f)
  if m.halls and (f.halls or 0) < m.halls then return false end
  if m.pop and (f.pop or 0) < m.pop then return false end
  return true
end

-- Milestones to complete now, in order. facts = {halls = n, pop = best colony population};
-- researched = {tech -> true}. Stops at the first unmet one, so the chain is never skipped.
function M.due(f, researched)
  local out = {}
  for _, m in ipairs(M.LIST) do
    if not researched[m.tech] then
      if not met(m, f) then break end
      out[#out + 1] = m.tech
    end
  end
  return out
end

-- The next milestone still ahead, as {tech, need, have} (need/have in colonists, or halls), or nil when done.
function M.next(f, researched)
  for _, m in ipairs(M.LIST) do
    if not researched[m.tech] then
      if m.pop then return {tech = m.tech, need = m.pop, have = f.pop or 0} end
      return {tech = m.tech, need = m.halls, have = f.halls or 0}
    end
  end
  return nil
end

return M
