-- PURE: labour-building rules. A hut employs up to `capacity` colonists, but only as many as it holds tools for.
local yields = require("scripts.model.yields")

local M = {}
M.HUTS = {
  ["colony-forager-hut"] = {job = "forage", tool = "colony-basket", capacity = 3},
  ["colony-woodcutter-hut"] = {job = "chop", tool = "colony-axe", capacity = 3},
  ["colony-miner-hut"] = {job = "mine", tool = "colony-pickaxe", capacity = 3},
  ["colony-farm-hut"] = {job = "farm", tool = "colony-hoe", capacity = 3},
  ["colony-hunting-lodge"] = {job = "hunt", tool = "colony-rifle", capacity = 3},
  ["colony-fishing-dock"] = {job = "fish", tool = "colony-rod", capacity = 3},
  -- No `tool`: a Smokehouse is gated by its inputs (salt + raw food), not by equipment (#81). `keep` lists the
  -- items that are *inputs*, so haulers do not treat them as hut output and cart them straight back to the hall.
  ["colony-smokehouse"] = {job = "preserve", capacity = 2,
    keep = {"colony-salt", "colony-meat", "colony-fish"}},
}
-- Worker trips before one tool in the hut wears out. A trip is ~10s of walking + 8s of work, so a hut
-- with three workers loses a tool roughly every 1-2 minutes: fast enough to see, slow enough to be logistics.
M.TOOL_USES = yields.TOOL_USES

-- A hut employs up to `capacity` colonists, but only as many as it holds tools for and as the player's
-- per-hut worker limit allows (`limit` nil = no player limit). A hut with no tool is supply-gated instead,
-- and reports its capacity as the allowance (the adapter checks its inputs before sending anyone to work).
function M.allowed(capacity, tools_in_hut, limit)
  local cap = math.min(capacity, limit or capacity)
  return math.max(0, math.min(cap, tools_in_hut))
end

-- Count one trip of wear. Returns new wear counter and whether a tool breaks now.
function M.wear(counter)
  counter = counter + 1
  if counter >= M.TOOL_USES then return 0, true end
  return counter, false
end

-- Remaining uses for the tool currently in service (for the hut GUI).
function M.uses_left(wear) return math.max(0, M.TOOL_USES - (wear or 0)) end

-- Free slots per job: huts = array of {job=, allowed=, workers=} -> {job -> n}
function M.free_slots(huts)
  local out = {}
  for _, h in ipairs(huts) do
    local free = h.allowed - h.workers
    if free > 0 then out[h.job] = (out[h.job] or 0) + free end
  end
  return out
end

-- Total tooled slots per job (used to give every built hut at least one worker).
function M.capacity_by_job(huts)
  local out = {}
  for _, h in ipairs(huts) do out[h.job] = (out[h.job] or 0) + h.allowed end
  return out
end

return M
