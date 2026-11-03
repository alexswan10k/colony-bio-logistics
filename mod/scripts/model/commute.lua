-- PURE: commuter outposts (#50, design §6.1). A colony with a stocked Canteen is an outpost: it asks for commuters
-- to fill its open job slots instead of housing workers. Idle colonists of other rail-linked towns ride in by
-- Passenger Coach (the ride itself is model/transit.lua), work a shift as the outpost's colonists, eat at the
-- Canteen, and ride home when the shift ends. Their beds at home are held while they are away.
local M = {}

M.SHIFT_TICKS = 12000      -- longest shift; nightfall or an empty Canteen ends it sooner
M.STRANDED_TICKS = 7200    -- a commuter waiting this long for a train home gives up and walks
M.HAUL_SHARE = 0.35        -- outposts need haulers too: slots are scaled up by work_plan's haul share
M.MEALS = 30               -- a Canteen keeps this much food on hand

-- Commuters an outpost still wants: its job slots (plus the haulers to serve them) less the colonists already
-- there and those already on their way.
function M.deficit(slots, here, inbound)
  local want = math.ceil((slots or 0) / (1 - M.HAUL_SHARE))
  return math.max(0, want - (here or 0) - (inbound or 0))
end

-- How many idle colonists of a town set off to commute this evaluation: no more than the outposts still want,
-- less those already waiting, and never more than fit on the platform.
function M.to_send(idle, wanted, waiting, cap)
  return math.max(0, math.min(idle or 0, (wanted or 0) - (waiting or 0), (cap or 0) - (waiting or 0)))
end

-- Is this shift over? At nightfall, at the shift's end, or when the Canteen could not feed everyone.
function M.shift_over(now, ends, night, fed)
  return night or now >= ends or not fed
end

-- Canteen meals for one evaluation: `commuters` eat `per` each (fractions carried in `owed`, as the Tavern's ale).
-- Returns the whole meals to take now, the new `owed`, and whether everyone was fed from `meals` on hand.
function M.eat(meals, commuters, per, owed)
  local need = (commuters or 0) * (per or 0) + (owed or 0)
  local take = math.floor(need)
  local fed = (meals or 0) >= take
  take = math.min(take, meals or 0)
  return take, fed and (need - math.floor(need)) or 0, fed
end

-- Food a Canteen asks haulers for, as a housing-style demand (any food item fills it).
function M.wants(food_items, have, inflight)
  local want = M.MEALS - (have or 0) - (inflight or 0)
  if want >= 1 then return {{need = "food", count = want, items = food_items}} end
  return {}
end

return M
