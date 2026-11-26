---@diagnostic enable: undefined-field, missing-fields
-- PURE: Cultural Insights tourism (#51, design §6.3). A tourist is a real colonist who walks to a Passenger
-- Platform, boards a coach at home, alights at a *different* rail-linked colony with a Spa, visits for a while,
-- boards home and only then earns one Cultural Insight per rider. There is no item, no currency and no tech:
-- insights are a decaying per-colony stat that feeds two bonus-only desirability components.
--
-- Nothing here touches the Factorio API: the coach trip itself is model/transit.lua, the engine work is
-- scripts/tourism.lua and scripts/transit.lua. All the anti-exploit predicates live here so they can be
-- pinned offline (tests/tourism_test.lua) as well as in the headless spike (m2_tourism).
local resorts = require("scripts.model.resorts")

local M = {}

M.SPA_CAPACITY = 2            -- visitors per Spa
M.HOME_TOURIST_CAP = 2        -- concurrent tourists away from one home (beds held in colony.away)
M.MAX_SEND_PER_EVAL = 1       -- one new departure per home per evaluation
M.VISIT_TICKS = 6000          -- half a commuter shift: a visit is real time, not a teleport
M.STRANDED_TICKS = 7200       -- a visitor waiting this long for the train home walks instead
M.INSIGHT_HALF_LIFE = 12      -- evaluations before a Cultural Insight is worth half as much
-- There is deliberately no payout cooldown: every rider on a genuine visited return batch earns exactly
-- one insight. A rider cannot be farmed - the 6000-tick visit, HOME_TOURIST_CAP and one departure per
-- evaluation already bound the rate - and a per-batch throttle silently discarded legitimate riders.
M.W_TOURISM = 0.10            -- home bonus once at least one insight has landed; never a penalty
M.W_HOSPITALITY = 0.05        -- per current visitor at the host; never a penalty
M.TOURISM_CAP = 2.0           -- stat saturates at this for the desirability maths
M.HOSPITALITY_CAP = 2         -- at most two visitors count towards hospitality

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
M.clamp = clamp

-- A colony cannot visit itself: a one-town rail loop must never pay out.
function M.host_ok(home_id, host_id)
  return home_id ~= nil and host_id ~= nil and home_id ~= host_id
end

-- How many idle colonists set off this evaluation: no more than the hosts still want, less those already
-- waiting, and at most one new tourist per home per evaluation (same shape as commute.to_send, #50).
function M.departures(idle, want, waiting, cap)
  return math.max(0, math.min(idle or 0, (want or 0) - (waiting or 0), (cap or 0) - (waiting or 0)))
end

-- Free visitor places at a host after the visitors already there, the tourists riding to it, and the ones
-- waiting at their home platform for it are subtracted.
function M.host_capacity(spas, visiting, inbound, waiting)
  return math.max(0, M.SPA_CAPACITY * (spas or 0) - (visiting or 0) - (inbound or 0) - (waiting or 0))
end

-- Tourists away from a home: visiting at a host, riding either way, or waiting at a platform. The same
-- number is also carried by colony.away once the outbound group has actually boarded.
function M.away_count(visiting, riding, waiting)
  return (visiting or 0) + (riding or 0) + (waiting or 0)
end

-- A visit ends at nightfall or after VISIT_TICKS, whichever comes first.
function M.visit_over(now, ends, night)
  return night == true or now >= (ends or 0)
end

-- THE payout predicate. A group earns insights only when it is a return group that really visited a
-- different host and is alighting at its home. Outbound alights, diverted groups, self-hosts and groups
-- with no `visited` marker all fail here even if the caller is confused about which stop the train is at.
function M.earns_insight(group, here)
  if not group or group.kind ~= "tourist_return" or group.visited ~= true then return false end
  if group.host == nil or group.home == nil or group.host == group.home then return false end
  return here == group.home
end

-- The number of insights an alighted batch earns: one per rider, but only for a genuine visited return
-- group at its own home. Two batches arriving close together each pay their own riders in full - the
-- group is consumed by transit.alight, so neither can pay twice.
function M.credited(group, here)
  if not M.earns_insight(group, here) then return 0 end
  return resorts.insights(group.resort, group.n)
end

-- One evaluation of half-life decay: after INSIGHT_HALF_LIFE evaluations a stat is worth half as much.
function M.decay(recent, half_life)
  local hl = half_life or M.INSIGHT_HALF_LIFE
  if hl <= 0 then return recent or 0 end
  return (recent or 0) * 0.5 ^ (1 / hl)
end

-- Bonus-only: no insight and no visitors means 0, never a penalty. The home bonus saturates at one
-- insight's worth (a mature town does not stack insight forever; the stat itself still decays).
function M.tourism_bonus(recent, w, cap)
  return (w or M.W_TOURISM) * clamp(math.min(recent or 0, cap or M.TOURISM_CAP), 0, 1)
end

function M.hospitality_bonus(visitors, w, cap)
  return (w or M.W_HOSPITALITY) * clamp(visitors or 0, 0, cap or M.HOSPITALITY_CAP)
end

return M
