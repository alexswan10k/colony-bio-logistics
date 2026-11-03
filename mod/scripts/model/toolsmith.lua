-- PURE: the Toolsmith. A staffed labour hut with no tool of its own: a colonist makes the tools huts are waiting on
-- from wood, iron and copper that haulers bring it. Supply-gated like the Kitchen (no tool needed), but slower, and
-- every tool it makes costs labour. The recipes are workshop.RECIPES (the same numbers as the hand-craft recipes in
-- prototypes/buildings.lua); this module only decides what to make and what to ask for.
local workshop = require("scripts.model.workshop")

local M = {}

M.NAME = "colony-toolsmith"
-- A tool takes this many normal work spells: 3 x 8 s of work, plus the walk, is roughly 30 s per tool (was 10 s
-- when the Town Hall workshop made them for free).
M.WORK_MULT = 3

-- Input stock a Toolsmith asks for, in a fixed order. Enough for the largest tool (a rifle) once over.
M.STOCK = {{item = "wood", n = 8}, {item = "iron-plate", n = 12}, {item = "copper-plate", n = 4}}

function M.work_ticks(base)
  return base * M.WORK_MULT
end

-- The tool to make this pass, or nil: the first wanted tool that is unlocked and makeable from the hut's own `stock`.
-- wanted = ordered list of tool names; stock = {item -> n} in the Toolsmith; unlocked = {tool -> true}.
function M.pick(wanted, stock, unlocked)
  for _, tool in ipairs(wanted) do
    if unlocked[tool] and workshop.RECIPES[tool] and next(workshop.missing(tool, stock)) == nil then
      return tool, workshop.RECIPES[tool]
    end
  end
  return nil
end

-- The tools the Toolsmith should make, in order: first the tools huts are short of (gap_tools), then one spare of
-- each tool a built hut uses (built_tools). A tool only goes on the list while the colony has none in stock, so
-- the Toolsmith keeps one spare rather than piling tools up, and only when colony stock holds its ingredients: a
-- rifle with no copper in the colony is not wanted (the advice for that hut is `gap`, not a request). stock = colony
-- stock {item -> n}.
function M.wanted(gap_tools, built_tools, stock)
  local out, seen = {}, {}
  local function add(tool)
    if not seen[tool] and (stock[tool] or 0) <= 0 and workshop.RECIPES[tool]
        and next(workshop.missing(tool, stock)) == nil then
      seen[tool] = true
      out[#out + 1] = tool
    end
  end
  for _, tool in ipairs(gap_tools) do add(tool) end
  for _, tool in ipairs(built_tools) do add(tool) end
  return out
end

-- Input stock a Toolsmith wants delivered: wood, iron and copper up to the buffer, counting what is already there
-- and on the way.
function M.wants(counts, inflight)
  local out = {}
  for _, want in ipairs(M.STOCK) do
    local n = want.n - (counts[want.item] or 0) - ((inflight and inflight[want.item]) or 0)
    if n > 0 then out[#out + 1] = {item = want.item, count = n} end
  end
  return out
end

-- Advice for a hut short of `tool` with none in colony stock. facts: toolsmith (a built Toolsmith exists), unlocked
-- (the tool's recipe is researched), missing {item -> n} (what colony stock lacks for the recipe). Returns
-- "craft" (no Toolsmith to make it: craft one by hand), "making" (the Toolsmith has what it needs), or
-- "short", item, n (colony stock is short of an ingredient; the first one by name).
function M.gap(f)
  if not (f.toolsmith and f.unlocked) then return "craft" end
  local items = {}
  for item in pairs(f.missing or {}) do items[#items + 1] = item end
  if #items == 0 then return "making" end
  table.sort(items)
  return "short", items[1], f.missing[items[1]]
end

return M
