-- PURE: the Town Hall workshop. When a hut is waiting on a tool the colony does not have, a colonist at the
-- hall makes one from colony stock - so woodcutters keep foragers in baskets without the player crafting them.
-- Mirrors the tool recipes in prototypes/buildings.lua; the adapter only offers tools whose recipe the force
-- has unlocked, so the workshop never gets ahead of the tech tree.
local M = {}

M.RECIPES = {
  ["colony-basket"] = {wood = 4},
  ["colony-axe"] = {wood = 2, ["iron-plate"] = 3},
  ["colony-pickaxe"] = {wood = 2, ["iron-plate"] = 3},
  ["colony-hoe"] = {wood = 2, ["iron-plate"] = 3},
  ["colony-rod"] = {wood = 3, ["iron-plate"] = 2},
  ["colony-rifle"] = {wood = 4, ["iron-plate"] = 6, ["copper-plate"] = 2},
}

-- Ingredients that stop `stock` from making `tool`, as {item -> missing}; empty when it can be made.
function M.missing(tool, stock)
  local out = {}
  for item, n in pairs(M.RECIPES[tool] or {}) do
    local have = stock[item] or 0
    if have < n then out[item] = n - have end
  end
  return out
end

-- Which tool to make this pass, or nil. gaps = {{tool=, short=}} (huts short of that tool, sorted);
-- stock = {item -> n}; unlocked = {tool -> true}. A tool already in stock is not a gap worth crafting for:
-- a hauler is about to deliver it.
function M.pick(gaps, stock, unlocked)
  for _, g in ipairs(gaps) do
    local tool = g.tool
    if M.RECIPES[tool] and unlocked[tool] and (stock[tool] or 0) <= 0 and next(M.missing(tool, stock)) == nil then
      return tool, M.RECIPES[tool]
    end
  end
  return nil
end

return M
