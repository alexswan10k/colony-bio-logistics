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
-- Steel buffer (#95): only asked for while a steel tool is actually wanted (see M.wants), enough for
-- a few steel tools at 1 steel each. Keeps the Toolsmith from hoarding steel before Steel Tools unlocks.
M.STEEL_STOCK = {item = "steel-plate", n = 4}

-- Steel ladders (#95): tier-1 -> tier-2, best-first. The Toolsmith covers tier-1 gaps before it asks
-- for tier-2 upgrades (M.wanted suppresses steel while its tier-1 gap exists).
M.LADDER = {
  ["colony-axe"] = {"colony-steel-axe", "colony-axe"},
  ["colony-pickaxe"] = {"colony-steel-pickaxe", "colony-pickaxe"},
  ["colony-hoe"] = {"colony-steel-hoe", "colony-hoe"},
}
M.TIER1_OF = {
  ["colony-steel-axe"] = "colony-axe", ["colony-steel-pickaxe"] = "colony-pickaxe",
  ["colony-steel-hoe"] = "colony-hoe",
}
M.STEEL = {["colony-steel-axe"] = true, ["colony-steel-pickaxe"] = true, ["colony-steel-hoe"] = true}

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
-- each tool a built hut uses (built_tools), or up to the configured quota. A tool only goes on the list while the colony
-- stock is below target, and only when colony stock holds its ingredients: a rifle with no copper in the colony is not
-- wanted (the advice for that hut is `gap`, not a request). stock = colony stock {item -> n}.
-- Tier-1 first (#95): a steel tool is not wanted as a spare or quota while its tier-1 gap exists, so the
-- Toolsmith fills empty huts before it upgrades them.
function M.wanted(gap_tools, built_tools, stock, quotas)
  local out, seen = {}, {}
  local gap_set = {}
  for _, tool in ipairs(gap_tools or {}) do gap_set[tool] = true end
  local function suppressed(tool)
    local t1 = M.TIER1_OF[tool]
    return t1 ~= nil and gap_set[t1] == true
  end
  local function target_for(tool)
    if quotas and quotas[tool] ~= nil then
      return tonumber(quotas[tool]) or 0
    end
    return 1
  end

  local function add(tool, min_needed)
    if seen[tool] or not workshop.RECIPES[tool] then return end
    if next(workshop.missing(tool, stock)) ~= nil then return end
    local have = stock[tool] or 0
    local tgt = math.max(target_for(tool), min_needed or 0)
    if have < tgt then
      seen[tool] = true
      out[#out + 1] = tool
    end
  end

  for _, tool in ipairs(gap_tools) do add(tool, 1) end
  for _, tool in ipairs(built_tools) do
    if not suppressed(tool) then add(tool, 0) end
  end
  if quotas then
    local sorted = {}
    for tool, tgt in pairs(quotas) do
      if tonumber(tgt) and tonumber(tgt) > 0 and not seen[tool] and not suppressed(tool) then
        sorted[#sorted + 1] = tool
      end
    end
    table.sort(sorted)
    for _, tool in ipairs(sorted) do add(tool, 0) end
  end
  return out
end

-- Input stock a Toolsmith wants delivered: wood, iron and copper up to the buffer, counting what is already there
-- and on the way. `wanted` is the Toolsmith wanted list: steel-plate is only buffered while a steel tool
-- is wanted (#95), so the Toolsmith does not hoard steel before the upgrade is due.
function M.wants(counts, inflight, wanted)
  local out = {}
  for _, want in ipairs(M.STOCK) do
    local n = want.n - (counts[want.item] or 0) - ((inflight and inflight[want.item]) or 0)
    if n > 0 then out[#out + 1] = {item = want.item, count = n} end
  end
  local wants_steel = false
  if wanted then
    for _, tool in ipairs(wanted) do
      if M.STEEL[tool] then wants_steel = true; break end
    end
  end
  if wants_steel then
    local want = M.STEEL_STOCK
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
