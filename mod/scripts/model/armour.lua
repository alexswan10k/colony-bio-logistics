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
  -- #69 cross-planet endgame: Vulcanus siege plating heals back 55% of applied damage (quality scales it,
  -- clamped at 80%). The Fulgora shield is NOT a percentage - it has its own finite, recharging pool below.
  ["colony-heavy-siege-armor"] = 0.55,
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
M.PREFERENCE = {"colony-heavy-siege-armor", "power-armor-mk2", "power-armor", "modular-armor",
  "colony-personal-shield-pack", "heavy-armor", "light-armor"}

-- #69: two colony-made armours, unlocked by Bio-Ecological Data. Both are drawn by the same hall/Armory
-- gear path as vanilla armour; never added to GEAR_PER_MILITIA unconditionally, or an untouched town's
-- Armory would start requesting gear the player has not researched.
M.SIEGE = "colony-heavy-siege-armor"
M.SHIELD = "colony-personal-shield-pack"
M.ENDGAME = {M.SIEGE, M.SHIELD}

-- The Personal Shield Pack absorbs a flat amount from a finite pool instead of a percentage. Recharge is
-- slow and deterministic; a depleted shield is still an armour (it can recharge on the next scan).
M.SHIELD_CAPACITY = 60
M.SHIELD_RECHARGE_PER_TICK = 0.1

---@param kind string|nil
---@return boolean
function M.is_shield(kind) return kind == M.SHIELD end

-- Absorb as much of `damage` as the remaining charge allows. No input mutation.
---@param charge number|nil
---@param damage number
---@return number, number absorbed, charge_left
function M.shield_drain(charge, damage)
  local have = math.max(0, math.min(charge or M.SHIELD_CAPACITY, M.SHIELD_CAPACITY))
  local absorbed = math.max(0, math.min(have, damage or 0))
  return absorbed, have - absorbed
end

-- Recharge by `ticks` at the fixed rate, capped at capacity.
---@param charge number|nil
---@param ticks number
---@return number
function M.shield_recharge(charge, ticks)
  local have = math.max(0, math.min(charge or 0, M.SHIELD_CAPACITY))
  return math.min(M.SHIELD_CAPACITY, have + M.SHIELD_RECHARGE_PER_TICK * math.max(0, ticks or 0))
end

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

-- Armory depot rules (M3 Stage 2, #56 remainder). The Armory is a worker-free chest: haulers fill it to these
-- targets and a militia draws its weapon/armour out of it. All three routines are pure - the adapter owns the
-- live inventory and performs the actual insert/remove. Inputs are never mutated.

-- Gear an equipped militia needs, in a fixed order (deterministic haul rows and gear draws).
---@type table[] {item=, count=} per militia post
M.GEAR_PER_MILITIA = {
  {item = "colony-rifle", count = 1},
  {item = "heavy-armor", count = 1},
  {item = "firearm-magazine", count = 10},
  {item = "colony-arrow", count = 20},
}

--- Restock targets for `manning` equipped militia. A limit of 0 wants nothing (an unmanned Armory never nags).
--- `unlocked` is an optional set of endgame armour item names; only those the force has researched are asked
--- for, so an untouched town's Armory is byte-identical (#69).
---@param manning integer|nil
---@param unlocked table<string, boolean>|nil
---@return table[] {item=, count=}
function M.armory_targets(manning, unlocked)
  local n = math.max(0, math.floor(tonumber(manning) or 0))
  local out = {}
  if n == 0 then return out end
  for _, row in ipairs(M.GEAR_PER_MILITIA) do
    out[#out + 1] = {item = row.item, count = row.count * n}
  end
  if unlocked then
    for _, item in ipairs(M.ENDGAME) do
      if unlocked[item] then out[#out + 1] = {item = item, count = n} end
    end
  end
  return out
end

--- What can actually be handed out from `counts` for the ordered `wants`, without taking more than exists.
--- No input mutation: a private copy of `counts` is decremented as grants are decided.
---@param counts table<string, integer>|nil
---@param wants table[]|nil ordered {item=, count=}
---@return table[] grants ordered {item=, count=}
function M.draw_gear(counts, wants)
  local left = {}
  for item, n in pairs(counts or {}) do left[item] = n end
  local grants = {}
  for _, w in ipairs(wants or {}) do
    local have = left[w.item] or 0
    local n = math.min(math.floor(tonumber(w.count) or 0), have)
    if n > 0 then
      grants[#grants + 1] = {item = w.item, count = n}
      left[w.item] = have - n
    end
  end
  return grants
end

--- Haul requests that bring an Armory up to `targets`, counting stock already there and already in flight.
--- No input mutation; targets are consumed in order so two identical calls return identical rows.
---@param counts table<string, integer>|nil
---@param targets table[]|nil ordered {item=, count=}
---@param inflight table<string, integer>|nil
---@return table[] demands ordered {item=, count=}
function M.restock_deficit(counts, targets, inflight)
  local out = {}
  for _, t in ipairs(targets or {}) do
    local have = (counts and counts[t.item] or 0) + (inflight and inflight[t.item] or 0)
    local deficit = (t.count or 0) - have
    if deficit > 0 then out[#out + 1] = {item = t.item, count = deficit} end
  end
  return out
end

return M
