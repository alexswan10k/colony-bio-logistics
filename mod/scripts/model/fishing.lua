-- PURE: fishing rules (#80, design §3.1, §7 coastal specialization).
--
-- The Fishing Dock is the first building whose placement is a real decision: it only works with water beside
-- it. The rule is a count of water tiles in a fixed box, checked once when the dock is built, so the
-- interesting part (the sampling) belongs to the adapter and the *policy* lives here where it can be tested.
local yields = require("scripts.model.yields")

local M = {}

M.BOX = 15              -- half-size of the box sampled around the dock, in tiles
M.MIN_WATER = 6         -- water tiles needed in that box for the dock to count as coastal
M.FISH_PER_TRIP = yields.FISH.count   -- a little better than foraging, because water access is earned
M.ROD = "colony-rod"

-- Enough water to call it a shore?
function M.shore_ok(water) return (water or 0) >= M.MIN_WATER end

-- Offsets outward from the centre: 0, +1, -1, +2, -2, ... . Visiting tiles this way means a dock that really
-- is on a shore answers in a handful of reads, and only a doomed placement pays for the whole box.
local function offsets(box, stride)
  local out = {0}
  for v = stride, box, stride do
    out[#out + 1] = v
    out[#out + 1] = -v
  end
  return out
end

-- Scan the square box around `pos`, calling `is_water(x, y)`, and stop as soon as the answer is known.
-- Returns (on_shore, water_count_found).
function M.on_shore(pos, is_water, box, stride, need)
  box = box or M.BOX
  stride = stride or 1
  need = need or M.MIN_WATER
  local off, found = offsets(box, stride), 0
  for _, dy in ipairs(off) do
    local y = pos.y + dy
    for _, dx in ipairs(off) do
      if is_water(pos.x + dx, y) then
        found = found + 1
        if found >= need then return true, found end
      end
    end
  end
  return false, found
end

return M
