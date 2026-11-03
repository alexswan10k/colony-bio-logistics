-- PURE: passenger rail between colonies (#49, design §10.4).
-- A unit can never sit in a train (spike #2: `set_passenger` only takes characters), so a ride is bookkeeping: a
-- colonist waiting at a Passenger Platform boards a Passenger Coach by leaving its colony, rides as a count on
-- the coach, and steps off as a new colonist of the first other colony with free beds. Colonists are not
-- individuals with histories yet, so nothing is lost by this.
local M = {}

M.STOP_RADIUS = 10   -- tiles between a platform and the train stop it serves
M.SEATS = 20         -- riders per coach
M.WAIT_CAP = 20      -- colonists waiting at one platform
M.RETURN_AFTER = 4   -- stops a rider stays aboard before it will get off back home

-- How many colonists head for the platform this evaluation. `leaving` would otherwise walk off the map and
-- `homeless` have no bed; both only travel when another colony has room for them (`room`, free beds elsewhere
-- minus riders already waiting), and never more than the platform holds.
function M.departures(leaving, homeless, waiting, room)
  local want = (leaving or 0) + (homeless or 0)
  local space = math.min(M.WAIT_CAP - (waiting or 0), (room or 0) - (waiting or 0))
  return math.max(0, math.min(want, space))
end

-- Riders get off where they did not get on, or anywhere once they have ridden RETURN_AFTER stops (a loop line
-- with no room anywhere else brings them home rather than carrying them forever).
function M.alights_here(group, here)
  return group.from ~= here or (group.stops or 0) >= M.RETURN_AFTER
end

-- groups: array of {from = colony id, n = riders, stops = stops ridden}, oldest first. Returns how many get off
-- at colony `here` given `free` beds, and the groups left aboard (each with its stop counted).
function M.alight(groups, here, free)
  local out, left = 0, {}
  free = math.max(free or 0, 0)
  for _, g in ipairs(groups) do
    local n = g.n
    if M.alights_here(g, here) and free > 0 then
      local off = math.min(n, free)
      out, free, n = out + off, free - off, n - off
    end
    if n > 0 then left[#left + 1] = {from = g.from, n = n, stops = (g.stops or 0) + 1} end
  end
  return out, left
end

function M.riders(groups)
  local n = 0
  for _, g in ipairs(groups or {}) do n = n + g.n end
  return n
end

-- Seats left on a coach.
function M.seats(groups) return math.max(0, M.SEATS - M.riders(groups)) end

return M
