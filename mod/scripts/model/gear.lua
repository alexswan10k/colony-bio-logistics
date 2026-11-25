---@diagnostic enable: undefined-field, missing-fields
-- PURE: cross-planetary endgame gear (#69, design §9.4). Every planet hands the colony one tool or structure
-- that changes a number the rest of the game already reads; the numbers and the decisions live here so they
-- can be tested without Factorio. The adapter (scripts/work.lua, scripts/cold.lua, scripts/illness.lua,
-- scripts/colony.lua) only asks these questions and applies the answer.
--
--   Vulcanus  tungsten tools  - a third tier above iron and steel: more trips, faster work.
--   Fulgora   exoskeleton     - hauling at car speed (movement multiplier while on a delivery trip).
--   Gleba     panacea serum   - immunity to every illness and a +50% work-speed buff.
--   Aquilo    cryo warehouse  - a 0% spoilage store (like the Cold Chain, but always cold).
--   Aquilo    fusion arcology - the Tier-6 housing rung above the Habitat Dome.
--
-- Issued gear is a colony-wide passive while at least one copy is in the colony stock (hall + warehouses +
-- hut chests + carried goods). It is deliberately NOT consumed per colonist: a serum or harness is equipment
-- the town keeps, so there is no per-unit gear state to migrate and no new schema. This keeps existing towns
-- bit-identical - none of them hold endgame gear - so the determinism checksum only moves on the prototype
-- hash, exactly like every other prototype-only addition in this repo.
local M = {}

M.ITEM = {
  tungsten_pickaxe = "colony-tungsten-pickaxe",
  exoskeleton = "colony-exoskeleton-harness",
  panacea = "colony-panacea-serum",
  cryo_warehouse = "colony-cryo-warehouse",
  arcology = "colony-fusion-arcology",
}

-- Tungsten tools (Vulcanus): tier 3. Steel is 45 trips at 0.8x work ticks; tungsten is 60 at 0.65x.
M.TUNGSTEN_TOOL_USES = 60
M.TUNGSTEN_WORK_MULT = 0.65
-- Exoskeleton harness (Fulgora): doubles the movement speed of a colonist on a haul trip. It never stacks
-- with the wooden trailer (a trailer is the slow, cheap tier), so the adapter takes the single best multiplier.
M.EXO_HAUL_MULT = 2.0
-- Panacea serum (Gleba): a +50% work-speed buff and immunity to all three diseases. Sick colonists still
-- work at half speed; panacea removes the sickness before that multiplier would apply.
M.PANACEA_WORK_MULT = 0.5
M.PANACEA_IMMUNE = {lung = true, poison = true, swamp_fever = true}
-- Cryo-preservation warehouse (Aquilo): contents never spoil while inside. The adapter restamps
-- `spoil_percent` to 0 on a short timer, as the Cold Chain already does for refrigerated storage; a 0%
-- rate means the countdown is stopped rather than reversed past the engine's floor.
M.CRYO_SPOIL_RATE = 0
-- Fusion arcology (Aquilo): the late housing rung. 48 beds, mandatory power, water and comfort, like the
-- dome above it but denser; its own spirit is "a city under one roof", so it also keeps a bigger pantry.
M.ARCOLOGY_CAPACITY = 48
M.ARCOLOGY_BUFFER_INTERVALS = 8

---@param stock ItemCount|nil
---@param item string
---@return boolean
function M.present(stock, item)
  return stock ~= nil and (stock[item] or 0) > 0
end

-- The colony-wide buffs currently active. `stock` is colony.stock_table(colony) (a {item -> count} map).
---@param stock ItemCount|nil
---@return table {exo = boolean, panacea = boolean}
function M.effects(stock)
  return {
    exo = M.present(stock, M.ITEM.exoskeleton),
    panacea = M.present(stock, M.ITEM.panacea),
  }
end

-- Movement multiplier for a hauler. `base` is the speed multiplier before gear (1 normally, 0.6 with a
-- trailer); the exoskeleton is a separate issued item, so a trailer trip keeps its penalty and gains the
-- harness bonus on top rather than being replaced by it.
---@param base number
---@param exo boolean|nil
---@return number
function M.haul_speed(base, exo)
  return exo and (base or 1) * M.EXO_HAUL_MULT or (base or 1)
end

-- Work ticks after the panacea buff. Rounded up so a buff never shortens a trip below a whole tick.
---@param base number
---@param panacea boolean|nil
---@return number
function M.work_ticks(base, panacea)
  return panacea and math.ceil(base * M.PANACEA_WORK_MULT) or base
end

-- A colonist with panacea cannot catch `kind`, and an existing illness is cured at the next evaluation.
---@param kind string
---@param panacea boolean|nil
---@return boolean
function M.immune(kind, panacea)
  return panacea == true and M.PANACEA_IMMUNE[kind] == true
end

-- Effective spoilage rate. 0 means the item does not spoil at all; nil `in_cryo` is the normal world.
---@param in_cryo boolean|nil
---@return number
function M.spoil_rate(in_cryo)
  return in_cryo and M.CRYO_SPOIL_RATE or 1
end

-- Ticks until a stack of `base_ticks` spoils; nil means "never while it stays inside".
---@param base_ticks number
---@param in_cryo boolean|nil
---@return number|nil
function M.spoils_after(base_ticks, in_cryo)
  local rate = M.spoil_rate(in_cryo)
  if rate <= 0 then return nil end
  return base_ticks / rate
end

return M
