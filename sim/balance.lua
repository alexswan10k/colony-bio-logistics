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

--------------------------------------------------------------------------------
-- #41: the M1 exit-gate questions. Everything below reads the *game's own* constants (model/yields.lua and the
-- job models), so these tables are evidence rather than a second opinion.
--------------------------------------------------------------------------------
local yields = require("scripts.model.yields")
local farm = require("scripts.model.farm")
local labour = require("scripts.model.labour")

local INTERVAL = 600            -- colony interval in ticks (colony.INTERVAL); food is eaten per interval
local TICKS_PER_MIN = 60 * 60
local EATEN_PER_MIN = yields.FOOD_PER_INTERVAL * TICKS_PER_MIN / INTERVAL    -- 6/min per colonist
-- A trip is the work animation plus walking there, working, and walking the load back to the hut. The walk is
-- the fuzzy number, so the table shows it rather than hiding it: 12 s is a hut whose patches are close.
local TRIP_EXTRA = 720

local function per_min(items, trip_ticks)
  return items * TICKS_PER_MIN / trip_ticks
end

print(("\n== Q6 (#41): what one worker feeds. A colonist eats %.1f food/min (%.0f per interval, interval %d)."):format(
  EATEN_PER_MIN, yields.FOOD_PER_INTERVAL, INTERVAL))
print(("   trip = %d work + %d walk = %d ticks (%.1f s)"):format(
  yields.WORK_TICKS, TRIP_EXTRA, yields.WORK_TICKS + TRIP_EXTRA, (yields.WORK_TICKS + TRIP_EXTRA) / 60))
print("role      items/trip  food/min  colonists_fed  note")
local trip = yields.WORK_TICKS + TRIP_EXTRA
local rows = {
  {"forage", yields.FORAGE.count, per_min(yields.FORAGE.count, trip), "patch regrows in place"},
  {"chop", yields.CHOP.count, per_min(yields.CHOP.count, trip), "wood, not food"},
  {"mine", yields.MINE_PER_TRIP, per_min(yields.MINE_PER_TRIP, trip), "ore, not food"},
  {"fish", yields.FISH.count, per_min(yields.FISH.count, trip), "needs a shore"},
  {"hunt", yields.HUNT.count, per_min(yields.HUNT.count, trip), "needs game in range"},
}
for _, r in ipairs(rows) do
  print(("%-6s  %10d  %8.2f  %13.2f  %s"):format(r[1], r[2], r[3], r[3] / EATEN_PER_MIN, r[4]))
end
-- Farming is gated by the plot cycle, not by labour: one plot yields once per GROW_TICKS once planted.
local cycle = farm.GROW_TICKS
local per_plot = per_min(farm.YIELD_BASE, cycle)
local labour_per_cycle = 2 * trip                      -- plant trip + harvest trip
print(("farm    %10d  %8.2f  %13.2f  per plot at fertility 1.0 (one harvest per %d s)")
  :format(farm.YIELD_BASE, per_plot, per_plot / EATEN_PER_MIN, cycle / 60))
print(("        one farmer keeps ~%.1f plots busy (%d s of labour per %d s of growth) -> feeds ~%.1f colonists")
  :format(cycle / labour_per_cycle, labour_per_cycle / 60, cycle / 60, per_plot * cycle / labour_per_cycle / EATEN_PER_MIN))

print("\n== Q7 (#41): salt is the throttle on the preserved tier. A pan is worker-free.")
local salts_per_hour = TICKS_PER_MIN * 60 / yields.SALT_TICKS
print(("one pan: %.0f salt/h, and %d salt cures %d preserved item(s) -> %.0f preserved/h")
  :format(salts_per_hour, yields.CURE.salt, yields.CURE.out, salts_per_hour * yields.CURE.out / yields.CURE.salt))
print(("that covers %.0f%% of one colonist's diet (%.0f food/h), so preserved food is a stockpile, not a staple")
  :format(100 * (salts_per_hour / (EATEN_PER_MIN * 60)), EATEN_PER_MIN * 60))
print("smokehouse labour is never the limit: salt arrives every 30 s, a cure takes ~20 s of work.")

print("\n== Q8 (#41): tools. One tool per " .. labour.TOOL_USES .. " trips; a 3-worker hut replaces them at:")
print("hut        trips/min  tools/h  wood/h  iron/h  copper/h")
local tools = {
  {"forager", "colony-forage", 2, 3, 0}, {"woodcutter", "chop", 2, 3, 0}, {"miner", "mine", 2, 3, 0},
  {"farmer", "farm", 2, 3, 0}, {"hunter", "hunt", 4, 6, 2}, {"fisher", "fish", 3, 2, 0},
}
for _, t in ipairs(tools) do
  local trips_min = 3 * per_min(1, trip)               -- 3 workers, one trip each per trip time
  local tools_h = trips_min * 60 / labour.TOOL_USES
  print(("%-10s  %9.2f  %7.2f  %6.1f  %6.1f  %8.1f")
    :format(t[1], trips_min, tools_h, tools_h * t[3], tools_h * t[4], tools_h * t[5]))
end

print("\n== Q9 (#41): bootstrap bill. What a new player must gather, in order, to run one of each hut.")
local bill = {
  {"colony-town-hall", {wood = 50, ["iron-plate"] = 50}},
  {"colony-housing-tent", {wood = 20, ["iron-plate"] = 5}},
  {"colony-forager-hut", {wood = 20, ["iron-plate"] = 5}},
  {"colony-woodcutter-hut", {wood = 20, ["iron-plate"] = 5}},
  {"colony-miner-hut", {wood = 20, ["iron-plate"] = 10}},
  {"tools x3", {wood = 3 * 2 + 3 * 2, ["iron-plate"] = 3 * 3 + 3 * 3}},
}
local total = {wood = 0, ["iron-plate"] = 0}
for _, b in ipairs(bill) do
  for item, n in pairs(b[2]) do total[item] = total[item] + n end
end
print("wood " .. total.wood .. ", iron plates " .. total["iron-plate"])
print(("iron: %d plates = %d ore smelted at 3.2 s/plate in one stone furnace = %.1f player-minutes of smelting")
  :format(total["iron-plate"], total["iron-plate"], total["iron-plate"] * 3.2 / 60))
print(("wood: %d = %d hand-chopped trees (4 wood each) = %.1f player-minutes")
  :format(total.wood, math.ceil(total.wood / 4), total.wood / 4 * 1.0))

print("\n== Q10 (#41): does the preserved tier actually change hauling? (same run as Q4, shelf 45 vs 15)")
for _, shelf in ipairs({15, 45}) do
  local r = hauling.run{produce = 12, consume = 10, haulers = 4, capacity = 20, delay = 3, shelf = shelf,
    steps = 600, stock_buffer_start = 20}
  print(("shelf %2d min  waste %5.1f%%  unmet %5.1f%%  avg_age %5.1f"):format(
    shelf, 100 * r.waste_frac, 100 * r.unmet_frac, r.avg_age))
end
