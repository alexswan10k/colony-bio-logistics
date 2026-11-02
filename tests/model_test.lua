local desirability = require("scripts.model.desirability")
local spoilage = require("scripts.model.spoilage")
local jobs = require("scripts.model.jobs")
local cm = require("scripts.model.colony_model")
local scenic = require("scripts.model.scenic")
local tags = require("scripts.model.tags")
local compost = require("scripts.model.compost")

describe("desirability", function()
  local good = {food_ratio = 1, free_housing_ratio = 0.5, scenic = 0.5, leisure = 0.5, pollution = 0, deaths = {}}
  it("healthy colony is above migration threshold", function()
    truthy(desirability.compute(good) > desirability.defaults.migrate_in)
  end)
  it("pollution can flip migration off", function()
    local bad = {food_ratio = 1, free_housing_ratio = 0.5, scenic = 0.5, leisure = 0.5, pollution = 1, deaths = {}}
    truthy(desirability.compute(bad) < desirability.defaults.migrate_in)
  end)
  it("death penalty decays with age", function()
    local fresh = desirability.compute({food_ratio = 1, free_housing_ratio = 1, deaths = {0}})
    local old = desirability.compute({food_ratio = 1, free_housing_ratio = 1, deaths = {30}})
    truthy(old > fresh)
  end)
  it("inputs are clamped", function()
    local a = desirability.compute({food_ratio = 50, free_housing_ratio = 50})
    local b = desirability.compute({food_ratio = 1, free_housing_ratio = 1})
    near(a, b)
  end)
end)

describe("entity tags (#36)", function()
  local function machine(collect, requests)
    return {collect = collect, requests = requests or {}}
  end
  it("round-trips a machine's opt-in, collect flag and supply rows", function()
    local d = tags.dictionary(tags.machine(machine(false, {{item = "iron-plate", count = 40}, nil,
      {item = "copper-plate", count = 7}})))
    local back = tags.decode(d)
    eq(back.machine.collect, false)
    eq(back.machine.requests[1].item, "iron-plate"); eq(back.machine.requests[1].count, 40)
    eq(back.machine.requests[2], nil, "the empty row stays empty")
    eq(back.machine.requests[3].item, "copper-plate"); eq(back.machine.requests[3].count, 7)
    eq(back.crate, nil)
  end)
  it("keeps sparse rows dense on the wire (Tags stringifies sparse keys)", function()
    local wire = tags.machine(machine(true, {nil, nil, {item = "coal", count = 5}}))
    for i, row in ipairs(wire.requests) do
      eq(type(i), "number")
      eq(row.item, "coal"); eq(row.row, 3)
    end
    eq(#wire.requests, 1)
  end)
  it("round-trips crate filters by row", function()
    local back = tags.decode(tags.dictionary(tags.crate(
      {filters = {{item = "stone", count = 50}, {item = "wood", count = 12}}})))
    eq(back.crate.filters[1].item, "stone")
    eq(back.crate.filters[2].count, 12)
    eq(back.machine, nil)
  end)
  it("an empty filter list still travels, so a copy clears the destination", function()
    local back = tags.decode(tags.dictionary(tags.crate({filters = {}})))
    truthy(back.crate ~= nil)
    eq(next(back.crate.filters), nil)
  end)
  it("says nothing for a dictionary that is not ours", function()
    eq(tags.decode(nil), nil); eq(tags.decode("nope"), nil)
    eq(tags.decode({}), nil); eq(tags.decode({other = {machine = true}}), nil)
    eq(tags.decode({[tags.TAG] = {something = 1}}), nil)
  end)
  it("validates and clamps untrusted rows", function()
    local back = tags.decode({[tags.TAG] = {machine = true, requests = {
      {row = 1, item = "iron-plate", count = 99999},
      {row = 9, item = "wood", count = 5},          -- beyond the panel's rows
      {row = 0, item = "wood", count = 5},
      {row = 2, item = 42, count = 5},              -- not an item name
      {row = 3, item = "", count = 5},
      "junk",
    }}})
    eq(back.machine.requests[1].count, 400)          -- crates.MAX_COUNT
    eq(back.machine.requests[2], nil); eq(back.machine.requests[3], nil)
    eq(back.machine.requests[9], nil)
    eq(back.machine.collect, true, "absent collect defaults to true")
  end)
  it("decode is stable when the same row repeats", function()
    local back = tags.decode({[tags.TAG] = {crate = true, filters = {
      {row = 1, item = "stone", count = 5}, {row = 1, item = "wood", count = 9}}}})
    eq(back.crate.filters[1].item, "stone", "first mention wins")
    eq(#back.crate.filters, 1)
  end)
end)

describe("scenic + pollution inputs (#29)", function()
  it("trees and water raise scenic, bare ground does not", function()
    local bare = scenic.score{tree_cover = 0, water_cover = 0, built_cover = 0}
    local forest = scenic.score{tree_cover = scenic.TREE_FULL}
    local lake = scenic.score{water_cover = scenic.WATER_FULL}
    eq(bare, 0)
    near(forest, scenic.WEIGHTS.tree)
    near(lake, scenic.WEIGHTS.water)
  end)
  it("a forest with a lake beats either alone but stays within 0..1", function()
    local both = scenic.score{tree_cover = 10, water_cover = 10}
    eq(both, 1)
    truthy(scenic.score{tree_cover = scenic.TREE_FULL, water_cover = scenic.WATER_FULL} > scenic.WEIGHTS.tree)
  end)
  it("paving subtracts, and never below zero", function()
    local paved = scenic.score{tree_cover = scenic.TREE_FULL, built_cover = scenic.BUILT_FULL}
    near(paved, scenic.WEIGHTS.tree - scenic.WEIGHTS.built)
    eq(scenic.score{built_cover = 100}, 0)
  end)
  it("classifies vanilla tiles", function()
    truthy(scenic.is_built("refined-concrete")); truthy(scenic.is_built("stone-path"))
    truthy(scenic.is_built("hazard-concrete-left")); truthy(scenic.is_water("deepwater-green"))
    truthy(not scenic.is_built("grass-1")); truthy(not scenic.is_built("water"))
    truthy(not scenic.is_water("grass-1"))
  end)
  it("pollution normalises against the 'terrible' mark", function()
    eq(scenic.pollution_ratio(0), 0)
    eq(scenic.pollution_ratio(scenic.POLLUTION_BAD), 1)
    eq(scenic.pollution_ratio(scenic.POLLUTION_BAD * 5), 1)
    truthy(scenic.pollution_ratio(scenic.POLLUTION_BAD / 2) > 0.4)
  end)
end)

describe("leaving (#29)", function()
  local p = desirability.defaults
  it("nobody leaves at or above the leave line", function()
    eq(cm.leave_count(50, p.leave_below), 0)
    eq(cm.leave_count(50, 0.5), 0)
    eq(cm.leave_count(0, -1), 0)
  end)
  it("just below the line a trickle starts: at least one colonist", function()
    eq(cm.leave_count(50, p.leave_below - 0.001), 1)
    eq(cm.leave_count(1, -1), 1)
  end)
  it("the deeper the collapse the more leave, capped at leave_rate of the town", function()
    local shallow = cm.leave_count(100, p.leave_below - 0.05)
    local deep = cm.leave_count(100, p.leave_below - p.leave_span)
    truthy(deep > shallow, shallow .. " -> " .. deep)
    eq(deep, math.ceil(100 * p.leave_rate))
    eq(cm.leave_count(3, -5), 1, "a tiny town still loses someone")
  end)
end)

describe("spoilage", function()
  it("merging fresh into old stack averages by count (Factorio semantics)", function()
    local m = spoilage.merge({count = 10, percent = 0.8}, {count = 10, percent = 0})
    near(m.percent, 0.4); eq(m.count, 20)
  end)
  it("cold storage slows spoilage", function()
    local a, b = {count = 1, percent = 0}, {count = 1, percent = 0}
    spoilage.advance(a, 1000, 500, 1); spoilage.advance(b, 1000, 500, 0.1)
    near(a.percent, 0.5); near(b.percent, 0.05)
  end)
  it("no waste when consumption >= production", function()
    near(spoilage.waste_fraction(5, 6, 10, 500), 0)
  end)
  it("surplus production beyond shelf life is wasted", function()
    truthy(spoilage.waste_fraction(10, 5, 10, 500) > 0.4)
  end)
end)

describe("jobs priority", function()
  it("chooses highest-priority job with open tasks", function()
    eq(jobs.pick({doctor = 1, haul = 2, harvest = 3}, {doctor = 0, haul = 5, harvest = 9}), "haul")
  end)
  it("disabled (nil/0) jobs are never chosen", function()
    eq(jobs.pick({doctor = 0, haul = nil}, {doctor = 3, haul = 3}), nil)
  end)
  it("ties broken by canonical job order", function()
    eq(jobs.pick({haul = 1, construct = 1}, {haul = 1, construct = 1}), "construct")
  end)
  it("falls back to the default matrix when none is stored", function()
    eq(jobs.rank(nil, "haul"), 1); eq(jobs.rank(nil, "mine"), 2)
    eq(jobs.enabled(nil, "haul"), true)
  end)
  it("stores ranks 0..MAX_RANK and clamps the rest", function()
    local p = jobs.defaults()
    jobs.set(p, "mine", 0); eq(jobs.rank(p, "mine"), 0); eq(jobs.enabled(p, "mine"), false)
    jobs.set(p, "mine", 99); eq(jobs.rank(p, "mine"), jobs.MAX_RANK)
    jobs.set(p, "mine", -5); eq(jobs.rank(p, "mine"), 0)
  end)
  it("shifts a job up and down, letting ranks collide into groups", function()
    local p = jobs.defaults()
    jobs.shift(p, "forage", -1); eq(jobs.rank(p, "forage"), 1); eq(jobs.rank(p, "haul"), 1)
    jobs.shift(p, "forage", 1); eq(jobs.rank(p, "forage"), 2)
    jobs.shift(p, "haul", -1); eq(jobs.rank(p, "haul"), 0)   -- 0 switches the role off
    jobs.shift(p, "haul", 1); eq(jobs.rank(p, "haul"), 1)
  end)
  it("best_rank ignores disabled jobs and jobs with no free slot", function()
    local p = jobs.defaults()
    eq(jobs.best_rank(p, jobs.JOBS, {forage = 0, chop = 0, mine = 1}), 2)
    jobs.set(p, "mine", 0)
    eq(jobs.best_rank(p, jobs.JOBS, {forage = 0, chop = 0, mine = 1}), nil)
  end)
end)

describe("colony model (theories)", function()
  it("well-fed colony grows to capacity", function()
    local c = cm.new{pop = 4, capacity = 16, food_stock = 100, foragers_output = 30}
    cm.run(c, 60); eq(c.pop, 16)
  end)
  it("starvation collapses population and migration stops", function()
    local c = cm.new{pop = 12, capacity = 16, food_stock = 0, foragers_output = 0}
    cm.run(c, 40); truthy(c.pop <= 2, "pop=" .. c.pop)
  end)
  it("heavy pollution makes colonists leave even when fed", function()
    local c = cm.new{pop = 12, capacity = 16, food_stock = 1000, foragers_output = 50, pollution = 2, scenic = 0}
    cm.run(c, 40); truthy(c.pop < 12, "pop=" .. c.pop)
  end)
  it("off-world: no migration, needs critical mass + nursery to breed", function()
    local a = cm.new{pop = 5, capacity = 30, food_stock = 1000, foragers_output = 50, offworld = true, nurseries = 1}
    cm.run(a, 30); eq(a.pop, 5, "below critical mass stays flat")
    local b = cm.new{pop = 12, capacity = 30, food_stock = 1000, foragers_output = 50, offworld = true, nurseries = 1}
    cm.run(b, 30); truthy(b.pop > 12)
    local c = cm.new{pop = 12, capacity = 30, food_stock = 1000, foragers_output = 50, offworld = true, nurseries = 0}
    cm.run(c, 30); eq(c.pop, 12, "no nursery, no births")
  end)
end)

describe("hauling model", function()
  local hauling = require("scripts.model.hauling")
  local base = {produce = 10, consume = 8, haulers = 4, capacity = 10, delay = 2, shelf = 30, steps = 600, stock_buffer_start = 16}
  local function with(o) local t = {} for k, v in pairs(base) do t[k] = v end for k, v in pairs(o) do t[k] = v end return t end
  it("adequate haulers deliver with no starvation", function()
    local r = hauling.run(base); truthy(r.unmet_frac < 0.02, "unmet " .. r.unmet_frac)
  end)
  it("too few haulers starve the colony", function()
    local r = hauling.run(with{haulers = 1, delay = 8}); truthy(r.unmet_frac > 0.3, "unmet " .. r.unmet_frac)
  end)
  it("short shelf life + long distance wastes food in transit", function()
    local near_ = hauling.run(with{shelf = 6, delay = 1}); local far = hauling.run(with{shelf = 6, delay = 5, haulers = 10})
    truthy(far.waste_frac > near_.waste_frac, far.waste_frac .. " vs " .. near_.waste_frac)
  end)
  it("conservation: produced = consumed + wasted + remaining (<=)", function()
    local r = hauling.run(base); truthy(r.consumed + r.wasted <= r.produced + base.stock_buffer_start + 1e-9)
  end)
end)

describe("work_plan", function()
  local wp = require("scripts.model.work_plan")
  local function s(o)
    local t = {food_ratio = 2, counts = {}, slots = {forage = 3, chop = 3, mine = 3},
      capacity = {forage = 3, chop = 3, mine = 3}, pop = 3, haul = false}
    for k, v in pairs(o or {}) do t[k] = v end
    return t
  end
  it("prioritises foraging when hungry", function()
    eq(wp.choose(s{food_ratio = 0.1, slots = {forage = 3}, capacity = {forage = 3}}), "forage")
  end)
  it("keeps a share of the colony hauling while there is haul work", function()
    eq(wp.choose(s{pop = 6, haul = true}), "haul")
  end)
  it("staffs every tooled hut before over-staffing one", function()
    eq(wp.choose(s{pop = 3, counts = {forage = 1}}), "chop")
    eq(wp.choose(s{pop = 3, counts = {forage = 1, chop = 1}}), "mine")
  end)
  it("never assigns a job with no free tooled slot", function()
    eq(wp.choose(s{pop = 2, slots = {forage = 0, chop = 1, mine = 0}, capacity = {forage = 0, chop = 1, mine = 0}}), "chop")
  end)
  it("idles when there is no tooled slot and nothing to haul", function()
    eq(wp.choose(s{pop = 2, slots = {}, capacity = {}}), nil)
  end)
  it("honours the priority matrix: hauling can be switched off", function()
    local job = wp.choose(s{pop = 6, haul = true, priority = {haul = 0, forage = 2, chop = 2, mine = 2}})
    truthy(job == "forage" or job == "chop" or job == "mine", tostring(job))
  end)
  it("honours the priority matrix: a rank-1 role beats the food ratio", function()
    eq(wp.choose(s{food_ratio = 0.1, priority = {haul = 1, forage = 3, chop = 1, mine = 1}}), "chop")
  end)
  it("honours the priority matrix: a disabled role is never assigned", function()
    eq(wp.choose(s{slots = {forage = 3}, capacity = {forage = 3},
      priority = {haul = 0, forage = 0, chop = 0, mine = 0}}), nil)
  end)
  it("keeps hauling below its share before starting a lower-ranked harvest job", function()
    eq(wp.choose(s{pop = 9, haul = true, priority = {haul = 1, forage = 4, chop = 4, mine = 4}}), "haul")
  end)
  it("gives every harvest role a share, and the shares add up (a nil share would crash choose)", function()
    for _, ratio in ipairs({0.1, 0.75, 2}) do
      local shares, sum = wp.desired_shares(ratio), 0
      for _, job in ipairs(wp.HARVEST) do
        truthy(shares[job] ~= nil, job .. " has no share at food_ratio " .. ratio)
        sum = sum + shares[job]
      end
      eq(math.abs(sum - 1) < 1e-9, true, "shares sum to " .. sum)
    end
  end)
end)

describe("fishing (#80)", function()
  local fishing = require("scripts.model.fishing")
  local function pond(cx, cy, r)
    return function(x, y) return math.abs(x - cx) <= r and math.abs(y - cy) <= r end
  end
  it("counts water tiles in the box, and needs six of them", function()
    eq(fishing.shore_ok(5), false); eq(fishing.shore_ok(6), true)
    local ok, found = fishing.on_shore({x = 0, y = 0}, pond(4, 0, 1))
    eq(ok, true); eq(found, 6)          -- stops as soon as it has enough
  end)
  it("accepts a dock beside a 3x3 pond and rejects one in a dry field", function()
    eq((fishing.on_shore({x = 0, y = 0}, pond(3, 0, 1))), true)
    eq((fishing.on_shore({x = 0, y = 0}, pond(40, 0, 1))), false)
  end)
  it("does not read the whole box when the answer is already known", function()
    local calls = 0
    local function probe(x, y) calls = calls + 1; return pond(1, 0, 1)(x, y) end
    fishing.on_shore({x = 0, y = 0}, probe)
    truthy(calls < 40, calls .. " tile reads")
  end)
  it("a big lake is still just water", function()
    local ok, found = fishing.on_shore({x = 0, y = 0}, pond(0, 0, 20))
    eq(ok, true); eq(found, fishing.MIN_WATER)
  end)
  it("fishing pays better than foraging, because water access is earned", function()
    truthy(fishing.FISH_PER_TRIP >= 4, fishing.FISH_PER_TRIP)
  end)
end)

describe("keeping food (#81)", function()
  local salt = require("scripts.model.salt")
  local preserve = require("scripts.model.preserve")
  local well = require("scripts.model.well")
  local function by_item(list)
    local out = {}
    for _, x in ipairs(list) do out[x.item] = x.count end
    return out
  end
  it("a well produces water up to cap (#43)", function()
    eq(well.full(0), false); eq(well.full(well.CAP - 1), false); eq(well.full(well.CAP), true)
    truthy(well.TICKS_PER_WATER > 0 and well.CAP > 0)
    eq(well.ITEM, "colony-water")
  end)
  it("a salt pan fills, and stops at its cap", function()
    eq(salt.full(0), false); eq(salt.full(salt.CAP - 1), false); eq(salt.full(salt.CAP), true)
    truthy(salt.TICKS_PER_SALT > 0 and salt.CAP > 0)
  end)
  it("cures meat with salt, and fish when there is no meat", function()
    local r = preserve.recipe({["colony-salt"] = 1, ["colony-meat"] = 1})
    eq(r.raw, "colony-meat"); eq(r.product, "colony-preserved-meat")
    eq(preserve.recipe({["colony-salt"] = 1, ["colony-fish"] = 2}).product, "colony-preserved-fish")
  end)
  it("cannot cure without salt, or without something to cure", function()
    eq(preserve.recipe({["colony-meat"] = 5}), nil)
    eq(preserve.recipe({["colony-salt"] = 5}), nil)
    eq(preserve.recipe({}), nil)
  end)
  it("asks for salt and a little raw food, discounting stock and what is already on its way", function()
    local w = by_item(preserve.wants({["colony-salt"] = 3, ["colony-meat"] = 2}, {["colony-fish"] = 1}))
    eq(w[preserve.SALT], preserve.SALT_STOCK - 3)
    eq(w["colony-meat"], nil)                                  -- already stocked
    eq(w["colony-fish"], preserve.RAW_STOCK - 1)               -- one is in flight
  end)
  it("never asks for more than its buffers when empty", function()
    local w = by_item(preserve.wants({}, {}))
    eq(w[preserve.SALT], preserve.SALT_STOCK)
    eq(w["colony-meat"], preserve.RAW_STOCK); eq(w["colony-fish"], preserve.RAW_STOCK)
  end)
end)

describe("hunting (#79)", function()
  local hunting = require("scripts.model.hunting")
  local function animal(un, x, y) return {unit_number = un, position = {x = x, y = y}} end
  it("picks the nearest animal inside the lodge's reach", function()
    local a = hunting.nearest({animal(1, 20, 0), animal(2, 5, 0)}, {x = 0, y = 0}, 30)
    eq(a.unit_number, 2)
  end)
  it("ignores game outside the range", function()
    eq(hunting.nearest({animal(1, 40, 0)}, {x = 0, y = 0}, 30), nil)
  end)
  it("breaks distance ties by unit_number, so the choice is stable", function()
    local a = hunting.nearest({animal(7, 0, 10), animal(3, 10, 0)}, {x = 0, y = 0}, 30)
    eq(a.unit_number, 3)
  end)
  it("returns nil with no game at all", function()
    eq(hunting.nearest({}, {x = 0, y = 0}, 30), nil)
  end)
  it("a kill is worth meat", function()
    truthy(hunting.MEAT_PER_KILL > 0)
  end)
end)

describe("haul_plan", function()
  local hp = require("scripts.model.haul_plan")
  it("splits the carry cap across a destination's requests (ore + fuel in one trip)", function()
    local load = hp.load({{item = "iron-ore", count = 20}, {item = "wood", count = 10}}, {["iron-ore"] = 100, wood = 100}, 20)
    local by = {}; for _, x in ipairs(load) do by[x.item] = x.count end
    eq(by["iron-ore"], 10); eq(by.wood, 10); eq(hp.total(load), 20)
  end)
  it("fills a single request to the cap", function()
    local load = hp.load({{item = "wood", count = 50}}, {wood = 50}, 20)
    eq(hp.total(load), 20)
  end)
  it("loads a small single demand once, not twice", function()
    local load = hp.load({{item = "coal", count = 5}}, {coal = 100}, 20)
    eq(#load, 1); eq(load[1].count, 5)
  end)
  it("never carries more than is on hand", function()
    local load = hp.load({{item = "wood", count = 20}}, {wood = 3}, 20)
    eq(hp.total(load), 3)
  end)
  it("picks whichever interchangeable option the hall has (forage or fish)", function()
    local load = hp.load({{need = "food", count = 12, items = {"colony-forage", "raw-fish"}}}, {["raw-fish"] = 9}, 20)
    eq(#load, 1); eq(load[1].item, "raw-fish"); eq(load[1].count, 9)
  end)
  it("serves higher priority first, then the biggest deficit", function()
    local offers = {
      {priority = hp.PRIORITY.buffer, key = 1, demands = {{item = "wood", count = 50}}},
      {priority = hp.PRIORITY.request, key = 2, demands = {{item = "iron-ore", count = 5}}},
      {priority = hp.PRIORITY.request, key = 3, demands = {{item = "coal", count = 9}}},
    }
    hp.order(offers)
    eq(offers[1].key, 3); eq(offers[2].key, 2); eq(offers[3].key, 1)
    local pick = hp.choose(offers, {["iron-ore"] = 9, coal = 9, wood = 9}, 20)
    eq(pick.key, 3)
  end)
end)

describe("housing", function()
  local h = require("scripts.model.housing")
  it("consumes food and fuel per occupant", function()
    local stock, acc = {["colony-forage"] = 10, wood = 10}, {}
    local c, sat, score = h.step(h.TIERS.tent, 4, stock, false, acc)
    eq(c["colony-forage"], 4); eq(c.wood, 2); eq(sat.food, true); eq(sat.heat, true); eq(score, 1)
  end)
  it("flags critical unmet when out of food", function()
    local _, sat, score, crit = h.step(h.TIERS.tent, 4, {wood = 5}, false, {})
    eq(sat.food, false); eq(crit, true); eq(score, 0.5)
  end)
  it("power substitutes for fuel", function()
    local stock = {["colony-forage"] = 10}
    local c, sat = h.step(h.TIERS.cabin, 6, stock, true, {})
    eq(sat.heat, true); eq(c.wood, nil)
    local _, sat2 = h.step(h.TIERS.cabin, 6, {["colony-forage"] = 10}, false, {})
    eq(sat2.heat, false)
  end)
  it("fractional fuel accrues over intervals", function()
    local stock, acc = {wood = 5, ["colony-forage"] = 99}, {}
    local used = 0
    for _ = 1, 4 do local c = h.step(h.TIERS.tent, 1, stock, false, acc); used = used + (c.wood or 0) end
    eq(used, 2)
  end)
  local function by_need(demand)
    local by = {}
    for _, x in ipairs(demand) do by[x.need] = x end
    return by
  end
  it("demands up to buffer, discounting stock and inflight, none for powered heat", function()
    local d = by_need(h.demand(h.TIERS.cabin, {wood = 5}, {wood = 4}, false))
    eq(d.heat.count, 18 - 9); eq(d.food.count, 36)
    eq(d.food.items[1], "colony-forage"); eq(d.food.items[2], "colony-fish")
    eq(d.food.items[3], "colony-meat"); eq(d.food.items[4], "raw-fish")
    eq(d.food.items[5], "colony-produce")
    -- the preserved tier is eaten LAST (#81): a house finishes what spoils first
    eq(d.food.items[6], "colony-preserved-fish"); eq(d.food.items[7], "colony-preserved-meat")
    eq(d.food.items[8], "colony-bread")
    local d2 = h.demand(h.TIERS.cabin, {}, {}, true)
    eq(#d2, 1)
  end)
  it("sizes the buffer by occupants, so an empty house does not hoard", function()
    eq(#h.demand(h.TIERS.cabin, {}, {}, false, 0), 0)
    local d = by_need(h.demand(h.TIERS.cabin, {}, {}, false, 2))
    eq(d.food.count, 12)
  end)
  it("distributes colonists", function()
    local o, homeless = h.distribute(7, {4, 4})
    eq(o[1], 4); eq(o[2], 3); eq(homeless, 0)
  end)
  it("assigns names to houses in the same order as distribute", function()
    local lists = h.assign({1, 2, 3, 4, 5, 6, 7}, {4, 4})
    eq(#lists[1], 4); eq(lists[1][1], 1); eq(lists[1][4], 4)
    eq(#lists[2], 3); eq(lists[2][1], 5); eq(lists[2][3], 7)
  end)
  it("assign leaves later houses empty when the town is small", function()
    local lists = h.assign({9}, {4, 6})
    eq(#lists[1], 1); eq(lists[1][1], 9); eq(#lists[2], 0)
  end)
  it("homestead requires food and water, heat from coal or power (#43)", function()
    local stock = {["colony-meat"] = 8, ["colony-water"] = 4, coal = 4}
    local c, sat, score, crit = h.step(h.TIERS.homestead, 8, stock, false, {})
    eq(sat.food, true); eq(sat.water, true); eq(sat.heat, true); eq(crit, false); eq(score, 1)
    eq(c["colony-meat"], 8); eq(c["colony-water"], 4); eq(c.coal, 4)

    -- Missing water triggers critical unmet
    local _, sat2, _, crit2 = h.step(h.TIERS.homestead, 8, {["colony-meat"] = 8}, true, {})
    eq(sat2.water, false); eq(crit2, true)

    -- Demand includes water and food
    local d = by_need(h.demand(h.TIERS.homestead, {}, {}, true))
    eq(d.food.count, 48)   -- 8 occ * 1 * 6 intervals
    eq(d.water.count, 24)  -- 8 occ * 0.5 * 6 intervals
    eq(d.heat, nil)        -- powered
  end)
  it("apartment requires food, water, and mandatory electricity (#43)", function()
    local stock = {["colony-forage"] = 16, ["colony-water"] = 8, ["colony-furniture"] = 2}
    -- Unpowered apartment fails critical electricity need even if food and water are present
    local _, sat_unpowered, score_unp, crit_unp = h.step(h.TIERS.apartment, 16, stock, false, {})
    eq(sat_unpowered.electricity, false); eq(crit_unp, true)

    -- Powered apartment meets electricity and consumes comfort goods
    local stock2 = {["colony-forage"] = 16, ["colony-water"] = 8, ["colony-furniture"] = 2}
    local c2, sat_powered, score_pow, crit_pow = h.step(h.TIERS.apartment, 16, stock2, true, {})
    eq(sat_powered.electricity, true); eq(sat_powered.comfort, true); eq(crit_pow, false); eq(score_pow, 1)
    eq(c2["colony-furniture"], 1)   -- floor(16 * 0.1) = 1

    -- Demand requests food, water, and comfort, but no electricity
    local d = by_need(h.demand(h.TIERS.apartment, {}, {}, true))
    eq(d.food.count, 96)      -- 16 occ * 1 * 6
    eq(d.water.count, 48)     -- 16 occ * 0.5 * 6
    eq(d.comfort.count, 10)   -- ceil(16 * 0.1 * 6) = 10
    eq(d.electricity, nil)
  end)
  it("assign handles no colonists and no houses", function()
    eq(#h.assign({}, {4}), 1); eq(#h.assign({}, {4})[1], 0)
    eq(#h.assign({1, 2}, {}), 0)
  end)
end)

describe("construct", function()
  local c = require("scripts.model.construct")
  it("prices a ghost from items_to_place_this", function()
    local cost = c.cost({{name = "wood", count = 4}, {name = "iron-plate", count = 1, amount = 9}})
    eq(#cost, 2); eq(cost[1].item, "iron-plate"); eq(cost[1].count, 1); eq(cost[2].item, "wood")
    eq(#c.cost({{name = "wood", count = 0}}), 0)
    eq(#c.cost(nil), 0)
  end)
  it("only starts a ghost the colony can pay for", function()
    local cost = c.cost({{name = "wood", count = 5}, {name = "iron-plate", count = 2}})
    truthy(c.affordable(cost, {wood = 5, ["iron-plate"] = 2}))
    truthy(not c.affordable(cost, {wood = 5, ["iron-plate"] = 1}))
  end)
  it("repairs at most one pack and stops at max health", function()
    local h, used = c.repaired(50, 200)
    eq(h, 200); truthy(used)
    eq(select(2, c.repaired(200, 200)), false)
    eq(select(2, c.repaired(nil, 200)), false)
  end)
  it("caps builders to a share of the population", function()
    eq(c.builders(0), 0); eq(c.builders(1), 1); eq(c.builders(4), 1); eq(c.builders(10), 3)
  end)
end)

describe("crates", function()
  local c = require("scripts.model.crates")
  it("demand targets subtract crate stock and inflight", function()
    local d = c.demands({{item = "coal", count = 50}}, {coal = 20}, {coal = 5})
    eq(#d, 1); eq(d[1].item, "coal"); eq(d[1].count, 25)
    eq(#c.demands({{item = "coal", count = 10}}, {coal = 40}, {}), 0)
  end)
  it("empty filter rows are not demands", function()
    eq(#c.demands({{}, {item = nil, count = 5}}, {}, {}), 0)
    eq(#c.demands(nil, {}, {}), 0)
  end)
  it("demands are sorted by item for determinism", function()
    local d = c.demands({{item = "stone", count = 5}, {item = "coal", count = 5}}, {}, {})
    eq(d[1].item, "coal"); eq(d[2].item, "stone")
  end)
  it("supply offers everything in the crate", function()
    local s = c.supply({wood = 30, coal = 4})
    eq(#s, 2); eq(s[1].item, "coal"); eq(s[1].count, 4); eq(s[2].item, "wood")
    eq(#c.supply({}), 0)
  end)
  it("clamps counts and keeps rows addressable", function()
    local f = {}
    c.set_count(f, 2, 9999); eq(f[2].count, c.MAX_COUNT)
    c.set_count(f, 2, "nope"); eq(f[2].count, 0)
    c.set_filter(f, 2, "iron-ore"); eq(f[2].item, "iron-ore"); eq(f[2].count, 0)
    c.set_filter(f, 3, nil); eq(f[3].item, nil)
  end)
  it("reports fill progress", function()
    local f = {{item = "coal", count = 20}, {item = "stone", count = 10}}
    local n, target = c.filled(f, {coal = 5, stone = 30})
    eq(n, 15); eq(target, 30)
  end)
end)

describe("compost (#78)", function()
  it("turns whole batches of ten spoilage into fertilizer", function()
    eq(compost.batches(10), 1); eq(compost.batches(35), 3); eq(compost.batches(400), 40)
  end)
  it("leaves the remainder in the bin for next time", function()
    local made, left = compost.batches(37)
    eq(made, 3); eq(left, 7)
  end)
  it("does nothing with less than a batch", function()
    local made, left = compost.batches(9)
    eq(made, 0); eq(left, 9)
  end)
  it("is defensive about junk", function()
    eq(compost.batches(nil), 0); eq(compost.batches(-5), 0); eq(compost.batches("x"), 0)
    eq(compost.batches(9.9), 0)
  end)
  it("is the lowest haul priority, but above nothing", function()
    local hp = require("scripts.model.haul_plan")
    for _, band in pairs(hp.PRIORITY) do
      if band ~= hp.PRIORITY.compost then truthy(band < hp.PRIORITY.compost) end
    end
  end)
end)

describe("mine_plan", function()
  local mp = require("scripts.model.mine_plan")
  it("defaults every ore to rank 1 (nearest-first, as before)", function()
    local e = mp.effective(nil)
    for _, ore in ipairs(mp.ORES) do eq(e[ore], 1) end
    eq(#mp.order(nil), #mp.ORES)
  end)
  it("orders by rank, ties keeping the ore list order", function()
    local p = {["iron-ore"] = 1, ["copper-ore"] = 1, coal = 2, stone = 1}
    eq(mp.order(p)[1], "iron-ore"); eq(mp.order(p)[2], "copper-ore")
    eq(mp.order(p)[3], "stone"); eq(mp.order(p)[4], "coal")
  end)
  it("rank 0 switches an ore off", function()
    local p = {["iron-ore"] = 0}
    local o = mp.order(p)
    eq(#o, #mp.ORES - 1)
    for _, ore in ipairs(o) do truthy(ore ~= "iron-ore") end
  end)
  it("shift moves one ore and clamps to 0..MAX_RANK", function()
    local p = {}
    mp.shift(p, "coal", -1); eq(mp.rank(p, "coal"), 0)     -- one step up from the default disables it
    mp.set(p, "coal", 1); mp.shift(p, "coal", 1); eq(mp.rank(p, "coal"), 2)
    mp.set(p, "coal", 0); eq(mp.enabled(p, "coal"), false)
    mp.set(p, "coal", 99); eq(mp.rank(p, "coal"), mp.MAX_RANK)
  end)
  it("ignores unknown ores", function()
    eq(mp.valid("uranium-ore"), false); eq(mp.valid("iron-ore"), true)
  end)
end)

describe("labour", function()
  local l = require("scripts.model.labour")
  it("limits workers by tools and capacity", function()
    eq(l.allowed(3, 0), 0); eq(l.allowed(3, 2), 2); eq(l.allowed(3, 9), 3)
    eq(l.allowed(3, 3, 1), 1); eq(l.allowed(3, 3, 0), 0); eq(l.allowed(3, 1, 3), 1)
  end)
  it("wears a tool after TOOL_USES trips", function()
    local c, broke = 0, false
    for _ = 1, l.TOOL_USES do c, broke = l.wear(c) end
    eq(broke, true); eq(c, 0)
  end)
  it("reports remaining uses for the hut GUI", function()
    eq(l.uses_left(0), l.TOOL_USES); eq(l.uses_left(l.TOOL_USES - 2), 2); eq(l.uses_left(nil), l.TOOL_USES)
  end)
  it("sums free slots by job", function()
    local f = l.free_slots({{job = "mine", allowed = 3, workers = 1}, {job = "mine", allowed = 1, workers = 1}, {job = "chop", allowed = 0, workers = 0}})
    eq(f.mine, 2); eq(f.chop, nil)
  end)
  it("sums tooled capacity by job", function()
    local c = l.capacity_by_job({{job = "mine", allowed = 3}, {job = "mine", allowed = 1}, {job = "chop", allowed = 0}})
    eq(c.mine, 4); eq(c.chop, 0)
  end)
end)

describe("farm", function()
  local f = require("scripts.model.farm")
  it("grass is the best soil and water cannot be farmed", function()
    eq(f.fertility("grass-2"), 1.0); eq(f.fertility("water"), 0)
    truthy(f.plantable("grass-1")); truthy(f.plantable("dirt-3")); truthy(f.plantable("dry-dirt"))
    eq(f.plantable("sand-1"), false); eq(f.plantable("concrete"), false)
  end)
  it("yield scales with fertility and never rounds down to nothing on plantable soil", function()
    eq(f.yield_for(1.0), f.YIELD_BASE); eq(f.yield_for(0.5), f.YIELD_BASE / 2)
    truthy(f.yield_for(f.MIN_FERTILITY) >= 1); eq(f.yield_for(0), 0)
  end)
  it("derives fallow/growing/ripe from the stored plot", function()
    eq(f.stage({stage = f.FALLOW}, 100), f.FALLOW)
    eq(f.stage({stage = f.GROWING, ripe_at = 500}, 100), f.GROWING)
    eq(f.stage({stage = f.GROWING, ripe_at = 500}, 500), f.RIPE)
    eq(f.stage({stage = f.RIPE}, 0), f.RIPE)
  end)
  it("fertilizer doubles harvest yield (#44)", function()
    eq(f.harvest_yield(1.0, false), f.YIELD_BASE)
    eq(f.harvest_yield(1.0, true), f.YIELD_BASE * 2)
    eq(f.harvest_yield(0.5, false), 4)
    eq(f.harvest_yield(0.5, true), 8)
  end)
end)

describe("kitchen (#44)", function()
  local k = require("scripts.model.kitchen")
  it("bakes produce and water into bread", function()
    local r = k.recipe({["colony-produce"] = 2, ["colony-water"] = 2})
    eq(r.product, "colony-bread")
  end)
  it("cannot bake without produce or without water", function()
    eq(k.recipe({["colony-produce"] = 5}), nil)
    eq(k.recipe({["colony-water"] = 5}), nil)
    eq(k.recipe({}), nil)
  end)
  it("requests produce and water up to stock buffer", function()
    local w = k.wants({["colony-produce"] = 1}, {["colony-water"] = 2})
    local by = {}
    for _, item in ipairs(w) do by[item.item] = item.count end
    eq(by["colony-produce"], k.PRODUCE_STOCK - 1)
    eq(by["colony-water"], k.WATER_STOCK - 2)
  end)
end)

describe("yields (#41)", function()
  local y = require("scripts.model.yields")
  local f = require("scripts.model.farm")
  local fish = require("scripts.model.fishing")
  local hunt = require("scripts.model.hunting")
  local lab = require("scripts.model.labour")
  local pres = require("scripts.model.preserve")
  local slt = require("scripts.model.salt")

  it("exports single source of truth for all yields and rates", function()
    eq(f.YIELD_BASE, y.FARM_BASE)
    eq(fish.FISH_PER_TRIP, y.FISH.count)
    eq(hunt.MEAT_PER_KILL, y.HUNT.count)
    eq(lab.TOOL_USES, y.TOOL_USES)
    eq(pres.SALT_PER_BATCH, y.CURE.salt)
    eq(pres.RAW_PER_BATCH, y.CURE.raw)
    eq(pres.PRODUCT_PER_BATCH, y.CURE.out)
    eq(slt.TICKS_PER_SALT, y.SALT_TICKS)
    eq(slt.CAP, y.SALT_CAP)
    local wel = require("scripts.model.well")
    eq(wel.TICKS_PER_WATER, y.WATER_TICKS)
    eq(wel.CAP, y.WATER_CAP)
    eq(y.FORAGE.count, 4)
    eq(y.CHOP.count, 4)
    eq(y.MINE_PER_TRIP, 5)
    eq(y.CARRY_CAP, 20)
    eq(y.WORK_TICKS, 480)
  end)
end)

describe("resource ledger (#82)", function()
  local ledger = require("scripts.model.ledger")
  it("aggregates stock, huts, and in-transit carries", function()
    local data = {
      stock = {wood = 50, ["iron-ore"] = 20},
      huts = {
        {name = "colony-woodcutter-hut", contents = {wood = 12}},
        {name = "colony-miner-hut", contents = {["iron-ore"] = 15, coal = 5}},
      },
      transit = {
        {item = "wood", count = 4},
        {item = "colony-meat", count = 6},
      },
    }
    local res = ledger.aggregate(data)
    eq(res.totals.wood, 66)
    eq(res.totals["iron-ore"], 35)
    eq(res.totals.coal, 5)
    eq(res.totals["colony-meat"], 6)
    eq(res.grand_total, 66 + 35 + 5 + 6)
    local wood_entry
    for _, item in ipairs(res.items) do
      if item.item == "wood" then wood_entry = item end
    end
    truthy(wood_entry)
    eq(wood_entry.stock, 50)
    eq(wood_entry.huts, 12)
    eq(wood_entry.transit, 4)
    eq(wood_entry.total, 66)
    eq(wood_entry.hut_details["colony-woodcutter-hut"], 12)
  end)
  it("sorts food before raw materials before tools", function()
    local data = {
      stock = {["colony-axe"] = 2, wood = 10, ["colony-forage"] = 8},
    }
    local res = ledger.aggregate(data)
    eq(res.items[1].item, "colony-forage")
    eq(res.items[2].item, "wood")
    eq(res.items[3].item, "colony-axe")
  end)
end)

describe("harvest quotas (#84)", function()
  local quota = require("scripts.model.quota")
  it("defaults to 0 (unlimited)", function()
    eq(quota.target(nil, nil, "iron-ore"), 0)
    eq(quota.met(0, 500), false)
  end)
  it("per-colony target overrides global settings", function()
    local quotas = {["iron-ore"] = 500}
    local globals = {["iron-ore"] = 1000}
    eq(quota.target(quotas, globals, "iron-ore"), 500)
    eq(quota.target(nil, globals, "iron-ore"), 1000)
  end)
  it("detects quota met when current reaches target", function()
    eq(quota.met(500, 499), false)
    eq(quota.met(500, 500), true)
    eq(quota.met(500, 550), true)
  end)
  it("filters out resources at quota while preserving open ones in order", function()
    local ores = {"iron-ore", "copper-ore", "coal"}
    local quotas = {["iron-ore"] = 200, ["copper-ore"] = 500}
    local counts = {["iron-ore"] = 200, ["copper-ore"] = 100, coal = 0}
    local open = quota.open_resources(ores, quotas, nil, counts)
    eq(#open, 2)
    eq(open[1], "copper-ore")
    eq(open[2], "coal")
  end)
  it("all_met returns true only when all items are capped and met", function()
    local ores = {"iron-ore", "copper-ore"}
    local quotas = {["iron-ore"] = 200, ["copper-ore"] = 500}
    eq(quota.all_met(ores, quotas, nil, {["iron-ore"] = 200, ["copper-ore"] = 499}), false)
    eq(quota.all_met(ores, quotas, nil, {["iron-ore"] = 200, ["copper-ore"] = 500}), true)
    eq(quota.all_met(ores, {["iron-ore"] = 200}, nil, {["iron-ore"] = 200, ["copper-ore"] = 500}), false)
  end)
end)

describe("workforce headcount targets (#73)", function()
  local headcount = require("scripts.model.headcount")
  local work_plan = require("scripts.model.work_plan")
  local jobs = require("scripts.model.jobs")

  it("handles target retrieval and setting", function()
    local targets = {}
    eq(headcount.target(targets, "mine"), nil)
    headcount.set_target(targets, "mine", 8)
    eq(headcount.target(targets, "mine"), 8)
    headcount.set_target(targets, "mine", "auto")
    eq(headcount.target(targets, "mine"), nil)
    headcount.set_target(targets, "mine", -1)
    eq(headcount.target(targets, "mine"), nil)
  end)

  it("shifts target up, down, and across auto cleanly", function()
    -- from nil: +1 sets to count + 1 (or 1)
    eq(headcount.shift_target(nil, 1, 3), 4)
    eq(headcount.shift_target(nil, 1, 0), 1)
    -- from nil: -1 sets to 0 (capped)
    eq(headcount.shift_target(nil, -1, 3), 0)
    -- from 3: +1 -> 4, -1 -> 2
    eq(headcount.shift_target(3, 1), 4)
    eq(headcount.shift_target(3, -1), 2)
    -- from 0: -1 -> nil (auto)
    eq(headcount.shift_target(0, -1), nil)
    -- from 0: +1 -> 1
    eq(headcount.shift_target(0, 1), 1)
  end)

  it("detects when a job has reached or exceeded its target", function()
    local targets = {mine = 8, chop = 0}
    eq(headcount.is_capped(targets, "mine", 7), false)
    eq(headcount.is_capped(targets, "mine", 8), true)
    eq(headcount.is_capped(targets, "mine", 9), true)
    eq(headcount.is_capped(targets, "chop", 0), true)
    eq(headcount.is_capped(targets, "forage", 50), false) -- auto is not capped
  end)

  it("steers work_plan.choose to prioritize jobs under their headcount target", function()
    local targets = {mine = 4, chop = 2}
    local priority = {haul = 1, forage = 2, chop = 2, mine = 2, farm = 2, hunt = 2, fish = 2, preserve = 2, construct = 2}
    local slots = {mine = 10, chop = 10, forage = 10}
    local capacity = {mine = 10, chop = 10, forage = 10}

    -- Mining has deficit (count 1 vs target 4); Chop has count 2 (target 2 met)
    local s = {food_ratio = 1.0, counts = {haul = 3, mine = 1, chop = 2, forage = 0},
      slots = slots, capacity = capacity, pop = 10, haul = false, priority = priority, targets = targets}
    eq(work_plan.choose(s), "mine")

    -- Mining met (count 4), Chop met (count 2), falls back to unconstrained job (forage)
    s.counts.mine = 4
    eq(work_plan.choose(s), "forage")

    -- When all open jobs are capped, choose returns nil (idle)
    local s_capped = {food_ratio = 1.0, counts = {haul = 2, mine = 4, chop = 2},
      slots = {mine = 10, chop = 10}, capacity = {mine = 10, chop = 10}, pop = 8, haul = false,
      priority = priority, targets = {haul = 2, mine = 4, chop = 2}}
    eq(work_plan.choose(s_capped), nil)
  end)
end)

describe("colony science (#42)", function()
  local science = require("scripts.model.science")
  local jobs = require("scripts.model.jobs")
  local work_plan = require("scripts.model.work_plan")

  it("calculates lab buffer wants", function()
    local archive_wants = science.wants(science.ARCHIVE, {}, {})
    eq(#archive_wants, 1)
    eq(archive_wants[1].item, science.FRONTIER_PACK)
    eq(archive_wants[1].count, 10)

    -- In-flight delivery and inventory reduce demand
    local partial = science.wants(science.ARCHIVE, {[science.FRONTIER_PACK] = 3}, {[science.FRONTIER_PACK] = 4})
    eq(#partial, 1)
    eq(partial[1].count, 3)

    -- Fully stocked archive wants nothing
    local full = science.wants(science.ARCHIVE, {[science.FRONTIER_PACK] = 10}, {})
    eq(#full, 0)

    -- University wants both packs
    local uni_wants = science.wants(science.UNIVERSITY, {}, {})
    eq(#uni_wants, 2)
    eq(uni_wants[1].item, science.FRONTIER_PACK)
    eq(uni_wants[2].item, science.CIVIC_PACK)
  end)

  it("integrates research role into jobs registry", function()
    local found = false
    for _, j in ipairs(jobs.JOBS) do
      if j == "research" then found = true end
    end
    eq(found, true)
    eq(jobs.DEFAULT.research, 2)
  end)

  it("calculates research workforce capacity and steers work_plan", function()
    eq(work_plan.research_workers(10), 1)
    eq(work_plan.research_workers(20), 3)

    local priority = {haul = 1, forage = 2, chop = 2, mine = 2, farm = 2, hunt = 2, fish = 2,
      preserve = 2, construct = 2, research = 2}
    local s = {food_ratio = 1.0, counts = {haul = 2, forage = 1, chop = 1, mine = 1, research = 0},
      slots = {research = 2, forage = 2}, capacity = {research = 2, forage = 2}, pop = 15,
      haul = false, priority = priority}
    -- With food abundant and research open, research can be chosen
    local chosen = work_plan.choose(s)
    truthy(chosen == "research" or chosen == "forage")

    -- High research priority wins cleanly
    local prio_high = {haul = 1, forage = 3, chop = 3, mine = 3, farm = 3, hunt = 3, fish = 3,
      preserve = 3, construct = 3, research = 1}
    s.priority = prio_high
    eq(work_plan.choose(s), "research")
  end)
end)
