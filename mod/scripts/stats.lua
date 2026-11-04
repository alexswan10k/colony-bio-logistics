-- Colony item production for the vanilla statistics GUI (#89).
-- The engine only counts item transfers it drives itself (machine input/output, recipes). The colony moves every
-- item with Lua `insert`/`remove`, so without this the whole colony economy was invisible to the production
-- statistics. `LuaFlowStatistics::on_flow` is the sanctioned hook: positive count adds to the input (production)
-- counter, negative to the output (consumption) counter; mod items and vanilla items both work, plain prototype
-- name as id. Statistics are per (force, surface). Everything here is wrapped in pcall: a statistics hiccup must
-- never break the colony loop.
local M = {}

local cache = {}   -- [force.index .. ":" .. surface.index] = LuaFlowStatistics

local function stats(force, surface)
  if not force then return nil end
  local key = tostring(force.index or force.name or "?") .. ":" .. tostring((surface and surface.index) or 0)
  local s = cache[key]
  if not (s and s.valid) then
    local ok, res = pcall(function() return force.get_item_production_statistics(surface) end)
    s = ok and res or nil
    cache[key] = s
  end
  return s
end
M.stats = stats

-- Raw signed flow. Prefer produced()/consumed().
function M.flow(colony, item, count, surface)
  if not (colony and item and count and count ~= 0) then return end
  local hall = colony.hall
  local force = hall and hall.valid and hall.force
  if not force then return end
  local s = stats(force, surface or (hall and hall.surface))
  if not (s and s.valid) then return end
  pcall(function() s.on_flow(s, item, count) end)
end

-- Items that came into existence in the colony (harvest, curing, baking, composting, wells and pans...).
function M.produced(colony, item, count)
  M.flow(colony, item, math.abs(count or 0))
end

-- Items that left existence in the colony (eaten, burned as ghost materials, tools wearing out...).
function M.consumed(colony, item, count)
  M.flow(colony, item, -math.abs(count or 0))
end

return M
