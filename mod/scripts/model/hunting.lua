-- PURE: hunting rules (#79, design §3.1). A hunter is paid per kill, not per trip: the animal supplies the
-- meat, the rifle supplies the reach. Everything here is a plain decision the adapter can apply.
local M = {}

M.MEAT_PER_KILL = 6       -- raw meat from one animal
M.RANGE = 30              -- tiles from the lodge a hunter looks for game (the standard hut radius)
M.MAX_ATTEMPTS = 3        -- attack commands per trip before the hunter gives up and walks home

-- Nearest animal to `pos` within `range`, ties by unit_number so the pick is stable.
-- `animals` is an array of {unit_number=, position=}; returns nil when there is nothing in reach.
function M.nearest(animals, pos, range)
  local best, best_d, r2 = nil, nil, (range or M.RANGE) ^ 2
  for _, a in ipairs(animals) do
    local dx, dy = a.position.x - pos.x, a.position.y - pos.y
    local d = dx * dx + dy * dy
    if d <= r2 and (not best_d or d < best_d or (d == best_d and a.unit_number < best.unit_number)) then
      best, best_d = a, d
    end
  end
  return best
end

return M
