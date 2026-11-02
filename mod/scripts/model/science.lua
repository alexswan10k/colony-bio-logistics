-- PURE: colony science rules (#42, design §8).
--
-- Towns conduct research via custom science packs (Frontier Charters, Civic Treatises)
-- studied in Town Archives and Universities staffed by scholars.

local M = {}

M.FRONTIER_PACK = "colony-frontier-pack"
M.CIVIC_PACK = "colony-civic-pack"

M.ARCHIVE = "colony-town-archive"
M.UNIVERSITY = "colony-university"

M.BUFFER_STOCK = 10

M.PACKS_BY_LAB = {
  [M.ARCHIVE] = {M.FRONTIER_PACK},
  [M.UNIVERSITY] = {M.FRONTIER_PACK, M.CIVIC_PACK},
}

-- Returns list of item demands for a lab building to keep its input buffer stocked.
function M.wants(lab_name, counts, inflight)
  local packs = M.PACKS_BY_LAB[lab_name] or {}
  local out = {}
  for _, item in ipairs(packs) do
    local have = (counts and counts[item] or 0) + (inflight and inflight[item] or 0)
    local deficit = M.BUFFER_STOCK - have
    if deficit > 0 then
      out[#out + 1] = {item = item, count = deficit}
    end
  end
  return out
end

return M
