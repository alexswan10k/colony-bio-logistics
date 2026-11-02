-- PURE: kitchen cooking and baking rules (#44, design §3.1).
--
-- A Kitchen combines agricultural produce with well water to bake bread, extending shelf life (60 min)
-- and closing the mid-game agriculture loop. Like the Smokehouse, it is supply-gated (no tool needed).

local M = {}

M.PRODUCE = "colony-produce"
M.WATER = "colony-water"
M.PRODUCT = "colony-bread"

M.PRODUCE_PER_BATCH = 1
M.WATER_PER_BATCH = 1
M.PRODUCT_PER_BATCH = 1

M.PRODUCE_STOCK = 4
M.WATER_STOCK = 4

-- What can be cooked from this stock? Returns {product = ...} or nil.
function M.recipe(stock)
  if (stock[M.PRODUCE] or 0) >= M.PRODUCE_PER_BATCH and (stock[M.WATER] or 0) >= M.WATER_PER_BATCH then
    return {product = M.PRODUCT}
  end
  return nil
end

-- What a Kitchen wants delivered: produce and water up to stock buffer.
function M.wants(counts, inflight)
  local out = {}
  local function add(item, want)
    local n = want - (counts[item] or 0) - ((inflight and inflight[item]) or 0)
    if n > 0 then out[#out + 1] = {item = item, count = n} end
  end
  add(M.PRODUCE, M.PRODUCE_STOCK)
  add(M.WATER, M.WATER_STOCK)
  return out
end

return M
