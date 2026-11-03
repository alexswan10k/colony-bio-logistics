-- PURE: what a hauler carries, and which destination it serves first.
-- One trip serves ONE destination, but it may carry several item types (e.g. ore + fuel for a furnace),
-- so a machine with two requests is filled in one visit instead of starving one of them.
local M = {}

-- Lower number = served first. An unmet critical need (food/heat) always comes first or colonists die
-- while the furnace gets stocked. Tools next: a hut without a tool stops working entirely, while output
-- only waits for space. Then the hut's finished goods (they block its slots), explicit requests, machine
-- output, carrying spoilage away to a compost bin (#78), and last of all topping up houses that are already fed.
-- Compost used to be last, but once haulers had to walk to every pickup there was always a top-up waiting, so
-- spoilage sat in the hall for good; it blocks storage slots, and a fed house loses nothing by waiting.
M.PRIORITY = {critical = 1, tools = 2, hut_output = 3, request = 4, collect = 5, compost = 6, buffer = 7}

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
  local out, total, left, added = {}, 0, {}, {}
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
  -- `added[i]` is what this trip has already loaded for demand i: the two passes below (fair share, then
  -- leftovers) must not count the same demand twice, or a small request is loaded twice over.
  local function add(i, max_n)
    local d = demands[i]
    if total >= cap then return end
    local remaining = math.min((d.count or 0) - (added[i] or 0), max_n or cap, cap - total)
    for _, item in ipairs(demand_items(d)) do
      if remaining < 1 then break end
      local n = math.min(remaining, avail(item))
      if n >= 1 then
        push(item, n, d.need)
        left[item] = avail(item) - n
        added[i] = (added[i] or 0) + n
        total, remaining = total + n, remaining - n
      end
    end
  end
  local share = math.ceil(cap / #demands)
  for i = 1, #demands do add(i, share) end
  for i = 1, #demands do add(i) end
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
