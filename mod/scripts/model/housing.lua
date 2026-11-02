-- PURE: housing tiers, per-house needs, consumption and hauling demand.
-- A need is satisfied by the FIRST workable option: {power=true} (if powered) or {item=, per=} (per occupant per interval).
-- So electricity substitutes for fuel/heat. Later needs (water, luxury goods) are just more entries here.
local M = {}

M.FOOD = {{item = "colony-forage", per = 1}, {item = "colony-fish", per = 1}, {item = "colony-meat", per = 1},
  {item = "raw-fish", per = 1}, {item = "colony-produce", per = 1}}

M.TIERS = {
  tent = {
    capacity = 4, buffer_intervals = 6,
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

-- stock {item->count} is MUTATED (consumption). acc {item->fraction debt} is MUTATED.
-- Returns consumed {item->n}, sat {need_id->bool}, score (0..1 fraction of needs met), critical_unmet (bool).
function M.step(tier, occupants, stock, powered, acc)
  local consumed, sat, met, total, crit_unmet = {}, {}, 0, 0, false
  for _, need in ipairs(tier.needs) do
    total = total + 1
    local ok = occupants == 0
    if not ok then
      for _, opt in ipairs(need.options) do
        if opt.power then
          if powered then ok = true; break end
        else
          local owed = (acc[opt.item] or 0) + occupants * opt.per
          local take = math.floor(owed)
          local have = stock[opt.item] or 0
          local use = math.min(take, have)
          stock[opt.item] = have - use
          consumed[opt.item] = (consumed[opt.item] or 0) + use
          acc[opt.item] = math.min(owed - use, occupants * opt.per * 2)
          if use >= take and (take > 0 or have > 0 or owed < 1) then ok = true; break end
        end
      end
    end
    sat[need.id] = ok
    if ok then met = met + 1 elseif need.critical then crit_unmet = true end
  end
  return consumed, sat, total > 0 and met / total or 1, crit_unmet
end

-- What to haul to this house: {{need=, count=, items={...}}} - `items` are interchangeable options
-- (food = forage OR fish), so the hauler brings whatever the hall actually has.
-- `occupants` (default: full capacity) sizes the buffer, so an empty house does not hoard supplies
-- that machines and other houses are waiting for.
function M.demand(tier, stock, inflight, powered, occupants)
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
      local want = math.ceil(n * first.per * tier.buffer_intervals) - have
      if want >= 1 then out[#out + 1] = {need = need.id, count = want, items = items} end
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
