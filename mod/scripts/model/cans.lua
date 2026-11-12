---@diagnostic enable: undefined-field, missing-fields
-- PURE: canning rules (#45). A Cannery converts preserved food into canned goods: same nutrition, four
-- hours of shelf life (~5x the smokehouse), paid for with the tin (iron plate) and a wash (colony water).
-- It sits *after* the smokehouse in the chain: raw -> preserved -> canned. Raw items are deliberately not
-- accepted, so the Cannery is not a shortcut around curing.
local M = {}

M.PRODUCT_PER_BATCH = 1
M.PLATES_PER_BATCH = 1
M.WATER_PER_BATCH = 1
M.PLATE_STOCK = 4            -- iron on hand, so the cannery is not stripped by its own output
M.WATER_STOCK = 4            -- colony-water for the brine wash
M.PRESERVED_STOCK = 2        -- per preserved item, so a cannery never empties the smokehouse's output
M.RAW = {"colony-preserved-meat", "colony-preserved-fish"}
M.PRODUCT = {["colony-preserved-meat"] = "colony-canned-meat",
             ["colony-preserved-fish"] = "colony-canned-fish"}

-- What can be canned from this stock? {raw=, product=} or nil. Meat is tried first, so the choice is stable
-- when the hut holds both.
function M.recipe(stock)
  if ((stock["iron-plate"]) or 0) < M.PLATES_PER_BATCH then return nil end
  if ((stock["colony-water"]) or 0) < M.WATER_PER_BATCH then return nil end
  for _, raw in ipairs(M.RAW) do
    if (stock[raw] or 0) >= 1 then return {raw = raw, product = M.PRODUCT[raw]} end
  end
  return nil
end

-- What a Cannery wants delivered: tin stock, water, and a little of each preserved item.
function M.wants(counts, inflight)
  local out = {}
  local function add(item, want)
    local n = want - (counts[item] or 0) - ((inflight and inflight[item]) or 0)
    if n > 0 then out[#out + 1] = {item = item, count = n} end
  end
  add("iron-plate", M.PLATE_STOCK)
  add("colony-water", M.WATER_STOCK)
  for _, raw in ipairs(M.RAW) do add(raw, M.PRESERVED_STOCK) end
  return out
end

return M
