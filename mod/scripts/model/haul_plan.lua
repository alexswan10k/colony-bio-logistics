-- PURE: what a hauler carries, and which destination it serves first.
-- One trip serves ONE destination, but it may carry several item types (e.g. ore + fuel for a furnace),
-- so a machine with two requests is filled in one visit instead of starving one of them.
local M = {}

-- Lower number = served first. Explicit player requests beat passive house buffering, but an unmet
-- critical need (food/heat) always comes first or colonists die while the furnace gets stocked.
M.PRIORITY = {critical = 1, tools = 2, request = 3, collect = 4, buffer = 5}

M.DEFAULT_CAP = 20

-- A demand is {item=, count=} or {items={...}, count=} (interchangeable options, e.g. forage or fish).
local function demand_items(d) return d.items or {d.item} end
M.demand_items = demand_items

-- demands: array of {item=, count=} or {items={...}, count=}. available: {item -> count on hand}.
-- Returns a load: array of {item=, count=, need=} with at most `cap` items total.
-- The cap is shared across the demanded items first (so a furnace gets ore AND fuel in one visit),
-- then whatever is left fills the biggest requests.
function M.load(demands, available, cap)
  cap = cap or M.DEFAULT_CAP
  local out, total, left = {}, 0, {}
  if #demands == 0 then return out end
  local function avail(item)
    if left[item] == nil then left[item] = available[item] or 0 end
    return left[item]
  end
  local function push(item, n, need)
    for _, s in ipairs(out) do
      if s.item == item then s.count = s.count + n; return end
    end
    out[#out + 1] = {item = item, count = n, need = need}
  end
  local function add(d, max_n)
    if total >= cap then return end
    local remaining = math.min(d.count or 0, max_n or cap, cap - total)
    for _, item in ipairs(demand_items(d)) do
      if remaining < 1 then break end
      local n = math.min(remaining, avail(item))
      if n >= 1 then
        push(item, n, d.need)
        left[item] = avail(item) - n
        total, remaining = total + n, remaining - n
      end
    end
  end
  local share = math.ceil(cap / #demands)
  for _, d in ipairs(demands) do add(d, share) end
  for _, d in ipairs(demands) do add(d) end
  return out
end

function M.total(load)
  local n = 0
  for _, s in ipairs(load) do n = n + s.count end
  return n
end

-- Total items an offer wants: used to rank destinations of the same priority (biggest deficit first).
function M.deficit(offer)
  local n = 0
  for _, d in ipairs(offer.demands) do n = n + (d.count or 0) end
  return n
end

-- Stable order: priority, then largest deficit, then `key` (caller supplies a stable id).
function M.order(offers)
  table.sort(offers, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    local da, db = a.deficit or M.deficit(a), b.deficit or M.deficit(b)
    if da ~= db then return da > db end
    return (a.key or 0) < (b.key or 0)
  end)
  return offers
end

-- offers: ordered array of {priority=, demands=, available=, key=}. `hall` = {item -> count} fallback.
-- Returns the first offer that can actually be loaded, plus its load.
function M.choose(offers, hall, cap)
  for _, o in ipairs(offers) do
    local load = M.load(o.demands, o.available or hall or {}, cap)
    if #load > 0 then return o, load end
  end
  return nil, nil
end

return M
