---@diagnostic enable: undefined-field, missing-fields
-- PURE: colony crate rules (design §5.1, issue #33).
-- A Supply Crate is a provider: colonists empty whatever is inside into colony stock, so a belt can hand
-- off to the colony without inserters into the Town Hall. A Demand Crate is a requester: the player sets
-- item filters and target counts, and colonists fill it so inserters can pull from it. A Warehouse is bulk
-- stock: it counts as colony storage for both sourcing and depositing (see colony.stock_count).
local M = {}

M.SUPPLY, M.DEMAND, M.WAREHOUSE = "supply", "demand", "warehouse"
M.HAUL_STATION = "station"   -- #94: bulk stock like a Warehouse, plus a trailer depot (work.lua checks the station back out)
M.FILTER_ROWS = 4
M.DEFAULT_COUNT = 50
M.MAX_COUNT = 400

local function by_item(a, b) return a.item < b.item end

-- Targets for a demand crate: filters minus what the crate holds and what is already in flight.
-- Only rows with an item count; an empty row is not a demand.
-- Uses hysteresis: requests are triggered when have <= 50% target or deficit >= 10 (or force_reorder).
function M.demands(filters, contents, inflight, force_reorder)
  local out = {}
  for i = 1, M.FILTER_ROWS do
    local f = filters and filters[i]
    if f and f.item then
      local target = f.count or M.DEFAULT_COUNT
      local have = ((contents and contents[f.item]) or 0) + ((inflight and inflight[f.item]) or 0)
      local want = target - have
      local threshold = math.max(0, math.floor(target * 0.5))
      if want >= 1 and (force_reorder or have <= threshold or want >= 10) then
        out[#out + 1] = {item = f.item, count = want}
      end
    end
  end
  table.sort(out, by_item)   -- deterministic regardless of the order the player filled the rows
  return out
end

-- Everything a supply crate offers: it is a provider, so it hands over its whole contents.
function M.supply(contents)
  local out = {}
  for item, n in pairs(contents or {}) do
    if n and n >= 1 then out[#out + 1] = {item = item, count = n} end
  end
  table.sort(out, by_item)
  return out
end

-- The filters are a fixed-size list of rows so the panel and the stored table never disagree.
function M.set_filter(filters, row, item)
  filters[row] = filters[row] or {count = M.DEFAULT_COUNT}
  filters[row].item = item
end

function M.set_count(filters, row, count)
  filters[row] = filters[row] or {}
  count = math.floor(tonumber(count) or 0)
  if count < 0 then count = 0 end
  if count > M.MAX_COUNT then count = M.MAX_COUNT end
  filters[row].count = count
end

-- How many target items a crate still wants, for the panel's "N / target" line.
function M.filled(filters, contents)
  local n, target = 0, 0
  for i = 1, M.FILTER_ROWS do
    local f = filters and filters[i]
    if f and f.item then
      target = target + (f.count or M.DEFAULT_COUNT)
      n = n + math.min((contents and contents[f.item]) or 0, f.count or M.DEFAULT_COUNT)
    end
  end
  return n, target
end

return M