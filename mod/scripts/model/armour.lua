---@diagnostic enable: undefined-field, missing-fields
-- PURE model: militia armour and item quality (M3 defence stack, #55).
--
-- Stage 0 (s19_defence) proved a `small-biter`-derived `unit` has NO character_armor inventory, NO equipment
-- grid and no per-unit resistances. Native armour is therefore IMPOSSIBLE on a colonist/militia unit.
-- Armour is pure data: gear recorded on the unit's state, with a scripted *heal-back* on on_entity_damaged
-- (scripts/militia.lua) applying the mitigation fraction computed here. Quality arrives from the adapter as a
-- plain string ("normal", "uncommon", ...), so this model stays engine-free.
--
-- These are vanilla armour item names; no new prototype is needed. A militia "wears" one by holding a count
-- in its gear data, and the item itself is consumed from colony stock when issued.
local M = {}

-- Base mitigation fraction per armour kind. The value is the share of *applied* damage healed back.
M.ARMOUR = {
  ["light-armor"] = 0.15,
  ["heavy-armor"] = 0.28,
  ["modular-armor"] = 0.38,
  ["power-armor"] = 0.48,
  ["power-armor-mk2"] = 0.58,
}

-- Quality multiplier on mitigation (a string key, exactly what ItemWithQualityCount.quality returns in 2.1).
M.QUALITY = {
  normal = 1.0,
  uncommon = 1.15,
  rare = 1.3,
  epic = 1.5,
  legendary = 1.75,
}
M.MAX_MITIGATION = 0.80   -- clamped: armour is a backstop, not invulnerability

-- Deterministic order for "best armour" ties: highest base mitigation, then name.
M.PREFERENCE = {"power-armor-mk2", "power-armor", "modular-armor", "heavy-armor", "light-armor"}

local function q(name) return M.QUALITY[name] or M.QUALITY.normal end

--- Mitigation fraction for an armour kind + quality name, clamped to [0, MAX_MITIGATION].
---@param kind string|nil armour item name, or nil (unarmoured)
---@param quality_name string|nil
---@return number
function M.mitigation(kind, quality_name)
  local base = kind and M.ARMOUR[kind] or 0
  if base <= 0 then return 0 end
  local v = base * q(quality_name)
  if v < 0 then return 0 end
  if v > M.MAX_MITIGATION then return M.MAX_MITIGATION end
  return v
end

-- Tiers in ascending order, used for "best in stock" ranking (deterministic; never pairs() over a map).
---@param kind string|nil
---@return integer
function M.tier(kind)
  for i, name in ipairs(M.PREFERENCE) do if name == kind then return i end end
  return 0
end

--- Best (highest-tier) armour present in `counts`, with its quality. Ties broken by PREFERENCE order.
---@param counts table<string, integer>|nil
---@param quality_by_item table<string, string>|nil optional quality string per item
---@return string|nil, string|nil
function M.best(counts, quality_by_item)
  local best, best_q
  for _, name in ipairs(M.PREFERENCE) do
    if (counts and counts[name] or 0) > 0 then
      best = name
      best_q = quality_by_item and quality_by_item[name] or "normal"
      break
    end
  end
  return best, best_q
end

return M
