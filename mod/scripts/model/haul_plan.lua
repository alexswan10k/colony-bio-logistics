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
  if not offer then return 0 end
  if type(offer.deficit) == "number" then return offer.deficit end
  local n = 0
  for _, d in ipairs(offer.demands or {}) do n = n + (d.count or 0) end
  return n
end

-- Stable order: priority, then building priority, then largest deficit, then `key` (caller supplies a stable id).
function M.order(offers)
  table.sort(offers, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    local bpa = a.building_priority or 3
    local bpb = b.building_priority or 3
    if bpa ~= bpb then return bpa < bpb end
    local da, db = a.deficit or M.deficit(a), b.deficit or M.deficit(b)
    if da ~= db then return da > db end
    return (a.key or 0) < (b.key or 0)
  end)
  return offers
end

local function pos_of(p)
  if not p then return {x = 0, y = 0} end
  if p.position then return p.position end
  return p
end

local function dist2(a, b)
  local pa, pb = pos_of(a), pos_of(b)
  local dx, dy = pa.x - pb.x, pa.y - pb.y
  return dx * dx + dy * dy
end
M.dist2 = dist2

local function has_any_demanded(available, demands)
  for _, d in ipairs(demands) do
    for _, item in ipairs(demand_items(d)) do
      if (available[item] or 0) > 0 then return true end
    end
  end
  return false
end

-- Match requesters, active providers, storages and compost offers into an optimal haul task.
-- Requesters are served from active providers first (direct transfer), then storage.
-- Active providers push unmatched output to the nearest storage with space.
function M.match(requesters, providers, storages, compost_offers, cap, hauler_pos)
  cap = cap or M.DEFAULT_CAP
  requesters = requesters or {}
  providers = providers or {}
  storages = storages or {}
  compost_offers = compost_offers or {}

  local candidates = {}

  -- 1. Requesters: check active providers (direct delivery) first, then storage
  for _, r in ipairs(requesters) do
    local r_pos = r.pos or (r.entity and r.entity.position) or {x = 0, y = 0}
    local matched_direct = false

    -- A. Direct delivery from active providers
    local direct_providers = {}
    for _, p in ipairs(providers) do
      if has_any_demanded(p.available or {}, r.demands or {}) then
        direct_providers[#direct_providers + 1] = p
      end
    end
    if #direct_providers > 0 then
      table.sort(direct_providers, function(a, b)
        local pa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
        local pb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
        local da, db = dist2(pa, r_pos), dist2(pb, r_pos)
        if da ~= db then return da < db end
        return (a.key or 0) < (b.key or 0)
      end)
      for _, p in ipairs(direct_providers) do
        local load = M.load(r.demands, p.available or {}, cap)
        if #load > 0 then
          local p_pos = p.pos or (p.entity and p.entity.position) or {x = 0, y = 0}
          local d = dist2(hauler_pos or p_pos, p_pos) + dist2(p_pos, r_pos)
          candidates[#candidates + 1] = {
            kind = "direct",
            priority = math.min(r.priority, p.priority),
            building_priority = math.min(r.building_priority or 3, p.building_priority or 3),
            is_direct = true,
            source = p,
            target = r,
            load = load,
            demands = r.demands,
            deficit = M.deficit(r),
            key = r.key,
            dist = d,
            house = r.house,
            machine = r.machine or p.machine,
            crate = r.crate or p.crate,
            pool = r.pool,
            tavern = r.tavern,
            canteen = r.canteen,
            hut = r.hut or p.hut,
            bin = r.bin or p.bin,
            pan = p.pan,
            well = p.well,
          }
          matched_direct = true
          break
        end
      end
    end

    -- B. Pull from storage (fallback or when storage is closer/available)
    -- A requester is never its own source: a Watchtower's stock room is colony storage (#56), so without this a
    -- hauler would carry the tower's own rifles out of it and straight back into it.
    local avail_storages = {}
    for _, s in ipairs(storages) do
      if not (r.entity and s.entity == r.entity) and has_any_demanded(s.available or {}, r.demands or {}) then
        avail_storages[#avail_storages + 1] = s
      end
    end
    if #avail_storages > 0 then
      table.sort(avail_storages, function(a, b)
        local spa = a.storage_priority or 3
        local spb = b.storage_priority or 3
        if spa ~= spb then return spa < spb end
        local sa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
        local sb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
        local da, db = dist2(sa, r_pos), dist2(sb, r_pos)
        if da ~= db then return da < db end
        return (a.key or 0) < (b.key or 0)
      end)
      for _, s in ipairs(avail_storages) do
        local load = M.load(r.demands, s.available or {}, cap)
        if #load > 0 then
          local s_pos = s.pos or (s.entity and s.entity.position) or {x = 0, y = 0}
          local d = dist2(hauler_pos or s_pos, s_pos) + dist2(s_pos, r_pos)
          candidates[#candidates + 1] = {
            kind = "supply",
            priority = r.priority,
            building_priority = r.building_priority or 3,
            is_direct = false,
            source = s,
            target = r,
            load = load,
            demands = r.demands,
            deficit = M.deficit(r),
            key = r.key,
            dist = d,
            house = r.house,
            machine = r.machine,
            crate = r.crate,
            pool = r.pool,
            tavern = r.tavern,
            canteen = r.canteen,
            hut = r.hut,
          }
          break
        end
      end
    end
  end

  -- 2. Active providers: push finished output to nearest storage with space that accepts the items
  for _, p in ipairs(providers) do
    local p_pos = p.pos or (p.entity and p.entity.position) or {x = 0, y = 0}
    local p_items = {}
    for item, count in pairs(p.available or {}) do
      if count > 0 then p_items[#p_items + 1] = item end
    end
    if #p_items > 0 then
      local open_storages = {}
      for _, s in ipairs(storages) do
        if s.has_space ~= false then
          local accepts_any = false
          for _, item in ipairs(p_items) do
            if not s.accepts_item or s.accepts_item(item) then
              accepts_any = true
              break
            end
          end
          if accepts_any then open_storages[#open_storages + 1] = s end
        end
      end
      if #open_storages > 0 then
        table.sort(open_storages, function(a, b)
          local spa = a.storage_priority or 3
          local spb = b.storage_priority or 3
          if spa ~= spb then return spa < spb end
          local sa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
          local sb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
          local da, db = dist2(sa, p_pos), dist2(sb, p_pos)
          if da ~= db then return da < db end
          return (a.key or 0) < (b.key or 0)
        end)
        local best_s = open_storages[1]
        local s_pos = best_s.pos or (best_s.entity and best_s.entity.position) or {x = 0, y = 0}
        local demands = {}
        for item, count in pairs(p.available or {}) do
          if count > 0 and (not best_s.accepts_item or best_s.accepts_item(item)) then
            demands[#demands + 1] = {item = item, count = count}
          end
        end
        table.sort(demands, function(a, b) return a.item < b.item end)
        if #demands > 0 then
          local load = M.load(demands, p.available or {}, cap)
          if #load > 0 then
            local d = dist2(hauler_pos or p_pos, p_pos) + dist2(p_pos, s_pos)
            candidates[#candidates + 1] = {
              kind = "collect",
              priority = p.priority,
              building_priority = p.building_priority or 3,
              is_direct = false,
              source = p,
              target = best_s,
              load = load,
              demands = demands,
              deficit = M.deficit(p),
              key = p.key,
              dist = d,
              machine = p.machine,
              crate = p.crate,
              hut = p.hut,
              bin = p.bin,
              pan = p.pan,
              well = p.well,
            }
          end
        end
      end
    end
  end

  -- 3. Compost offers
  for _, c in ipairs(compost_offers) do
    local src_pos = c.pos or (c.source and (c.source.pos or (c.source.entity and c.source.entity.position))) or {x = 0, y = 0}
    local bin_pos = (c.bin and (c.bin.pos or (c.bin.entity and c.bin.entity.position))) or {x = 0, y = 0}
    local d = dist2(hauler_pos or src_pos, src_pos) + dist2(src_pos, bin_pos)
    local n = math.min(c.spoil or cap, cap)
    if n > 0 then
      candidates[#candidates + 1] = {
        kind = "compost",
        priority = c.priority,
        building_priority = c.building_priority or 3,
        is_direct = false,
        source = c.source or c.storage,
        target = c.bin,
        bin = c.bin,
        load = {{item = c.item or "colony-spoilage", count = n}},
        demands = {{item = c.item or "colony-spoilage", count = n}},
        deficit = c.spoil or cap,
        key = c.key,
        dist = d,
      }
    end
  end

  local backlog = 0
  for _, r in ipairs(requesters) do
    if r.priority < M.PRIORITY.buffer then backlog = backlog + 1 end
  end
  for _, p in ipairs(providers) do
    if p.priority < M.PRIORITY.buffer then backlog = backlog + 1 end
  end
  for _, c in ipairs(compost_offers) do
    if c.priority < M.PRIORITY.buffer then backlog = backlog + 1 end
  end

  if #candidates == 0 then return nil, backlog end

  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    local bpa = a.building_priority or 3
    local bpb = b.building_priority or 3
    if bpa ~= bpb then return bpa < bpb end
    if a.is_direct ~= b.is_direct then return a.is_direct end
    if a.deficit ~= b.deficit then return a.deficit > b.deficit end
    if a.dist ~= b.dist then return a.dist < b.dist end
    return (a.key or 0) < (b.key or 0)
  end)

  return candidates[1], backlog
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
