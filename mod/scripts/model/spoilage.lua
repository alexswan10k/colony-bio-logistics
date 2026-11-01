-- PURE model of Factorio spoilage semantics (percent in 0..1; merging stacks averages by count).
local M = {}

-- advance a stack {count, percent} by `ticks`, with optional rate multiplier (cold storage <1). Returns true if fully spoiled.
function M.advance(stack, spoil_ticks, ticks, rate)
  stack.percent = stack.percent + (ticks * (rate or 1)) / spoil_ticks
  return stack.percent >= 1
end

-- Factorio merges stacks by count-weighted average spoilage (a fresh item merged into an old stack ages it).
function M.merge(a, b)
  local n = a.count + b.count
  return {count = n, percent = (a.percent * a.count + b.percent * b.count) / n}
end

-- Steady-state fraction of production wasted if consumption lags: simple FIFO queue model.
-- produce(t) items per tick-step, consume rate per step, shelf = steps until spoil.
function M.waste_fraction(produce_per_step, consume_per_step, shelf_steps, steps)
  local queue, produced, wasted = {}, 0, 0   -- queue of {age,count} FIFO consumption
  for _ = 1, steps do
    queue[#queue + 1] = {age = 0, count = produce_per_step}; produced = produced + produce_per_step
    local need = consume_per_step
    while need > 0 and #queue > 0 do
      local q = queue[1]; local take = math.min(q.count, need)
      q.count = q.count - take; need = need - take
      if q.count <= 0 then table.remove(queue, 1) end
    end
    for i = #queue, 1, -1 do
      queue[i].age = queue[i].age + 1
      if queue[i].age >= shelf_steps then wasted = wasted + queue[i].count; table.remove(queue, i) end
    end
  end
  return wasted / math.max(produced, 1)
end

return M
