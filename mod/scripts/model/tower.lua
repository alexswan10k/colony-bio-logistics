---@diagnostic enable: undefined-field, missing-fields
-- PURE: water tower rules (#96 second half). A water tower is a worker-free machine that turns piped fluid
-- water into colony-water in its output inventory. Houses drink from the tower instead of waiting for a
-- hauler, so a town with a pump, pipes and a tank never rations its taps.
local M = {}

M.RADIUS = 24              -- tiles from a water tower to a house it serves (like the Tavern)
M.OUTPUT_STACK = 50        -- colony-water the tower is allowed to hold (the machine's own output cap)
M.CONVERT_WATER = 100      -- fluid water per craft (the vanilla bottling recipe)
M.CONVERT_OUT = 10         -- colony-water per craft

local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- towers: array of {position=, water=, id=} (water = colony-water present). Returns the indexes of the towers
-- in fair "fill order": nearest to `house_pos` first, then by unit number so the pick is deterministic.
function M.best_tower(towers, house_pos)
  local r2 = M.RADIUS * M.RADIUS
  local best, best_d, best_id
  for i, t in ipairs(towers) do
    if (t.water or 0) > 0 then
      local d = dist2(t.position, house_pos)
      if d <= r2 and (not best_d or d < best_d or (d == best_d and (t.id or 0) < (best_id or 0))) then
        best, best_d, best_id = i, d, t.id
      end
    end
  end
  return best
end

-- Take up to `want` water from the towers available to a house, in fill order (nearest first). Mutates
-- `taken_from` so a tower never gives more than it holds across several calls in one evaluation.
--   towers: array of {position=, water=, id=}
--   house_pos: {x, y}
--   want: integer
--   taken_from: {[tower_index] = amount} (optional, accumulated here)
-- Returns the number taken (0..want).
function M.take(towers, house_pos, want, taken_from)
  taken_from = taken_from or {}
  local left, got = want, 0
  -- Fill in waves of "nearest first": after a tower is drained, the next fill still looks for the nearest
  -- with stock left, which matches how the town would actually ration its towers.
  while left > 0 do
    local best = M.best_tower(towers, house_pos)
    if not best then break end
    local t = towers[best]
    local left_here = t.water or 0
    if left_here <= 0 then break end   -- stale: nothing more to take from anyone
    local give = math.min(left, left_here)
    t.water = left_here - give
    taken_from[best] = (taken_from[best] or 0) + give
    -- mark exhausted by zeroing in place so the next scan moves to the next tower
    if t.water <= 0 then t.water = 0 end
    left, got = left - give, got + give
    if give <= 0 then break end
  end
  return got
end

return M
