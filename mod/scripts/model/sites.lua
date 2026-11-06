---@diagnostic enable: undefined-field, missing-fields
-- PURE: which site a colonist works (#93). A hut is already chosen near home (work.candidates_for); this is
-- the same idea one level down, for the tree / ore patch / plot inside the hut's radius.
--
-- The walk hut -> site -> hut dominates: the loop starts and ends at the hut, so "nearest the hut" stays the
-- first key. The colonist's house only settles genuinely close calls (candidates in the same distance band),
-- which is a small nudge towards compact towns without ever sending someone across the radius to be near home.
local M = {}

M.TIE_TILES = 8     -- candidates within this many tiles of the nearest count as the same band

---@param a table
---@param b table
---@return number
local function d2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end
M.dist2 = d2

-- Sortable position of a candidate: (distance band from the hut, distance from home, exact distance, unit
-- number). Totally ordered, so the same set of candidates always picks the same site.
---@param candidate table
---@param pos table
---@param home table|nil
---@param tie number|nil
---@return table
function M.key(candidate, pos, home, tie)
  tie = tie or M.TIE_TILES
  local d = d2(candidate.position, pos)
  return {
    band = math.floor(d / (tie * tie)),
    home = home and d2(candidate.position, home) or 0,
    dist = d,
    unit = candidate.unit_number or 0,
  }
end

function M.less(a, b)
  if a.band ~= b.band then return a.band < b.band end
  if a.home ~= b.home then return a.home < b.home end
  if a.dist ~= b.dist then return a.dist < b.dist end
  return a.unit < b.unit
end

-- Best valid candidate, or nil. `accept` is an optional predicate (in territory, not claimed, ...).
-- Same order as `key`/`less`, written out without allocating: a tree scan can offer hundreds of candidates.
function M.best(candidates, pos, accept, home, tie)
  tie = tie or M.TIE_TILES
  local tie2 = tie * tie
  local best, best_band, best_home, best_dist, best_unit
  for _, c in ipairs(candidates or {}) do
    if c.valid ~= false and (not accept or accept(c)) then
      local p = c.position
      local dx, dy = p.x - pos.x, p.y - pos.y
      local d = dx * dx + dy * dy
      local band = math.floor(d / tie2)
      local h = 0
      if home then
        local hx, hy = p.x - home.x, p.y - home.y
        h = hx * hx + hy * hy
      end
      local unit = c.unit_number or 0
      local better
      if not best then better = true
      elseif band ~= best_band then better = band < best_band
      elseif h ~= best_home then better = h < best_home
      elseif d ~= best_dist then better = d < best_dist
      else better = unit < best_unit end
      if better then best, best_band, best_home, best_dist, best_unit = c, band, h, d, unit end
    end
  end
  return best
end

return M
