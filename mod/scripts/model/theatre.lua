---@diagnostic enable: undefined-field, missing-fields
-- PURE: Theatres (#48 slice B). A Theatre is worker-free, needs no consumable, and inspires every occupied
-- house within RADIUS at QUALITY 1.5 (overriding a Tavern's 1.25). It is the expensive, short-range cousin of
-- the Tavern: no ale to brew or haul, but a smaller radius to justify that. No Factorio globals here - the
-- adapter owns entities and only hands in plain positions and occupant counts.
local inspiration = require("scripts.model.inspiration")
local M = {}

M.RADIUS = 16              -- tiles from a Theatre to a house it inspires (Tavern is 24)
M.QUALITY = inspiration.THEATRE  -- keep in step with the research/work rule; never hard-code 1.5 twice

local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- theatres: array of {position={x=,y=}} in a stable order; houses: array of {position={x=,y=}, occupants=}
-- in a stable order. Returns served (house index -> true) and coverage (0..1 = inspired residents / all
-- residents). A house is served if ANY Theatre is within RADIUS (squared distance, <=). Empty houses are
-- never servable and contribute no residents to either side of the ratio; the denominator is all residents
-- in occupied houses. Arrays are walked with ipairs so the result is deterministic and never depends on
-- iteration order over an unordered map.
function M.serve(theatres, houses)
  local served = {}
  local r2 = M.RADIUS * M.RADIUS
  local total, happy = 0, 0
  for hi, h in ipairs(houses or {}) do
    local n = h.occupants or 0
    total = total + n
    if n > 0 then
      local inside = false
      for _, t in ipairs(theatres or {}) do
        local tp, hp = t.position, h.position
        if tp and hp and dist2(tp, hp) <= r2 then inside = true; break end
      end
      if inside then served[hi] = true; happy = happy + n end
    end
  end
  return served, total > 0 and happy / total or 0
end

return M
