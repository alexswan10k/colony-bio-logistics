---@diagnostic enable: undefined-field, missing-fields
-- PURE model: militia combat damage, gear choice and gear demand (M3 defence stack, #55).
--
-- Stage 0 (s19_defence) facts this model is built around:
--   * LuaEntity:damage() applies prototype resistances INSIDE the engine and returns the damage actually
--     applied. This model returns the raw *scripted* damage to hand to damage(); it never subtracts engine
--     resistances a second time.
--   * A unit has no armour inventory/grid/resistances. Defender armour is pure data, applied ONCE by the
--     adapter's heal-back on on_entity_damaged using model/armour.mitigation. engage() returns only the raw
--     outgoing script damage; it never subtracts or adds a defender-side term (a speculative "armour piercing"
--     bonus was removed in the review pass: no Stage 1 target has armour gear, so it was unreachable code).
--   * The colonist hitscan is reduced to a 1-damage baseline on the militia prototype, so engine + script
--     damage do not double-count; the script path below is the real damage.
--
-- No Factorio globals (game/storage/script/defines/surface), no input mutation, plain tables only.
local labour = require("scripts.model.labour")
local garrison = require("scripts.model.garrison")

local M = {}

-- Weapon preference, single-sourced from the garrison so militia and posted guards cannot drift apart.
-- Rifle > submachine gun > pistol > bow, exactly as a tower post arms itself (#56).
M.PREFERENCE = garrison.PREFERENCE

---@class WeaponDef
---@field damage number base scripted damage per strike
---@field type string DamageTypeID string passed to LuaEntity.damage
---@field ammo string|nil item spent per strike (nil = self-contained, e.g. a rifle)
---@field wear boolean|nil true when the weapon wears like a tool per completed engagement
---@field uses integer|nil wear threshold (rifle/bow); nil when ammo-based
---@field magazine_every integer|nil spend one magazine every N engagements (guns)
---@type table<string, WeaponDef>
M.WEAPONS = {
  ["colony-rifle"] = {damage = 40, type = "physical", ammo = nil, wear = true, uses = labour.TOOL_USES},
  ["submachine-gun"] = {damage = 14, type = "physical", ammo = "firearm-magazine", magazine_every = 10},
  ["pistol"] = {damage = 18, type = "physical", ammo = "firearm-magazine", magazine_every = 10},
  ["colony-bow"] = {damage = 14, type = "physical", ammo = "colony-arrow", wear = true, uses = labour.TOOL_USES},
}

-- Quality scales the raw damage. Mirrors model/armour's string-keyed quality input.
M.QUALITY_DAMAGE = {normal = 1.0, uncommon = 1.10, rare = 1.25, epic = 1.45, legendary = 1.70}

local function qd(name) return M.QUALITY_DAMAGE[name] or M.QUALITY_DAMAGE.normal end

--- Base scripted damage, damage type and ammo item for a weapon + quality. No input mutation.
---@param weapon string|nil
---@param quality_name string|nil
---@return number, string, string|nil
function M.outgoing(weapon, quality_name)
  local def = weapon and M.WEAPONS[weapon]
  if not def then return 0, "physical", nil end
  return def.damage * qd(quality_name), def.type, def.ammo
end

--- Damage for one strike of `attacker`, and its damage type. `attacker = {weapon=, quality=}`.
--- The defender's armour mitigation is NOT applied here - it happens once, in the adapter's heal-back on
--- on_entity_damaged. A second arg is accepted for source compatibility with the plan's `engage(gear, target)`
--- signature but is deliberately ignored: no Stage 1 target carries armour gear, so any defender-side term
--- would be unreachable in-game (review finding 4).
---@param attacker table|nil
---@param target table|nil unused; accepted for signature compatibility
---@return number, string
function M.engage(attacker, target)
  return M.outgoing(attacker and attacker.weapon, attacker and attacker.quality)
end

--- Best weapon present in `counts`, with its quality. PREFERENCE order, never pairs() over the map.
---@param counts table<string, integer>|nil
---@param quality_by_item table<string, string>|nil
---@return string|nil, string|nil
function M.best_gear(counts, quality_by_item)
  for _, item in ipairs(M.PREFERENCE) do
    if (counts and counts[item] or 0) > 0 then
      return item, quality_by_item and quality_by_item[item] or "normal"
    end
  end
  return nil, nil
end

-- Default spares the town keeps on hand for its militia, so a broken weapon or a spent magazine can be
-- replaced. The adapter turns these into ordinary haul requests (at `tools` priority), fed from colony stock
-- and NEVER from the requesting militia's own gear (which is pure data, not an entity inventory).
M.STOCK_TARGET = {
  ["colony-rifle"] = 2,
  ["submachine-gun"] = 1,
  ["pistol"] = 1,
  ["colony-bow"] = 2,
  ["firearm-magazine"] = 10,
  ["colony-arrow"] = 20,
  ["heavy-armor"] = 1,
  ["modular-armor"] = 1,
}

--- The most-needed gear item to keep in stock. `inflight` counts items already on a hauler, `stock` the
--- colony totals, `wants` an optional ordered {item=, count=} list (defaults to STOCK_TARGET, name-sorted).
--- Returns item, deficit, have, target (all nil when nothing is wanted). Deterministic; no input mutation.
---@param inflight table<string, integer>|nil
---@param stock table<string, integer>|nil
---@param wants table[]|nil
---@return string|nil, integer|nil, integer|nil, integer|nil
function M.gear_wanted(inflight, stock, wants)
  if not wants then
    local names = {}
    for name in pairs(M.STOCK_TARGET) do names[#names + 1] = name end
    table.sort(names)
    wants = {}
    for _, name in ipairs(names) do wants[#wants + 1] = {item = name, count = M.STOCK_TARGET[name]} end
  end
  local best_item, best_deficit, best_have, best_target
  for _, w in ipairs(wants) do
    local have = (stock and stock[w.item] or 0) + (inflight and inflight[w.item] or 0)
    local deficit = w.count - have
    if deficit > 0 and (not best_deficit or deficit > best_deficit) then
      best_item, best_deficit, best_have, best_target = w.item, deficit, have, w.count
    end
  end
  return best_item, best_deficit, best_have, best_target
end

--- One completed engagement's wear/ammo decision, pure. `st` is a gear table {weapon=, ammo_count=}.
--- Returns weapon (possibly nil when it broke), the item spent (ammo or a broken weapon), and the new
--- ammo_count. No input mutation: the caller applies the returned values to its own state.
---@param gear table {weapon=string|nil, ammo_count=integer|nil}
---@return string|nil, string|nil, integer
function M.spend(gear)
  gear = gear or {}
  local weapon = gear.weapon
  local def = weapon and M.WEAPONS[weapon]
  if not def then return weapon, nil, gear.ammo_count or 0 end
  if def.ammo then
    local n = (gear.ammo_count or 0) + 1
    if def.magazine_every then
      if n >= def.magazine_every then return weapon, def.ammo, 0 end
      return weapon, nil, n
    end
    return weapon, def.ammo, n   -- a bow spends one arrow per engagement
  end
  if def.wear then
    return weapon, weapon, gear.ammo_count or 0   -- a worn-out tool is consumed (adapter checks uses)
  end
  return weapon, nil, gear.ammo_count or 0
end

return M
