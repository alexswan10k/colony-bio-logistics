-- PURE: guard duty at a garrisoned Watchtower (#56 first slice, design §7.2).
-- A Watchtower registered as a hut job "guard" holds rifles (the stock room IS the tower); each rifle
-- in it opens one post, exactly like a tooled hut slot (model/labour.lua). Staffed guards stand their
-- post at the tower and engage enemy units inside RANGE, at the cost of the rifles wearing out one step
-- per completed engagement (model/labour.wear - a hunter's trip pays for a kill exactly the same way).
-- Rifles are the price of the garrison: a tower with no rifles posts nobody, and a guard whose rifle
-- breaks keeps fighting empty-handed until reassigned, at which point it cannot be posted again.
local M = {}
M.RANGE = 16          -- tiles; a guard stands at the tower, the colonist's attack (14) reaches its edge
M.CHECK_TICKS = 45    -- idle rescan period while a guard is posted and sees no enemy
M.MAX_ATTEMPTS = 3    -- attack commands re-issued per target before the guard lets it go (same rule as hunts)
M.STRIKE_CLAIM = 3600 -- after this many failures, lose that target for a while (a turret-pinned biter)

-- Nearest hostile to the tower's post `pos`; ties by unit_number. `enemies` = array of {unit_number=, position=}.
-- Deterministic: the same world state always picks the same target, so a desync or a test does not re-fight.
function M.nearest(enemies, pos, range)
  local best, best_d, r2 = nil, nil, (range or M.RANGE) ^ 2
  for _, a in ipairs(enemies) do
    local dx, dy = a.position.x - pos.x, a.position.y - pos.y
    local d = dx * dx + dy * dy
    if d <= r2 and (not best_d or d < best_d or (d == best_d and a.unit_number < best.unit_number)) then
      best, best_d = a, d
    end
  end
  return best
end

return M
