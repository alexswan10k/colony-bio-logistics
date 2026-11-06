---@diagnostic enable: undefined-field, missing-fields
-- PURE: construction & repair rules (#37). Colonists build entity-ghosts inside colony territory and
-- repair damaged colony buildings. A ghost's price comes from its `ghost_prototype.items_to_place_this`,
-- so a ghost of any entity costs exactly what placing that entity costs (mods included).
local M = {}

M.WORK_TICKS = 30         -- build/repair time once the colonist is on site (fast/snappy placement)
M.REPAIR_PACK = "repair-pack"
M.REPAIR_PER_PACK = 200   -- health restored by one repair pack
M.SHARE = 0.25            -- at most this share of the colony builds, so the town keeps eating
M.SCAN_TICKS = 300        -- how often a colony looks for new ghosts and new damage
M.RETRY_TICKS = 3600      -- back off this long after a ghost refuses to revive (blocked site)

local function by_item(a, b) return a.item < b.item end

-- Build cost of a ghost: its items_to_place_this, normalised and sorted so trips are deterministic.
function M.cost(items)
  local out = {}
  for _, it in ipairs(items or {}) do
    local n = it.count or it.amount or 0
    if it.name and n > 0 then out[#out + 1] = {item = it.name, count = n} end
  end
  table.sort(out, by_item)
  return out
end

-- Can colony stock pay for this ghost? stock is a plain {item -> count} map.
function M.affordable(cost, stock)
  for _, s in ipairs(cost) do
    if (stock[s.item] or 0) < s.count then return false end
  end
  return true
end

function M.needs_repair(health, max)
  return max and max > 0 and health and health < max
end

-- One pack's worth of repair. Returns the new health and whether a pack was actually used.
function M.repaired(health, max)
  if not M.needs_repair(health, max) then return health, false end
  return math.min(max, health + M.REPAIR_PER_PACK), true
end

-- How many colonists may build at this population: at least one, or nothing gets built.
function M.builders(pop)
  if pop <= 0 then return 0 end
  return math.max(1, math.floor(M.SHARE * pop + 0.5))
end

return M
