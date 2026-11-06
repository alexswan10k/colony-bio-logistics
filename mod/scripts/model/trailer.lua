---@diagnostic enable: undefined-field, missing-fields
-- PURE: Haul Station + Wooden Trailer rules (#94). A station is distributed colony storage (like a Warehouse);
-- a hauler checks a Wooden Trailer out of the nearest station in reach (like a car out of a Motor Pool), pulls
-- a 3x hand-load on foot, and returns the trailer to the station at delivery. A trailer wears like a tool and
-- breaks after TRAILER_USES trips. No new pathing and no explicit A->B pair routing in this first slice: the
-- load still comes from the haul planner's source, the station is just the trailer depot.
local yields = require("scripts.model.yields")

local M = {}

M.TRAILER_ITEM = "colony-wooden-trailer"
M.REACH = 48              -- a hauler only shops for a trailer this close to a station (tiles, like Motor Pool)
M.CAPACITY = yields.TRAILER_CAP      -- 60 items with a trailer (3x a 20-item hand-load)
M.MIN_LOAD = yields.TRAILER_MIN_LOAD -- a trailer only goes out for more than hands carry
M.USES = yields.TRAILER_USES         -- trailer trips before it breaks (like a tool)
M.SPEED = yields.TRAILER_SPEED       -- movement multiplier with a trailer (loaded, slow)

-- Is this load worth a trailer? A hand-load is CARRY_CAP, so a trailer only goes out for more.
---@param load_total integer|nil
---@return boolean
function M.worth_trailer(load_total)
  return (load_total or 0) >= M.MIN_LOAD
end

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

-- The station (record) a hauler at pos should shop at: nearest in reach that holds a trailer, ties by
-- unit-number key, so the choice is stable. `stations` is [{pos={x,y}, trailers=integer, key=integer}].
---@param stations table[]
---@param pos {x: number, y: number}
---@return integer|nil
function M.nearest(stations, pos)
  local best_i, best_d, best_key
  for i, s in ipairs(stations or {}) do
    if (s.trailers or 0) > 0 and s.pos then
      local d = dist2(pos.x, pos.y, s.pos.x, s.pos.y)
      if d <= M.REACH * M.REACH and (not best_d or d < best_d or (d == best_d and (s.key or 0) < (best_key or 0))) then
        best_i, best_d, best_key = i, d, s.key
      end
    end
  end
  return best_i
end

-- Count one trip of wear. Returns new wear counter and whether the trailer breaks now (mirrors labour.wear).
---@param counter integer
---@return integer, boolean
function M.wear(counter)
  counter = (counter or 0) + 1
  if counter >= M.USES then return 0, true end
  return counter, false
end

-- Trips left before the station's trailer breaks (for the station panel).
---@param wear integer|nil
---@return integer
function M.uses_left(wear)
  return math.max(0, M.USES - (wear or 0))
end

return M
