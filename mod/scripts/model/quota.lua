-- PURE: harvest quotas and yield targets (#84).
-- Determines whether a resource has reached its production cap.
local M = {}

M.DEFAULT_QUOTA = 200

M.RESOURCES = {
  ["iron-ore"] = {job = "mine"},
  ["copper-ore"] = {job = "mine"},
  ["coal"] = {job = "mine"},
  ["stone"] = {job = "mine"},
  ["wood"] = {job = "chop"},
  ["colony-forage"] = {job = "forage"},
  ["colony-meat"] = {job = "hunt"},
  ["colony-fish"] = {job = "fish"},
  ["colony-produce"] = {job = "farm"},
}

-- Target quota for item (0 or nil = unlimited).
function M.target(quotas, global_settings, item)
  if quotas and quotas[item] ~= nil then
    return tonumber(quotas[item]) or 0
  end
  if global_settings and global_settings[item] then
    return tonumber(global_settings[item]) or 0
  end
  return 0
end

-- True if current count has met or exceeded target (> 0).
function M.met(target, current)
  if not target or target <= 0 then return false end
  return (current or 0) >= target
end

-- Filter a list of resources (e.g. mine ores), removing any that reached their quota.
function M.open_resources(items, quotas, global_settings, counts)
  local open = {}
  for _, item in ipairs(items or {}) do
    local tgt = M.target(quotas, global_settings, item)
    if not M.met(tgt, counts and counts[item] or 0) then
      open[#open + 1] = item
    end
  end
  return open
end

-- True if every resource in the list has reached its quota (and list is non-empty).
function M.all_met(items, quotas, global_settings, counts)
  if not items or #items == 0 then return false end
  for _, item in ipairs(items) do
    local tgt = M.target(quotas, global_settings, item)
    if not M.met(tgt, counts and counts[item] or 0) then
      return false
    end
  end
  return true
end

return M
