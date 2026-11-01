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
