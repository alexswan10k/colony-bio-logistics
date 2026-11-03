-- PURE: civilians take shelter from enemies (#61, design §2.4 / §7). Colonists are on the player force, so biters
-- can and do kill them, and since #53 every death is permanent. An enemy damaging anything of the colony's raises
-- an alarm at that spot; colonists within RADIUS drop their work and run to a shelter (a house or the Town Hall)
-- at least SAFE tiles from the threat, where they cannot be hurt. The alarm stays up while enemy units are within
-- RADIUS of it (but at most HOLD_TICKS past the last hit, so a quiet nest nearby cannot pin the town indoors) and
-- clears CLEAR_TICKS after the last one is gone; a sheltered colonist goes back to work once no alarm covers the
-- place it fled from.
local M = {}

M.RADIUS = 40          -- tiles around an alarm that colonists flee from
M.SAFE = 24            -- a shelter at least this far from the threat is preferred
M.MERGE = 24           -- damage this close to an existing alarm refreshes it instead of raising another
M.CLEAR_TICKS = 600    -- quiet time before an alarm clears
M.CHECK_TICKS = 60     -- alarm upkeep period while any alarm is up
M.HOLD_TICKS = 3600    -- enemies merely nearby (biters idling by their nest) hold an alarm this long after the last hit

-- States a colonist is never pulled out of: it is already sheltering, or another system owns it (a driver waiting
-- in a Motor Pool, a passenger bound for or waiting at a platform).
M.EXEMPT = {to_shelter = true, sheltered = true, driving = true, to_platform = true, waiting_train = true}

local function d2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- Raise (or refresh) an alarm at `pos`. alarms = array of {pos, ends, hit, id} (`hit` = tick of the last damage). Returns the alarm and whether it is new.
function M.raise(alarms, pos, tick, next_id)
  for _, a in ipairs(alarms) do
    if d2(a.pos, pos) <= M.MERGE * M.MERGE then
      a.ends, a.hit = math.max(a.ends, tick + M.CLEAR_TICKS), tick
      return a, false
    end
  end
  local a = {pos = {x = pos.x, y = pos.y}, ends = tick + M.CLEAR_TICKS, hit = tick, id = next_id}
  alarms[#alarms + 1] = a
  return a, true
end

-- The alarm whose radius covers `pos`, or nil.
function M.covers(alarms, pos)
  for _, a in ipairs(alarms or {}) do
    if d2(a.pos, pos) <= M.RADIUS * M.RADIUS then return a end
  end
  return nil
end

-- Upkeep: `hostile[i]` says whether enemy units are still within RADIUS of alarms[i]. Returns the alarms that
-- remain (refreshed where enemies are still about) and how many cleared.
function M.upkeep(alarms, hostile, tick)
  local kept, cleared = {}, 0
  for i, a in ipairs(alarms) do
    if hostile[i] then a.ends = math.max(a.ends, math.min(tick + M.CLEAR_TICKS, (a.hit or tick) + M.HOLD_TICKS)) end
    if tick < a.ends then kept[#kept + 1] = a else cleared = cleared + 1 end
  end
  return kept, cleared
end

-- Index of the shelter to run to. shelters = array of {position}; `me` = the colonist, `threats` = alarm
-- positions. Prefer the nearest shelter that is at least SAFE from every threat; if none is, the one farthest
-- from the nearest threat. nil when there are no shelters.
function M.shelter(shelters, me, threats)
  local function threat_d2(p)
    local best
    for _, t in ipairs(threats) do
      local d = d2(p, t)
      if not best or d < best then best = d end
    end
    return best or math.huge
  end
  local safe_i, safe_d, far_i, far_d
  for i, s in ipairs(shelters) do
    local td = threat_d2(s.position)
    if td >= M.SAFE * M.SAFE then
      local d = d2(s.position, me)
      if not safe_d or d < safe_d then safe_i, safe_d = i, d end
    elseif not far_d or td > far_d then
      far_i, far_d = i, td
    end
  end
  return safe_i or far_i
end

return M
