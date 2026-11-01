-- PURE model: food moving producer pile -> haulers (travel delay) -> consumer stock, with spoilage at every stage.
-- 1 step = 1 time unit. Batches = {age, count}. Answers: how much do hauler count/capacity/distance/shelf life waste or starve?
local M = {}

local function total(list) local n = 0 for _, b in ipairs(list) do n = n + b.count end return n end

-- take up to `n` items from list; oldest first (fifo) or newest first. Returns taken batches.
local function take(list, n, newest_first)
  local out = {}
  while n > 0 and #list > 0 do
    local i = newest_first and #list or 1
    local b = list[i]
    local t = math.min(b.count, n)
    out[#out + 1] = {age = b.age, count = t}
    b.count = b.count - t; n = n - t
    if b.count <= 0 then table.remove(list, i) end
  end
  return out
end

local function age(list, shelf)
  local wasted = 0
  for i = #list, 1, -1 do
    list[i].age = list[i].age + 1
    if list[i].age >= shelf then wasted = wasted + list[i].count; table.remove(list, i) end
  end
  return wasted
end

-- o: produce (items/step), consume (items/step), haulers, capacity (items/trip), delay (one-way steps),
--    shelf (steps), steps, pickup_newest (bool), stock_buffer_start (items), wait_for_full (bool: haulers wait for a full load)
function M.run(o)
  local pile, stock, transit = {}, {{age = 0, count = o.stock_buffer_start or 0}}, {}
  local idle, returning = o.haulers, {}   -- returning: list of steps-until-free
  local r = {produced = 0, delivered = 0, consumed = 0, unmet = 0, wasted = 0, trips = 0, avg_age_sum = 0, avg_age_n = 0}
  for _ = 1, o.steps do
    pile[#pile + 1] = {age = 0, count = o.produce}; r.produced = r.produced + o.produce
    -- dispatch idle haulers
    while idle > 0 do
      local avail = total(pile)
      if avail <= 0 or (o.wait_for_full and avail < o.capacity) then break end
      local load = take(pile, o.capacity, o.pickup_newest)
      transit[#transit + 1] = {eta = o.delay, load = load}
      returning[#returning + 1] = 2 * o.delay
      idle = idle - 1; r.trips = r.trips + 1
    end
    -- deliveries
    for i = #transit, 1, -1 do
      transit[i].eta = transit[i].eta - 1
      if transit[i].eta <= 0 then
        for _, b in ipairs(transit[i].load) do stock[#stock + 1] = b; r.delivered = r.delivered + b.count end
        table.remove(transit, i)
      end
    end
    for i = #returning, 1, -1 do
      returning[i] = returning[i] - 1
      if returning[i] <= 0 then idle = idle + 1; table.remove(returning, i) end
    end
    -- consumption (oldest first)
    local got = take(stock, o.consume)
    local n = 0
    for _, b in ipairs(got) do n = n + b.count; r.avg_age_sum = r.avg_age_sum + b.age * b.count; r.avg_age_n = r.avg_age_n + b.count end
    r.consumed = r.consumed + n; r.unmet = r.unmet + (o.consume - n)
    -- spoilage everywhere (items in transit age too)
    r.wasted = r.wasted + age(pile, o.shelf) + age(stock, o.shelf)
    for _, t in ipairs(transit) do r.wasted = r.wasted + age(t.load, o.shelf) end
  end
  r.waste_frac = r.wasted / math.max(r.produced, 1)
  r.unmet_frac = r.unmet / math.max(o.consume * o.steps, 1)
  r.avg_age = r.avg_age_sum / math.max(r.avg_age_n, 1)
  return r
end

return M
