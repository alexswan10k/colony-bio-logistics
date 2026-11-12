---@diagnostic enable: undefined-field, missing-fields
-- PURE: tool recipes and what they cost. The Toolsmith (model/toolsmith.lua) makes tools from these; the Town Hall
-- no longer makes anything for free. Mirrors the tool recipes in prototypes/buildings.lua, and the adapter only
-- offers tools whose recipe the force has unlocked, so the Toolsmith never gets ahead of the tech tree.
local M = {}

---@type table<string, table<string, integer>>
M.RECIPES = {
  ["colony-basket"] = {wood = 4},
  ["colony-axe"] = {wood = 2, ["iron-plate"] = 3},
  ["colony-pickaxe"] = {wood = 2, ["iron-plate"] = 3},
  ["colony-hoe"] = {wood = 2, ["iron-plate"] = 3},
  -- Tier-2 steel (#95): no wood, costs steel + iron. Mirrors prototypes/buildings.lua. Lasts 45 trips
  -- at 0.8x work ticks (yields.STEEL_*), so the town shifts demand from trees to plates.
  ["colony-steel-axe"] = {["iron-plate"] = 2, ["steel-plate"] = 1},
  ["colony-steel-pickaxe"] = {["iron-plate"] = 2, ["steel-plate"] = 1},
  ["colony-steel-hoe"] = {["iron-plate"] = 2, ["steel-plate"] = 1},
  ["colony-rod"] = {wood = 3, ["iron-plate"] = 2},
  ["colony-spade"] = {wood = 2, ["iron-plate"] = 2},   -- Forester's Hut (#97): plants saplings
  ["colony-bow"] = {wood = 4},
  ["colony-arrow"] = {wood = 1},
  ["colony-rifle"] = {wood = 4, ["iron-plate"] = 6, ["copper-plate"] = 2},
}

-- Ingredients that stop `stock` from making `tool`, as {item -> missing}; empty when it can be made.
---@param tool string
---@param stock ItemCount
---@return ItemCount
function M.missing(tool, stock)
  local out = {}
  for item, n in pairs(M.RECIPES[tool] or {}) do
    local have = stock[item] or 0
    if have < n then out[item] = n - have end
  end
  return out
end

return M
