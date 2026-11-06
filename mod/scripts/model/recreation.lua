---@diagnostic enable: undefined-field, missing-fields
-- PURE: Taverns and the Inspired buff (#48, design §6.3).
-- A Tavern pours ale for the houses around it. Each colony evaluation every occupied house within RADIUS of a
-- stocked Tavern is served (nearest Tavern first), which costs ale per resident. Served residents are Inspired
-- (they work INSPIRED_SPEED times as fast) and the share of the town that was served is the colony's
-- `recreation` input to desirability: a bonus for having it, never a penalty for not having it yet.
local M = {}

M.ITEM = "colony-ale"
M.RADIUS = 24              -- tiles from a Tavern to a house it serves
M.ALE_PER_COLONIST = 0.25  -- ale per served resident per colony evaluation
M.STOCK = 20               -- ale a Tavern asks haulers to keep on tap
M.INSPIRED_SPEED = 1.25    -- +25% work speed (design §6.3)

local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- taverns: array of {position=, ale=, owed= (fractional ale carried over)}; houses: array of {position=,
-- occupants=}. Both in a stable order. Returns:
--   served {house index -> tavern index}, used {tavern index -> whole ale to remove}, owed {tavern index -> new
--   fractional debt}, coverage (served residents / all residents, 0..1).
-- A house is only served by a Tavern with ale left after the houses before it (in list order), so a dry Tavern
-- serves nobody. Fractions of an ale carry over in `owed`, so small houses are not served for free forever.
function M.serve(taverns, houses)
  local served, used, owed = {}, {}, {}
  local left, debt = {}, {}
  for i, t in ipairs(taverns) do left[i], debt[i], used[i] = t.ale or 0, t.owed or 0, 0 end
  local r2, total, happy = M.RADIUS * M.RADIUS, 0, 0
  for hi, h in ipairs(houses) do
    local n = h.occupants or 0
    total = total + n
    if n > 0 then
      local best, best_d
      for ti, t in ipairs(taverns) do
        local d = dist2(t.position, h.position)
        if d <= r2 and left[ti] > 0 and (not best_d or d < best_d) then
          best, best_d = ti, d
        end
      end
      if best then
        served[hi] = best
        debt[best] = debt[best] + n * M.ALE_PER_COLONIST
        local take = math.min(math.floor(debt[best] + 1e-9), left[best])
        debt[best], left[best], used[best] = debt[best] - take, left[best] - take, used[best] + take
        happy = happy + n
      end
    end
  end
  for i in ipairs(taverns) do owed[i] = debt[i] end
  return served, used, owed, total > 0 and happy / total or 0
end

-- Work ticks for one trip by an (un)inspired colonist.
function M.work_ticks(base, inspired)
  if inspired then return math.floor(base / M.INSPIRED_SPEED + 0.5) end
  return base
end

-- What to haul to a Tavern: ale up to STOCK, counting what is already on the way.
function M.wants(ale, inflight)
  local want = M.STOCK - (ale or 0) - (inflight or 0)
  if want >= 1 then return {{item = M.ITEM, count = want}} end
  return {}
end

return M
