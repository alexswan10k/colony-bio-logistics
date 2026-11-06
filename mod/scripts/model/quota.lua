---@diagnostic enable: undefined-field, missing-fields
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
  ["colony-steel-axe"] = {category = "tool", default = 1},
  ["colony-steel-pickaxe"] = {category = "tool", default = 1},
  ["colony-steel-hoe"] = {category = "tool", default = 1},
  ["colony-rod"] = {category = "tool", default = 1},
  ["colony-bow"] = {category = "tool", default = 1},
  ["colony-arrow"] = {category = "tool", default = 20},
  ["colony-rifle"] = {category = "tool", default = 1},
}

-- Produced intermediates the player can cap from the Town Hall ledger. They are not harvested by a hut, so
-- they are not listed above; the default is 20 (same sensible default as harvested quotas) so a furnace
-- town does not produce plates to infinity with no sink. The cap is a *ceiling on collection*, not a
-- target: once stock reaches base + downstream demand, haulers stop emptying machine output, the output
-- backs up, and the machine stalls until a sink pulls it. Downstream demand (an opted-in machine that
-- eats the item) is the obvious sink that exits the system and raises the ceiling; see supply_capped.
local quota_supply = {
  ["iron-plate"] = true, ["copper-plate"] = true, ["steel-plate"] = true,
  ["iron-gear-wheel"] = true, ["stone-brick"] = true, ["concrete"] = true,
  ["electronic-circuit"] = true, ["advanced-circuit"] = true, ["plastic-bar"] = true,
  ["solid-fuel"] = true,
}
for item in pairs(quota_supply) do
  M.RESOURCES[item] = {category = "supply", default = 20}
end

-- Target quota for item (0 or nil = unlimited).
---@param quotas ItemCount|nil
---@param global_settings table|nil
---@param item string
---@return integer
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
---@param target integer|nil
---@param current integer|nil
---@return boolean
function M.met(target, current)
  if not target or target <= 0 then return false end
  return (current or 0) >= target
end

-- Filter a list of resources (e.g. mine ores), removing any that reached their quota.
---@param items string[]|nil
---@param quotas ItemCount|nil
---@param global_settings table|nil
---@param counts ItemCount|nil
---@return string[]
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
---@param items string[]|nil
---@param quotas ItemCount|nil
---@param global_settings table|nil
---@param counts ItemCount|nil
---@return boolean
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
---@param overflow_table table|nil
---@param item string
---@return boolean
function M.overflow_allowed(overflow_table, item)
  if not overflow_table then return true end
  if overflow_table[item] ~= nil then
    return overflow_table[item] == true
  end
  return true
end

return M
