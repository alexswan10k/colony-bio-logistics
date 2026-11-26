---@diagnostic enable: undefined-field, missing-fields
-- PURE: EVA tile-repair tasks (#69, design §9.3). A space platform exposes its impact-damaged tiles as
-- `{position, damage}` records; an EVA crew member spends repair packs to heal them. The pure module picks
-- which tile to repair (most damaged first, deterministic ties) and converts a pack into repair points.
-- The adapter owns the live platform, units and inventories.
local eva = require("scripts.model.eva")
local construct = require("scripts.model.construct")

local M = {}

M.PACK = construct.REPAIR_PACK          -- vanilla repair pack, same item the builders use
M.PACK_POINTS = 100                     -- damage points one pack restores on a platform tile
M.WORK_TICKS = 300                      -- one work spell at the tile (5 s)
M.SCAN_EVERY = 600                      -- one dispatch pass per ten minutes, never per tick
M.MIN_DAMAGE = 0.01                     -- ignore rounding dust

---@param damaged table[]|nil {position={x,y}, damage=number}
---@param airlock table|nil
---@param packs integer|nil
---@return table|nil {position=, damage=, spend=}
function M.task(damaged, airlock, packs)
  if (packs or 0) <= 0 then return nil end
  local best
  for _, t in ipairs(damaged or {}) do
    local d = t.damage or 0
    if d >= M.MIN_DAMAGE and t.position and eva.in_radius(t.position, airlock) then
      local better = not best or d > best.damage
      if best and d == best.damage then
        better = t.position.x < best.position.x
          or (t.position.x == best.position.x and t.position.y < best.position.y)
      end
      if better then best = t end
    end
  end
  if not best then return nil end
  return {position = best.position, damage = best.damage,
    spend = math.min(M.PACK_POINTS, math.ceil(best.damage / M.PACK_POINTS))}
end

-- Repair points actually applied, clamped to what is left on the tile.
---@param damage number
---@param amount number
---@return number
function M.applied(damage, amount)
  return math.max(0, math.min(damage or 0, amount or 0))
end

return M
