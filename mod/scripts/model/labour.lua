-- PURE: labour-building rules. A hut employs up to `capacity` colonists, but only as many as it holds tools for.
local M = {}
M.HUTS = {
  ["colony-forager-hut"] = {job = "forage", tool = "colony-basket", capacity = 3},
  ["colony-woodcutter-hut"] = {job = "chop", tool = "colony-axe", capacity = 3},
  ["colony-miner-hut"] = {job = "mine", tool = "colony-pickaxe", capacity = 3},
}
M.TOOL_USES = 25    -- worker trips before one tool in the hut wears out

function M.allowed(capacity, tools_in_hut) return math.max(0, math.min(capacity, tools_in_hut)) end

-- Count one trip of wear. Returns new wear counter and whether a tool breaks now.
function M.wear(counter)
  counter = counter + 1
  if counter >= M.TOOL_USES then return 0, true end
  return counter, false
end

-- Free slots per job: huts = array of {job=, allowed=, workers=} -> {job -> n}
function M.free_slots(huts)
  local out = {}
  for _, h in ipairs(huts) do
    local free = h.allowed - h.workers
    if free > 0 then out[h.job] = (out[h.job] or 0) + free end
  end
  return out
end

return M
