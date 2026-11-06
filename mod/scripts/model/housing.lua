---@diagnostic enable: undefined-field, missing-fields
-- PURE: housing tiers, per-house needs, consumption and hauling demand.
-- A need is satisfied by the FIRST workable option: {power=true} (if powered) or {item=, per=} (per occupant per interval).
-- So electricity substitutes for fuel/heat. Later needs (water, luxury goods) are just more entries here.
local M = {}

-- Options are alternatives for the same need and are tried in order, so the preserved tier sits LAST: a house
-- eats what spoils first and keeps the salted food for when the fresh runs out (#81).
M.FOOD = {{item = "colony-forage", per = 1}, {item = "colony-fish", per = 1}, {item = "colony-meat", per = 1},
  {item = "raw-fish", per = 1}, {item = "colony-produce", per = 1},
  {item = "colony-preserved-fish", per = 1}, {item = "colony-preserved-meat", per = 1},
  {item = "colony-bread", per = 1}}

M.WATER = {{item = "colony-water", per = 0.5}}

M.TIERS = {
  tent = {
    capacity = 1, buffer_intervals = 6,
    needs = {
      {id = "food", critical = true, options = M.FOOD},
      {id = "heat", options = {{item = "wood", per = 0.5}}},
    },
  },
  cabin = {
    capacity = 6, buffer_intervals = 6,
    needs = {
      {id = "food", critical = true, options = M.FOOD},
      {id = "heat", options = {{power = true}, {item = "wood", per = 0.5}}},
    },
  },
  homestead = {
    capacity = 8, buffer_intervals = 6,
    needs = {
      {id = "food", critical = true, options = M.FOOD},
      {id = "water", critical = true, options = M.WATER},
      {id = "heat", options = {{power = true}, {item = "coal", per = 0.5}, {item = "wood", per = 0.5}}},
    },
  },
  apartment = {
    capacity = 16, buffer_intervals = 6,
    needs = {
      {id = "food", critical = true, options = M.FOOD},
      {id = "water", critical = true, options = M.WATER},
      {id = "electricity", critical = true, options = {{power = true}}},
      {id = "comfort", options = {{item = "colony-furniture", per = 0.1}}},
    },
  },
}

function M.items_of(tier)
  local set = {}
  for _, need in ipairs(tier.needs) do
    for _, opt in ipairs(need.options) do if opt.item then set[opt.item] = true end end
  end
  return set
end

function M.needs_power(tier)
  for _, need in ipairs(tier.needs) do
    for _, opt in ipairs(need.options) do if opt.power then return true end end
  end
  return false
end

-- stock {item->count} is MUTATED (consumption). acc {item/need->fraction debt} is MUTATED.
-- Returns consumed {item->n}, sat {need_id->bool}, score (0..1 fraction of needs met), critical_unmet (bool).
function M.step(tier, occupants, stock, powered, acc)
  local consumed, sat, met, total, crit_unmet = {}, {}, 0, 0, false
  for _, need in ipairs(tier.needs) do
    total = total + 1
    local ok = occupants == 0
    if not ok then
      local first_item, per, power_opt = nil, nil, false
      for _, opt in ipairs(need.options) do
        if opt.power then
          power_opt = true
        elseif opt.item then
          first_item = first_item or opt.item
          per = per or opt.per
        end
      end

      if power_opt and powered then
        ok = true
      elseif per then
        local cur_acc = acc[need.id] or (first_item and acc[first_item]) or 0
        local owed = cur_acc + occupants * per
        local take = math.floor(owed)
        local remaining = take
        for _, opt in ipairs(need.options) do
          if opt.item and remaining > 0 then
            local have = stock[opt.item] or 0
            local use = math.min(remaining, have)
            if use > 0 then
              stock[opt.item] = have - use
              consumed[opt.item] = (consumed[opt.item] or 0) + use
              remaining = remaining - use
            end
          end
        end
        local fraction = owed - take
        acc[need.id] = fraction
        if first_item then acc[first_item] = fraction end
        if remaining == 0 then ok = true end
      end
    end
    sat[need.id] = ok
    if ok then met = met + 1 elseif need.critical then crit_unmet = true end
  end
  return consumed, sat, total > 0 and met / total or 1, crit_unmet
end

-- Which needs the house could meet right now from what is on its shelves: {need_id -> bool}. Unlike step()
-- this neither consumes nor waits for an evaluation, so a status line clears the moment a hauler delivers.
function M.available(tier, stock, powered)
  local out = {}
  for _, need in ipairs(tier.needs) do
    local ok = false
    for _, opt in ipairs(need.options) do
      if (opt.power and powered) or (opt.item and (stock[opt.item] or 0) > 0) then ok = true; break end
    end
    out[need.id] = ok
  end
  return out
end

M.REORDER_INTERVALS = 3

-- What to haul to this house: {{need=, count=, items={...}}} - `items` are interchangeable options
-- (food = forage OR fish), so the hauler brings whatever the hall actually has.
-- `occupants` (default: full capacity) sizes the buffer, so an empty house does not hoard supplies
-- that machines and other houses are waiting for.
-- Uses high/low watermark hysteresis: requests are only made when stock drops to or below the reorder
-- threshold (default: 3 intervals / 50% buffer), but fills back up to the full buffer (6 intervals).
-- If `force_reorder` is true (e.g. need is unmet or critical), hysteresis is bypassed.
function M.demand(tier, stock, inflight, powered, occupants, force_reorder)
  local out = {}
  local n = occupants or tier.capacity
  for _, need in ipairs(tier.needs) do
    local skip, first, items, have = false, nil, {}, 0
    for _, opt in ipairs(need.options) do
      if opt.power then
        if powered then skip = true end
      else
        first = first or opt
        items[#items + 1] = opt.item
        have = have + (stock[opt.item] or 0) + (inflight[opt.item] or 0)
      end
    end
    if not skip and first and n > 0 then
      local target = math.ceil(n * first.per * tier.buffer_intervals)
      local threshold = math.max(0, math.min(target - 1, math.ceil(n * first.per * (tier.reorder_intervals or M.REORDER_INTERVALS))))
      local want = target - have
      if want >= 1 and (force_reorder or have <= threshold) then
        out[#out + 1] = {need = need.id, count = want, items = items}
      end
    end
  end
  return out
end

-- Distribute `pop` colonists across houses (array of capacities) in order. Returns array of occupant counts.
function M.distribute(pop, capacities)
  local out = {}
  for i, cap in ipairs(capacities) do
    local n = math.min(cap, pop); out[i] = n; pop = pop - n
  end
  return out, pop    -- homeless remainder
end

-- Same split as distribute(), but returns who lives where: `ids` (sorted colonist unit numbers) in, one
-- list per house out. Houses fill in order, so the house panel and the occupancy counts always agree.
function M.assign(ids, capacities)
  local out, next_i = {}, 1
  for i, cap in ipairs(capacities) do
    local list = {}
    for _ = 1, cap do
      if next_i > #ids then break end
      list[#list + 1] = ids[next_i]; next_i = next_i + 1
    end
    out[i] = list
  end
  return out
end

return M
