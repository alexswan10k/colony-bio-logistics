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

-- groups: array of {from = colony id, n = riders, stops = stops ridden, kind = nil|"commute"|"return", home},
-- oldest first. Three kinds of rider (#49, #50):
--   * migrants (kind nil) get off away from `from` into `free` beds;
--   * commuters on their way to work ("commute", from = home) get off away from home into `jobs` (the outpost's
--     open job slots), or back at home after RETURN_AFTER stops: their beds there were held for them;
--   * commuters on their way home ("return") get off only at `home`, beds or not.
-- Returns how many get off at colony `here`, the groups left aboard (each with its stop counted), and the
-- batches that got off: array of {kind, from, home, n}.
function M.alight(groups, here, free, jobs)
  local out, left, offs = 0, {}, {}
  free, jobs = math.max(free or 0, 0), math.max(jobs or 0, 0)
  for _, g in ipairs(groups) do
    local n, off = g.n, 0
    if g.kind == "return" then
      if g.home == here then off = n end
    elseif g.kind == "commute" then
      if g.from == here then
        if (g.stops or 0) >= M.RETURN_AFTER then off = n end
      else
        off = math.min(n, jobs)
        jobs = jobs - off
      end
    elseif M.alights_here(g, here) then
      off = math.min(n, free)
      free = free - off
    end
    if off > 0 then
      out, n = out + off, n - off
      offs[#offs + 1] = {kind = g.kind, from = g.from, home = g.home, n = off}
    end
    if n > 0 then left[#left + 1] = {from = g.from, n = n, stops = (g.stops or 0) + 1, kind = g.kind, home = g.home} end
  end
  return out, left, offs
end

function M.riders(groups)
  local n = 0
  for _, g in ipairs(groups or {}) do n = n + g.n end
  return n
end

-- Seats left on a coach.
function M.seats(groups) return math.max(0, M.SEATS - M.riders(groups)) end

return M
