-- PURE: harvest quotas and yield targets (#84).
-- Determines whether a resource has reached its production cap.
local M = {}

M.DEFAULT_QUOTA = 20

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
  ["colony-basket"] = {category = "tool", default = 1},
  ["colony-axe"] = {category = "tool", default = 1},
  ["colony-pickaxe"] = {category = "tool", default = 1},
  ["colony-hoe"] = {category = "tool", default = 1},
  ["colony-rod"] = {category = "tool", default = 1},
  ["colony-bow"] = {category = "tool", default = 1},
  ["colony-arrow"] = {category = "tool", default = 20},
  ["colony-rifle"] = {category = "tool", default = 1},
}

-- Produced intermediates the player can cap from the Town Hall ledger. They are not harvested by a hut, so
-- they are not listed above; a default of 0 means unlimited (the furnace behaves exactly as before) and a
-- player-set cap is a *ceiling on collection*, not a target: once stock reaches it, haulers stop emptying
-- machine output, the machine's output fills, and it stalls until demand or the player raises the cap.
local quota_supply = {
  ["iron-plate"] = true, ["copper-plate"] = true, ["steel-plate"] = true,
  ["iron-gear-wheel"] = true, ["stone-brick"] = true, ["concrete"] = true,
  ["electronic-circuit"] = true, ["advanced-circuit"] = true, ["plastic-bar"] = true,
  ["solid-fuel"] = true,
}
for item in pairs(quota_supply) do
  M.RESOURCES[item] = {category = "supply", default = 0}
end

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

-- True if a resource is permitted to be collected as a low-priority overflow task when idle.
-- Defaults to true for all core resources unless explicitly set to false.
function M.overflow_allowed(overflow_table, item)
  if not overflow_table then return true end
  if overflow_table[item] ~= nil then
    return overflow_table[item] == true
  end
  return true
end

return M
