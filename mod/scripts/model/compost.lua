---@diagnostic enable: undefined-field, missing-fields
-- PURE: the spoilage loop (design §3.2, #78).
--
-- Spoiled food is vanilla `spoilage`: useless, and it does not go away on its own. Left alone it fills the
-- house it was delivered to, which then cannot take more food and starves its occupants while the Town Hall
-- has stock - so somebody has to carry it out. A Compost Bin turns batches of it into fertilizer.
local M = {}

M.SPOILAGE_PER_FERTILIZER = 10    -- one fertilizer per ten spoilage
M.SOURCE = "spoilage"
M.PRODUCT = "colony-fertilizer"

-- How much of a bin's spoilage converts in one pass: the number of fertilizer it yields, and what is left
-- over (it stays in the bin and waits for the next batch).
function M.batches(spoilage)
  local n = math.max(0, math.floor(tonumber(spoilage) or 0))
  local out = math.floor(n / M.SPOILAGE_PER_FERTILIZER)
  return out, n - out * M.SPOILAGE_PER_FERTILIZER
end

return M
