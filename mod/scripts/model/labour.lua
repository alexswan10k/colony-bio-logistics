---@diagnostic enable: undefined-field, missing-fields
-- PURE: labour-building rules. A hut employs up to `capacity` colonists, but only as many as it holds tools for.
---@class LabourHutDef
---@field job string
---@field tool string|nil
---@field tools string[]|nil
---@field capacity integer
---@field keep string[]|nil
---@field inputs table[]|nil
---@field requires string[]|nil
local yields = require("scripts.model.yields")

local M = {}
---@type table<string, LabourHutDef>
M.HUTS = {
  ["colony-forager-hut"] = {job = "forage", tool = "colony-basket", capacity = 3},
  ["colony-woodcutter-hut"] = {job = "chop", tool = "colony-axe",
    tools = {"colony-steel-axe", "colony-axe"}, capacity = 3},
  ["colony-miner-hut"] = {job = "mine", tool = "colony-pickaxe",
    tools = {"colony-steel-pickaxe", "colony-pickaxe"}, capacity = 3},
  ["colony-farm-hut"] = {job = "farm", tool = "colony-hoe",
    tools = {"colony-steel-hoe", "colony-hoe"}, capacity = 3,
    keep = {"colony-fertilizer"}, inputs = {{item = "colony-fertilizer", count = 6}}},
  -- Forester's Hut (#97): replants trees so a mature colony can keep a woodcutter busy. Tooled like a
  -- woodcutter, but *supply*-gated as well: it spends one wood out of its own chest per tree planted
  -- (model/forest.lua), so `requires` tells the status line what it is actually waiting for.
  ["colony-forester-hut"] = {job = "forest", tool = "colony-spade", capacity = 2,
    keep = {"wood"}, inputs = {{item = "wood", count = 10}}, requires = {"wood"}},
  ["colony-hunting-lodge"] = {job = "hunt", tool = "colony-bow",
    tools = {"pistol", "submachine-gun", "colony-bow", "colony-rifle"},
    keep = {"colony-arrow", "firearm-magazine", "piercing-rounds-magazine"},
    capacity = 3},
  ["colony-fishing-dock"] = {job = "fish", tool = "colony-rod", capacity = 3},
  -- No `tool`: a Smokehouse or Kitchen is gated by its inputs, not by equipment (#81, #44). `keep` lists the
  -- items that are *inputs*, so haulers do not treat them as hut output and cart them straight back to the hall.
  ["colony-smokehouse"] = {job = "preserve", capacity = 2,
    keep = {"colony-salt", "colony-meat", "colony-fish"}},
  ["colony-kitchen"] = {job = "preserve", capacity = 2,
    keep = {"colony-produce", "colony-water"}},
  -- Toolsmith: the one hut that makes tools, from the wood, iron and copper haulers bring (model/toolsmith.lua).
  ["colony-toolsmith"] = {job = "preserve", capacity = 1, keep = {"wood", "iron-plate", "copper-plate"}},
  -- Research buildings (#42): Town Archive & University. Staffed by scholars, supplied with science packs.
  ["colony-town-archive"] = {job = "research", capacity = 2,
    keep = {"colony-frontier-pack"}, inputs = {{item = "colony-frontier-pack", count = 10}}},
  ["colony-university"] = {job = "research", capacity = 4,
    keep = {"colony-frontier-pack", "colony-civic-pack"},
    inputs = {{item = "colony-frontier-pack", count = 10}, {item = "colony-civic-pack", count = 10}}},
  -- Clinic (#47): doctors staff it while it holds medicine and someone is sick.
  ["colony-clinic"] = {job = "heal", capacity = 2, keep = {"colony-herbal-medicine"}, inputs = {{item = "colony-herbal-medicine", count = 10}}},
  -- Garrisoned Watchtower (#56): a guard post. The tower's stock room is the armory: bows and rifles/guns inside it
  -- open posts. Weapons wear out (or consume ammo) per engagement.
  -- Registered as a hut with limit = 0 by default, so an unmanned tower never nags; the player mans it.
  ["colony-watchtower"] = {job = "guard", tool = "colony-bow",
    tools = {"pistol", "submachine-gun", "colony-bow", "colony-rifle"},
    keep = {"colony-arrow", "firearm-magazine", "piercing-rounds-magazine"},
    capacity = 4},
}
-- Worker trips before one tool in the hut wears out. A trip is ~10s of walking + 8s of work, so a hut
-- with three workers loses a tool roughly every 1-2 minutes: fast enough to see, slow enough to be logistics.
M.TOOL_USES = yields.TOOL_USES
M.STEEL_TOOL_USES = yields.STEEL_TOOL_USES
M.STEEL_WORK_MULT = yields.STEEL_WORK_MULT
-- Trips per tool by tier (#95). Unlisted tools use TOOL_USES.
M.USES = {
  ["colony-steel-axe"] = yields.STEEL_TOOL_USES,
  ["colony-steel-pickaxe"] = yields.STEEL_TOOL_USES,
  ["colony-steel-hoe"] = yields.STEEL_TOOL_USES,
}
-- Work-spell multiplier by tier (#95): steel works 20% faster (480 -> 384 ticks).
M.WORK_MULT = {
  ["colony-steel-axe"] = yields.STEEL_WORK_MULT,
  ["colony-steel-pickaxe"] = yields.STEEL_WORK_MULT,
  ["colony-steel-hoe"] = yields.STEEL_WORK_MULT,
}
M.STEEL = {["colony-steel-axe"] = true, ["colony-steel-pickaxe"] = true, ["colony-steel-hoe"] = true}

-- A hut employs up to `capacity` colonists, but only as many as it holds tools for and as the player's
-- per-hut worker limit allows (`limit` nil = no player limit). A hut with no tool is supply-gated instead,
-- and reports its capacity as the allowance (the adapter checks its inputs before sending anyone to work).
---@param capacity integer
---@param tools_in_hut integer
---@param limit integer|nil
---@return integer
function M.allowed(capacity, tools_in_hut, limit)
  local cap = math.min(capacity, limit or capacity)
  return math.max(0, math.min(cap, tools_in_hut))
end

-- Trips before a tool of this tier wears out (#95). nil = default tier.
---@param tool string|nil
---@return integer
function M.uses_for(tool) return tool and M.USES[tool] or M.TOOL_USES end

-- Count one trip of wear. Returns new wear counter and whether a tool breaks now. `tool` is the tier in
-- service (the best present in the hut), so a steel hut lasts STEEL_TOOL_USES.
---@param counter integer
---@param tool string|nil
---@return integer, boolean
function M.wear(counter, tool)
  counter = counter + 1
  if counter >= M.uses_for(tool) then return 0, true end
  return counter, false
end

-- Remaining uses for the tool currently in service (for the hut GUI).
---@param wear integer|nil
---@param tool string|nil
---@return integer
function M.uses_left(wear, tool) return math.max(0, M.uses_for(tool) - (wear or 0)) end

-- Work ticks for a trip with this tool (#95): steel spells are 0.8x (480 -> 384).
---@param base integer
---@param tool string|nil
---@return integer
function M.work_ticks(base, tool)
  return math.floor(base * (tool and M.WORK_MULT[tool] or 1) + 0.5)
end

-- Best tool present in a ladder (best-first array, like garrison.PREFERENCE for weapons) (#95).
---@param counts ItemCount|nil
---@param ladder string[]|nil
---@return string|nil
function M.best_tool(counts, ladder)
  if not (counts and ladder) then return nil end
  for _, t in ipairs(ladder) do
    if (counts[t] or 0) > 0 then return t end
  end
  return nil
end

-- Worst tool present, for consumption: a mixed hut wears its tier-1 first and keeps its steel, so the
-- upgrade sticks instead of being spent first (#95).
---@param counts ItemCount|nil
---@param ladder string[]|nil
---@return string|nil
function M.worst_tool(counts, ladder)
  if not (counts and ladder) then return nil end
  for i = #ladder, 1, -1 do
    if (counts[ladder[i]] or 0) > 0 then return ladder[i] end
  end
  return nil
end

-- Free slots per job: huts = array of {job=, allowed=, workers=} -> {job -> n}
---@param huts HutSlot[]
---@return table<string, integer>
function M.free_slots(huts)
  local out = {}
  for _, h in ipairs(huts) do
    local free = h.allowed - h.workers
    if free > 0 then out[h.job] = (out[h.job] or 0) + free end
  end
  return out
end

-- Entries of one job that still have a free slot, least-staffed first (ties by `id` so the pick is
-- deterministic). Spreading a role this way means a hut built further from the hall gets its first worker
-- while the oldest hut is only on its second or third; filling hut-by-hut starved everything built later.
---@param slots HutSlot[]
---@return HutSlot[]
function M.spread(slots)
  local out = {}
  for _, sl in ipairs(slots) do
    if sl.allowed > sl.workers then out[#out + 1] = sl end
  end
  table.sort(out, function(a, b)
    local pa = a.priority or (a.hut and a.hut.priority) or 3
    local pb = b.priority or (b.hut and b.hut.priority) or 3
    if pa ~= pb then return pa < pb end
    if a.workers ~= b.workers then return a.workers < b.workers end
    return (a.id or 0) < (b.id or 0)
  end)
  return out
end

-- Total tooled slots per job (used to give every built hut at least one worker).
---@param huts HutSlot[]
---@return table<string, integer>
function M.capacity_by_job(huts)
  local out = {}
  for _, h in ipairs(huts) do out[h.job] = (out[h.job] or 0) + h.allowed end
  return out
end

return M
