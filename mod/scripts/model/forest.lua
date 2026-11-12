---@diagnostic enable: undefined-field, missing-fields
-- PURE: replanting rules for the Forester's Hut (#97).
--
-- Chopping was a one-way drain: work.find_site picks the nearest tree and the trip destroys it, and nothing put
-- trees back. A long-lived colony therefore stripped its own territory and had to walk further every trip, while
-- wood stayed a permanent sink (heat for tents/cabins/homesteads, plus every tier-1 tool in workshop.RECIPES).
-- The forester closes the loop: it spends one wood out of its own chest to plant a tree, and a woodcutter gets
-- yields.CHOP.count wood back out of it later. Planting costs a whole trip, so a managed forest is never cheaper
-- than a standing one - it is what a colony does *after* the standing forest is gone.
--
-- The placement rules live here so they can be tested offline:
--   * candidates sit on a *global* lattice, so two Forester's Huts can never crowd each other's trees;
--   * a sapling only takes root on soil (grass/dirt), never on paving, water or sand;
--   * nothing is planted within SPACING of an existing tree, so the hut fills the gaps a woodcutter opened
--     instead of carpeting the map (a dense forest simply has nowhere to plant until it is cut back).
local yields = require("scripts.model.yields")

local M = {}

M.SPACING = 4                 -- tiles between planting spots; also the minimum gap to a standing tree
M.RADIUS = 20                 -- how far from the hut it plants (tiles)
M.SAPLING_COST = 1            -- wood taken from the hut's own chest per tree planted
M.WOOD_PER_TREE = yields.CHOP.count   -- what the woodcutter gets back out of that tree
-- The vanilla prototype that is planted, plus a fixed fallback order (never pairs(): the choice must not depend
-- on hash order, or two peers could plant different species from the same save).
M.TREE = "tree-01"
M.TREE_FALLBACKS = {"tree-02", "tree-03", "tree-04", "tree-05", "tree-06", "tree-07", "tree-08", "tree-09"}

-- Tiles a sapling takes root on: the same soil a tree would grow on (genuine trees do not grow on sand or
-- landfill, and never through concrete or stone path). Unlisted tiles - water, paving, out-of-map - cannot be
-- planted at all.
M.SOIL = {
  ["grass-1"] = true, ["grass-2"] = true, ["grass-3"] = true, ["grass-4"] = true,
  ["dirt-1"] = true, ["dirt-2"] = true, ["dirt-3"] = true, ["dirt-4"] = true,
  ["dirt-5"] = true, ["dirt-6"] = true, ["dirt-7"] = true,
  ["dry-dirt"] = true,
  ["red-desert-0"] = true, ["red-desert-1"] = true, ["red-desert-2"] = true, ["red-desert-3"] = true,
}

---@param tile_name string|nil
---@return boolean
function M.plantable(tile_name) return (tile_name and M.SOIL[tile_name]) or false end

-- Planting spots, nearest first. Positions are snapped to a world-wide lattice of `spacing` tiles offset by half
-- a tile, so they land on tile centres and two huts' lattices share the same points.
---@param base table
---@param radius number|nil
---@param spacing number|nil
---@return table[]
function M.candidates(base, radius, spacing)
  spacing = spacing or M.SPACING
  radius = radius or M.RADIUS
  local out = {}
  local x0 = math.floor((base.x - radius) / spacing) * spacing + 0.5
  local y0 = math.floor((base.y - radius) / spacing) * spacing + 0.5
  for y = y0, base.y + radius, spacing do
    for x = x0, base.x + radius, spacing do
      local dx, dy = x - base.x, y - base.y
      local d2 = dx * dx + dy * dy
      if d2 <= radius * radius then
        out[#out + 1] = {x = x, y = y, d2 = d2}
      end
    end
  end
  table.sort(out, function(a, b)
    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  return out
end

-- Is there a standing tree too close to this spot? `trees` is a list of {x=, y=}.
---@param spot table
---@param trees table[]|nil
---@param spacing number|nil
---@return boolean
function M.blocked(spot, trees, spacing)
  spacing = spacing or M.SPACING
  local limit = spacing * spacing
  for _, t in ipairs(trees or {}) do
    local dx, dy = t.x - spot.x, t.y - spot.y
    if dx * dx + dy * dy < limit then return true end
  end
  return false
end

-- The first candidate that is not blocked by a standing tree and that `accept` allows (tile, land, entity
-- collision - the adapter supplies the world checks), or nil when there is nowhere to plant.
---@param candidates table[]
---@param trees table[]|nil
---@param accept fun(spot: table): boolean|nil
---@param spacing number|nil
---@return table|nil
function M.choose(candidates, trees, accept, spacing)
  for _, spot in ipairs(candidates or {}) do
    if not M.blocked(spot, trees, spacing) and (not accept or accept(spot)) then return spot end
  end
  return nil
end

-- The tree prototype to plant: the vanilla default when the game has it, otherwise the first known fallback that
-- exists. A fixed order, never pairs(): two peers replaying the same save must plant the same species.
---@param exists fun(name: string): boolean|nil
---@return string|nil
function M.tree(exists)
  if not exists then return M.TREE end
  if exists(M.TREE) then return M.TREE end
  for _, name in ipairs(M.TREE_FALLBACKS) do
    if exists(name) then return name end
  end
  return nil
end

-- Wood a planted tree is worth once it has grown, for the balance tables: one wood in, WOOD_PER_TREE out.
---@return integer
function M.net_wood() return M.WOOD_PER_TREE - M.SAPLING_COST end

return M
