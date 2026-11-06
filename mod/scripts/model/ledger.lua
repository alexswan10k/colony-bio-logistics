-- PURE: colony resource ledger logic (#82).
-- Aggregates items stored in Town Hall, warehouses, labour huts, salt pans, and in-transit carries.
local M = {}

local ORDER = {
  ["colony-forage"] = 10, ["colony-fish"] = 11, ["colony-meat"] = 12, ["colony-produce"] = 13,
  ["raw-fish"] = 14, ["colony-salt"] = 15, ["colony-preserved-meat"] = 16, ["colony-preserved-fish"] = 17,
  ["colony-water"] = 18, ["colony-bread"] = 19,
  ["wood"] = 20, ["iron-ore"] = 21, ["copper-ore"] = 22, ["coal"] = 23, ["stone"] = 24,
  ["iron-plate"] = 30, ["copper-plate"] = 31, ["colony-axe"] = 32, ["colony-pickaxe"] = 33,
  ["colony-hoe"] = 34, ["colony-steel-axe"] = 35, ["colony-steel-pickaxe"] = 36, ["colony-steel-hoe"] = 37,
  ["colony-bow"] = 38, ["colony-arrow"] = 39, ["colony-rifle"] = 40, ["colony-rod"] = 41, ["colony-basket"] = 42,
  ["repair-pack"] = 43, ["colony-fertilizer"] = 44, ["colony-furniture"] = 45,
  ["colony-frontier-pack"] = 46, ["colony-civic-pack"] = 47, ["spoilage"] = 48,
}

function M.sort_key(item)
  return ORDER[item] or 100
end

-- data = {
--   stock = { [item] = count },        -- hall + warehouses
--   huts = { {name = string, contents = { [item] = count }} },
--   transit = { {item = string, count = n} },
-- }
-- Returns aggregated ledger table:
-- {
--   items = { {item = string, stock = n, huts = n, transit = n, total = n, hut_details = ...}, ... },
--   totals = { [item] = n },
--   grand_total = n,
-- }
function M.aggregate(data)
  local by_item = {}
  local function get_entry(item)
    local e = by_item[item]
    if not e then
      e = {item = item, stock = 0, huts = 0, transit = 0, total = 0, hut_details = {}}
      by_item[item] = e
    end
    return e
  end

  if data.include_zero then
    for item in pairs(data.include_zero) do
      get_entry(item)
    end
  end

  for item, n in pairs(data.stock or {}) do
    if n > 0 then
      local e = get_entry(item)
      e.stock = e.stock + n
      e.total = e.total + n
    end
  end

  for _, h in ipairs(data.huts or {}) do
    for item, n in pairs(h.contents or {}) do
      if n > 0 then
        local e = get_entry(item)
        e.huts = e.huts + n
        e.total = e.total + n
        e.hut_details[h.name] = (e.hut_details[h.name] or 0) + n
      end
    end
  end

  for _, tr in ipairs(data.transit or {}) do
    if tr and tr.count and tr.count > 0 and tr.item then
      local e = get_entry(tr.item)
      e.transit = e.transit + tr.count
      e.total = e.total + tr.count
    end
  end

  local list = {}
  local totals = {}
  local grand_total = 0
  for item, e in pairs(by_item) do
    if e.total > 0 or (data.include_zero and data.include_zero[item]) then
      list[#list + 1] = e
      totals[item] = e.total
      grand_total = grand_total + e.total
    end
  end

  table.sort(list, function(a, b)
    local ka, kb = M.sort_key(a.item), M.sort_key(b.item)
    if ka ~= kb then return ka < kb end
    return a.item < b.item
  end)

  return {
    items = list,
    totals = totals,
    grand_total = grand_total,
  }
end

return M
