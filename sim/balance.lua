-- Balance explorer (no game needed): luajit sim/balance.lua
-- Prints tables answering design questions. Edit params; commit findings to the relevant decision issue.
package.path = "./mod/?.lua;" .. package.path
local cm = require("scripts.model.colony_model")
local spoilage = require("scripts.model.spoilage")

print("== Q1 (#16/#17): how many foragers per colonist does a 16-pop Tier-1 colony need to grow?")
print("forage_out/interval  final_pop  min_food")
for out = 8, 28, 4 do
  local c = cm.new{pop = 4, capacity = 16, food_stock = 10, foragers_output = out}
  local h, minf = cm.run(c, 120), math.huge
  for _, s in ipairs(h) do minf = math.min(minf, s.food) end
  print(string.format("%19d  %9d  %8.1f", out, c.pop, minf))
end

print("\n== Q2 (design §3.1): raw food shelf life vs waste. 1 step = 1 min, shelf 5-10 min, colonists eat 10/min")
print("produce/min  shelf  waste%")
for _, produce in ipairs({10, 12, 15, 20}) do
  for _, shelf in ipairs({5, 10}) do
    print(string.format("%11d  %5d  %5.1f%%", produce, shelf, 100 * spoilage.waste_fraction(produce, 10, shelf, 600)))
  end
end

print("\n== Q3 (#16): pollution tolerance - final pop of fed 16-cap colony vs pollution (0..2)")
for p = 0, 2, 0.25 do
  local c = cm.new{pop = 12, capacity = 16, food_stock = 1000, foragers_output = 50, pollution = p}
  cm.run(c, 80); print(string.format("pollution %.2f -> pop %d  D=%.2f", p, c.pop, c.d))
end

local hauling = require("scripts.model.hauling")
print("\n== Q4 (#10/#11, design §3.1+§5): hauling delay vs spoilage. produce 12/min, 16 colonists eat 10/min, capacity 10/trip, 600 min")
print("shelf  delay  haulers  waste%  unmet%  avg_age_at_meal")
for _, shelf in ipairs({6, 10, 30}) do
  for _, delay in ipairs({1, 3, 6}) do
    for _, haulers in ipairs({2, 4, 8}) do
      local r = hauling.run{produce = 12, consume = 10, haulers = haulers, capacity = 10, delay = delay, shelf = shelf, steps = 600, stock_buffer_start = 20}
      print(string.format("%5d  %5d  %7d  %5.1f%%  %5.1f%%  %6.1f", shelf, delay, haulers, 100 * r.waste_frac, 100 * r.unmet_frac, r.avg_age))
    end
  end
end
print("\n== Q5: wait-for-full-load policy vs dispatch-immediately (shelf 10, delay 3, 4 haulers, capacity 20)")
for _, wait in ipairs({false, true}) do
  local r = hauling.run{produce = 12, consume = 10, haulers = 4, capacity = 20, delay = 3, shelf = 10, steps = 600, stock_buffer_start = 20, wait_for_full = wait}
  print(string.format("wait_for_full=%-5s waste %.1f%% unmet %.1f%% avg_age %.1f", tostring(wait), 100 * r.waste_frac, 100 * r.unmet_frac, r.avg_age))
end
