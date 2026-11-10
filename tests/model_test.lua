local desirability = require("scripts.model.desirability")
local spoilage = require("scripts.model.spoilage")
local jobs = require("scripts.model.jobs")
local cm = require("scripts.model.colony_model")
local scenic = require("scripts.model.scenic")
local tags = require("scripts.model.tags")
local compost = require("scripts.model.compost")
local advice = require("scripts.model.advice")

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
  it("each tent drags desirability down, stopping at the tent cap", function()
    local base = desirability.compute({food_ratio = 1, free_housing_ratio = 0.5})
    local two = desirability.compute({food_ratio = 1, free_housing_ratio = 0.5, tents = 2})
    local eight = desirability.compute({food_ratio = 1, free_housing_ratio = 0.5, tents = 8})
    local twelve = desirability.compute({food_ratio = 1, free_housing_ratio = 0.5, tents = 12})
    truthy(two < base)
    near(eight - base, -desirability.defaults.w_tents * desirability.defaults.tent_cap)
    near(twelve - base, -desirability.defaults.w_tents * desirability.defaults.tent_cap, 1e-9, "tent penalty caps at tent_cap tents")
  end)
  it("open job slots are a big pull factor, maxing out at jobs_full", function()
    local none = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5})
    local some = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, open_jobs = 3})
    local full = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, open_jobs = desirability.defaults.jobs_full})
    local over = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, open_jobs = 99})
    truthy(some > none)
    near(over - none, full - none, 1e-9, "job pull maxes out at jobs_full open slots")
  end)
  it("privacy: empty and single-person houses are the most desirable", function()
    local base = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5})
    local private = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, privacy = 1})
    near(private - base, desirability.defaults.w_privacy)
  end)
  it("a short commute is a small bonus and a long one loses it (#93)", function()
    local base = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5})
    local near_work = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, commute = 1})
    local far_away = desirability.compute({food_ratio = 0.5, free_housing_ratio = 0.5, commute = 0})
    near(near_work - base, desirability.defaults.w_commute)
    near(far_away, base, 1e-9, "no commute bonus is never a penalty")
  end)
  it("commute_score falls from 1 at the door to 0 at commute_far", function()
    near(desirability.commute_score(0), 1)
    near(desirability.commute_score(desirability.defaults.commute_far), 0)
    near(desirability.commute_score(desirability.defaults.commute_far / 2), 0.5)
    near(desirability.commute_score(desirability.defaults.commute_far * 4), 0)
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
  it("carries crate priority and accept_all flag", function()
    local back = tags.decode(tags.dictionary(tags.crate({filters = {}, accept_all = false, priority = 1})))
    truthy(back.crate)
    eq(back.crate.accept_all, false)
    eq(back.crate.priority, 1)
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

describe("garrison (#56)", function()  local garrison = require("scripts.model.garrison")
  local labour = require("scripts.model.labour")
  it("the Watchtower is a tooled guard post: one post per rifle, capped by the player's limit", function()
    local def = labour.HUTS["colony-watchtower"]
    eq(def.job, "guard"); eq(def.tool, "colony-bow"); eq(def.capacity, 4)
    eq(labour.allowed(def.capacity, 0, nil), 0)   -- no weapons, nobody posted
    eq(labour.allowed(def.capacity, 2, nil), 2)
    eq(labour.allowed(def.capacity, 4, 1), 1)     -- the limit still caps the garrison
  end)
  it("a rifle wears one step per engagement, like a hunter's trip", function()
    local counter, broke = labour.wear(labour.TOOL_USES - 1)
    eq(counter, 0); eq(broke, true)
    counter, broke = labour.wear(0); eq(counter, 1); eq(broke, false)
  end)
  it("picks the nearest hostile in range, ties by unit number", function()
    local pos = {x = 0, y = 0}
    local enemies = {{unit_number = 9, position = {x = 3, y = 4}}, {unit_number = 3, position = {x = -3, y = -4}},
      {unit_number = 5, position = {x = 100, y = 0}}}
    eq(garrison.nearest(enemies, pos, 16).unit_number, 3)
    eq(garrison.nearest(enemies, pos, 4), nil)    -- beyond the engagement radius
    local tie = {{unit_number = 8, position = {x = 2, y = 0}}, {unit_number = 2, position = {x = -2, y = 0}}}
    eq(garrison.nearest(tie, pos, 16).unit_number, 2)
  end)
  it("guard duty joins the matrix and guards are exempt from sheltering", function()
    eq(jobs.DEFAULT.guard, 2)
    local alarm = require("scripts.model.alarm")
    eq(alarm.EXEMPT.guarding, true); eq(alarm.EXEMPT.to_tower, true); eq(alarm.EXEMPT["guarding-fight"], true)
  end)
  it("a tower is never the source of its own rifle request", function()
    local haul_plan = require("scripts.model.haul_plan")
    local tower = {}
    local req = {priority = haul_plan.PRIORITY.tools, entity = tower, pos = {x = 0, y = 0}, key = 7,
      demands = {{item = "colony-rifle", count = 1}}}
    local storages = {
      {kind = "watchtower", entity = tower, pos = {x = 0, y = 0}, key = 7, available = {["colony-rifle"] = 1}, has_space = true},
      {kind = "hall", entity = {}, pos = {x = 40, y = 0}, key = 1, available = {["colony-rifle"] = 1}, has_space = true},
    }
    local task = haul_plan.match({req}, {}, storages, {}, 20, {x = 0, y = 0})
    eq(task.source.kind, "hall")
    -- With nothing in the hall the request simply waits: it must never "haul" the tower's own rifle to itself.
    storages[2].available = {}
    eq(haul_plan.match({req}, {}, storages, {}, 20, {x = 0, y = 0}), nil)
  end)
  it("uses the best weapon in the stock room: rifle > SMG > pistol > bow", function()
    eq(garrison.best_weapon({["colony-bow"] = 1}), "colony-bow")
    eq(garrison.best_weapon({["colony-bow"] = 1, pistol = 1}), "pistol")
    eq(garrison.best_weapon({pistol = 1, ["submachine-gun"] = 1}), "submachine-gun")
    eq(garrison.best_weapon({["submachine-gun"] = 1, ["colony-rifle"] = 1}), "colony-rifle")
    eq(garrison.best_weapon({}), nil)
    eq(garrison.best_weapon(nil), nil)
  end)
  it("a gun without a magazine falls back to the bow until ammunition arrives", function()
    local mode, weapon, ammo = garrison.arm({pistol = 1})
    eq(mode, nil)                                  -- a pistol is not a bow
    mode, weapon, ammo = garrison.arm({pistol = 1, ["colony-bow"] = 1, ["colony-arrow"] = 4})
    eq(mode, "bow"); eq(weapon, "colony-bow"); eq(ammo, "colony-arrow")
    mode, weapon, ammo = garrison.arm({pistol = 1, ["firearm-magazine"] = 2})
    eq(mode, "gun"); eq(weapon, "pistol"); eq(ammo, "firearm-magazine")
    mode, weapon, ammo = garrison.arm({["submachine-gun"] = 1, ["piercing-rounds-magazine"] = 1})
    eq(mode, "gun"); eq(weapon, "submachine-gun"); eq(ammo, "piercing-rounds-magazine")
  end)
  it("a rifle carries its own ammunition and is spent by wear, not by magazines", function()
    local mode, weapon, ammo = garrison.arm({["colony-rifle"] = 1})
    eq(mode, "gun"); eq(weapon, "colony-rifle"); eq(ammo, nil)
  end)
  it("ammunition is requested by the weapons present, even when they cannot shoot yet", function()
    local item, deficit = garrison.ammo_wanted({pistol = 1}, nil)
    eq(item, "firearm-magazine"); eq(deficit, garrison.AMMO_TARGET["firearm-magazine"])
    item, deficit = garrison.ammo_wanted({["colony-bow"] = 1}, {["colony-arrow"] = 18})
    eq(item, "colony-arrow"); eq(deficit, 2)
    eq(garrison.ammo_wanted({["colony-rifle"] = 1}, nil), nil)   -- self-ammo: asks for nothing
    eq(garrison.ammo_wanted({}, nil), nil)
  end)
end)

describe("material caps (#84)", function()
  local quota = require("scripts.model.quota")
  it("produced intermediates are cappable, default 20 so they never pile to infinity (#54)", function()
    eq(quota.RESOURCES["iron-plate"].category, "supply")
    eq(quota.RESOURCES["iron-plate"].default, 20)
    eq(quota.RESOURCES["iron-gear-wheel"].category, "supply")
    eq(quota.RESOURCES["copper-plate"].default, 20)
    eq(quota.RESOURCES["steel-plate"].default, 20)
    eq(quota.target(nil, nil, "iron-plate"), 0)          -- 0 = unlimited only when player sets it
    eq(quota.met(20, 20), true)
    eq(quota.met(20, 19), false)
  end)
  it("a player cap is a ceiling on collection", function()
    local quotas = {["iron-plate"] = 200}
    eq(quota.target(quotas, nil, "iron-plate"), 200)
    eq(quota.met(200, 199), false)
    eq(quota.met(200, 200), true)
    eq(quota.met(200, 201), true)
  end)
  it("harvested resources keep their quota defaults and their jobs", function()
    eq(quota.RESOURCES.wood.job, "chop")
    eq(quota.RESOURCES["colony-arrow"].default, 20)
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
  it("raises the hauler target with the delivery backlog, up to half the town", function()
    eq(wp.haul_target(20), 7)                -- 0.35 * 20, rounded
    eq(wp.haul_target(20, 3), 7)             -- a small backlog changes nothing
    eq(wp.haul_target(20, 9), 9)             -- one hauler per waiting destination
    eq(wp.haul_target(20, 40), 10)           -- capped at HAUL_MAX_SHARE
    eq(wp.haul_target(0, 40), 0)
  end)
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
  it("staffs every built hut, not just the oldest one, when the food share is small", function()
    local base = {pop = 4, food_ratio = 2, counts = {mine = 1, chop = 0},
      slots = {mine = 8, chop = 3}, capacity = {mine = 9, chop = 3},
      priority = {haul = 0, forage = 2, chop = 2, mine = 2, farm = 2, hunt = 2, fish = 2,
        preserve = 2, construct = 2, research = 2}}
    -- The share alone is already met by the one miner, so the next colonist chops instead of staffing the
    -- second and third miner huts.
    eq(wp.choose(base), "chop")
    base.hut_count = {mine = 3, chop = 1}
    eq(wp.choose(base), "mine")
  end)
  it("never assigns a job with no free tooled slot", function()
    eq(wp.choose(s{pop = 2, slots = {forage = 0, chop = 1, mine = 0}, capacity = {forage = 0, chop = 1, mine = 0}}), "chop")
  end)
  it("idles when there is no tooled slot and nothing to haul", function()
    eq(wp.choose(s{pop = 2, slots = {}, capacity = {}}), nil)
  end)
  it("posts a guard when a tower is manned, and hauling still wins at equal rank", function()
    local base = {pop = 6, food_ratio = 2, counts = {}, haul = true, slots = {forage = 3, guard = 2},
      capacity = {forage = 3, guard = 2}, priority = {haul = 1, forage = 2, guard = 2}}
    eq(wp.choose(base), "haul")                                    -- haul rank 1 outranks a rank-2 garrison
    base.priority = {haul = 2, forage = 2, guard = 1}
    eq(wp.choose(base), "guard")                                   -- rank-1 guard duty beats hauling rank 2
    base.counts = {guard = 2}; base.slots = {forage = 3, guard = 0} -- both posts filled (job_slots closes them)
    truthy(wp.choose(base) ~= "guard")
    base.priority = {haul = 1, forage = 2, guard = 2}; base.slots = {forage = 3, guard = 0}
    base.counts = {}
    eq(wp.choose(base), "haul")                                    -- an unmanned tower offers no post
  end)
  it("honours the priority matrix: hauling can be switched off", function()
    local job = wp.choose(s{pop = 6, haul = true, priority = {haul = 0, forage = 2, chop = 2, mine = 2}})
    truthy(job == "forage" or job == "chop" or job == "mine", tostring(job))
  end)
  it("honours the priority matrix: a rank-1 role beats the food ratio", function()
    eq(wp.choose(s{food_ratio = 0.1, priority = {haul = 1, forage = 3, chop = 1, mine = 1}}), "chop")
  end)
  it("honours the priority matrix: a rank-1 harvest role beats a rank-2 hauling job", function()
    local job = wp.choose(s{pop = 6, haul = true, priority = {haul = 2, chop = 1, forage = 2, mine = 2},
      slots = {chop = 2, mine = 2, forage = 2}, capacity = {chop = 2, mine = 2, forage = 2}})
    eq(job, "chop")
  end)
  it("prioritises food jobs over non-food jobs when food is 0", function()
    local job = wp.choose(s{pop = 4, food_ratio = 0, haul = true,
      priority = {haul = 1, forage = 2, chop = 2, mine = 2},
      slots = {chop = 2, mine = 2, forage = 2}, capacity = {chop = 2, mine = 2, forage = 2}})
    eq(job, "forage")
  end)
  it("honours the priority matrix: a disabled role is never assigned", function()
    eq(wp.choose(s{slots = {forage = 3}, capacity = {forage = 3},
      priority = {haul = 0, forage = 0, chop = 0, mine = 0}}), nil)
  end)
  it("keeps hauling below its share before starting a lower-ranked harvest job", function()
    eq(wp.choose(s{pop = 9, haul = true, priority = {haul = 1, forage = 4, chop = 4, mine = 4}}), "haul")
  end)
  it("allows a lone colonist to haul when there is haul work", function()
    eq(wp.choose(s{pop = 0, haul = true}), "haul")
  end)
  it("prioritises missing resources over abundant ones", function()
    -- wood is abundant (missing = false), iron/mine is missing (missing = true)
    local state = s{pop = 3, missing = {mine = true, chop = false, forage = false},
      slots = {chop = 2, mine = 2, forage = 2}, capacity = {chop = 2, mine = 2, forage = 2}}
    eq(wp.choose(state), "mine")
  end)
  it("round-robins across missing harvest resources", function()
    local state0 = s{pop = 3, cursor = 0, missing = {chop = true, mine = true},
      slots = {chop = 2, mine = 2}, capacity = {chop = 2, mine = 2}}
    local state1 = s{pop = 3, cursor = 1, missing = {chop = true, mine = true},
      slots = {chop = 2, mine = 2}, capacity = {chop = 2, mine = 2}}
    local j0 = wp.choose(state0)
    local j1 = wp.choose(state1)
    truthy(j0 == "chop" or j0 == "mine")
    truthy(j1 == "chop" or j1 == "mine")
    truthy(j0 ~= j1, "expected round-robin to pick different jobs, got " .. tostring(j0) .. " and " .. tostring(j1))
  end)
  it("falls through to hauling when all harvest resources reach threshold", function()
    -- none are missing, haul task available
    local state = s{pop = 3, missing = {mine = false, chop = false, forage = false}, haul = true,
      slots = {chop = 2, mine = 2, forage = 2}, capacity = {chop = 2, mine = 2, forage = 2}}
    eq(wp.choose(state), "haul")
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
  it("choose_overflow selects harvest jobs with least workers and breaks ties with cursor", function()
    eq(wp.choose_overflow({overflow_slots = {}}), nil)
    eq(wp.choose_overflow({overflow_slots = {chop = 0, mine = 0}}), nil)
    eq(wp.choose_overflow({overflow_slots = {chop = 2, mine = 1}, counts = {chop = 0, mine = 1}}), "chop")
    eq(wp.choose_overflow({overflow_slots = {chop = 2, mine = 1}, counts = {chop = 1, mine = 0}}), "mine")
    -- Ties broken by cursor:
    eq(wp.choose_overflow({overflow_slots = {chop = 1, mine = 1}, counts = {chop = 0, mine = 0}, cursor = 0}), "chop")
    eq(wp.choose_overflow({overflow_slots = {chop = 1, mine = 1}, counts = {chop = 0, mine = 0}, cursor = 1}), "mine")
    -- Disabled job skipped:
    eq(wp.choose_overflow({overflow_slots = {chop = 1}, priority = {chop = 0}}), nil)
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
  it("sorts by building_priority within the same priority band", function()
    local offers = {
      {priority = hp.PRIORITY.request, building_priority = 4, key = 1, demands = {{item = "wood", count = 10}}},
      {priority = hp.PRIORITY.request, building_priority = 2, key = 2, demands = {{item = "wood", count = 10}}},
      {priority = hp.PRIORITY.request, building_priority = 3, key = 3, demands = {{item = "wood", count = 10}}},
    }
    hp.order(offers)
    eq(offers[1].key, 2); eq(offers[2].key, 3); eq(offers[3].key, 1)
  end)
  it("matches active provider directly to requester when item is available", function()
    local house = {key = 1, priority = hp.PRIORITY.critical, pos = {x = 10, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local forager = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 15, y = 10}, available = {["colony-forage"] = 15}}
    local hall = {key = 3, pos = {x = 80, y = 80}, available = {["colony-forage"] = 50}, has_space = true}

    local task, backlog = hp.match({house}, {forager}, {hall}, nil, 20)
    truthy(task)
    eq(task.kind, "direct")
    eq(task.source.key, 2)
    eq(task.target.key, 1)
    eq(task.load[1].item, "colony-forage")
    eq(task.load[1].count, 8)
    eq(backlog, 2)
  end)
  it("prefers closer active provider over farther active provider", function()
    local house = {key = 1, priority = hp.PRIORITY.critical, pos = {x = 10, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local near_forager = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 12, y = 10}, available = {["colony-forage"] = 10}}
    local far_forager = {key = 3, priority = hp.PRIORITY.hut_output, pos = {x = 60, y = 60}, available = {["colony-forage"] = 20}}
    local hall = {key = 4, pos = {x = 80, y = 80}, available = {}, has_space = true}

    local task = hp.match({house}, {far_forager, near_forager}, {hall}, nil, 20)
    truthy(task)
    eq(task.kind, "direct")
    eq(task.source.key, 2)
  end)
  it("falls back to storage when active providers do not have the demanded item", function()
    local house = {key = 1, priority = hp.PRIORITY.critical, pos = {x = 10, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local miner = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 15, y = 10}, available = {["copper-ore"] = 30}}
    local hall = {key = 3, pos = {x = 50, y = 50}, available = {["colony-forage"] = 50}, has_space = true}

    local task = hp.match({house}, {miner}, {hall}, nil, 20)
    truthy(task)
    eq(task.kind, "supply")
    eq(task.source.key, 3)
    eq(task.target.key, 1)
    eq(task.load[1].item, "colony-forage")
  end)
  it("pushes active provider output to nearest open storage when no requester needs it", function()
    local miner = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 10, y = 10}, available = {["copper-ore"] = 30}}
    local warehouse = {key = 3, pos = {x = 15, y = 10}, available = {}, has_space = true}
    local hall = {key = 4, pos = {x = 100, y = 100}, available = {}, has_space = true}

    local task = hp.match({}, {miner}, {hall, warehouse}, nil, 20)
    truthy(task)
    eq(task.kind, "collect")
    eq(task.source.key, 2)
    eq(task.target.key, 3) -- picks nearest warehouse over far hall
    eq(task.load[1].item, "copper-ore")
  end)
  it("pushes active provider output to higher storage_priority over closer storage", function()
    local miner = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 10, y = 10}, available = {["copper-ore"] = 30}}
    local hall = {key = 3, pos = {x = 12, y = 10}, available = {}, has_space = true, storage_priority = 3}
    local warehouse = {key = 4, pos = {x = 25, y = 10}, available = {}, has_space = true, storage_priority = 2}

    local task = hp.match({}, {miner}, {hall, warehouse}, nil, 20)
    truthy(task)
    eq(task.kind, "collect")
    eq(task.target.key, 4) -- picks higher priority warehouse (priority 2) over closer hall (priority 3)
  end)
  it("respects storage whitelist: skips storage that does not accept the item", function()
    local miner = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 10, y = 10}, available = {["copper-ore"] = 30}}
    local iron_warehouse = {key = 3, pos = {x = 12, y = 10}, available = {}, has_space = true, storage_priority = 1,
      accepts_item = function(item) return item == "iron-ore" end}
    local general_warehouse = {key = 4, pos = {x = 30, y = 10}, available = {}, has_space = true, storage_priority = 2,
      accepts_item = function(item) return true end}

    local task = hp.match({}, {miner}, {iron_warehouse, general_warehouse}, nil, 20)
    truthy(task)
    eq(task.kind, "collect")
    eq(task.target.key, 4) -- iron_warehouse refused copper-ore; general_warehouse accepted it
  end)
  it("serves production chain directly (woodcutter to toolsmith)", function()
    local toolsmith = {key = 10, priority = hp.PRIORITY.request, pos = {x = 20, y = 20}, demands = {{item = "wood", count = 10}}}
    local woodcutter = {key = 20, priority = hp.PRIORITY.hut_output, pos = {x = 25, y = 20}, available = {wood = 40}}
    local hall = {key = 30, pos = {x = 80, y = 80}, available = {wood = 100}, has_space = true}

    local task = hp.match({toolsmith}, {woodcutter}, {hall}, nil, 20)
    truthy(task)
    eq(task.kind, "direct")
    eq(task.source.key, 20)
    eq(task.target.key, 10)
    eq(task.load[1].item, "wood")
  end)
  it("critical starving house takes priority over buffer top-up for direct food transfer", function()
    local starving = {key = 1, priority = hp.PRIORITY.critical, pos = {x = 10, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local fed = {key = 2, priority = hp.PRIORITY.buffer, pos = {x = 12, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local forager = {key = 3, priority = hp.PRIORITY.hut_output, pos = {x = 15, y = 10}, available = {["colony-forage"] = 8}}

    local task = hp.match({fed, starving}, {forager}, {}, nil, 20)
    truthy(task)
    eq(task.kind, "direct")
    eq(task.target.key, 1) -- starving house served first
  end)
  it("direct transfer takes partial available amount when provider has less than demand", function()
    local house = {key = 1, priority = hp.PRIORITY.critical, pos = {x = 10, y = 10}, demands = {{item = "colony-forage", count = 8}}}
    local forager = {key = 2, priority = hp.PRIORITY.hut_output, pos = {x = 15, y = 10}, available = {["colony-forage"] = 3}}

    local task = hp.match({house}, {forager}, {}, nil, 20)
    truthy(task)
    eq(task.kind, "direct")
    eq(task.load[1].count, 3)
  end)
  it("picks the source on the way from the hauler, not the one nearest the destination (#93)", function()
    local house = {key = 1, priority = hp.PRIORITY.request, pos = {x = 100, y = 0}, demands = {{item = "wood", count = 10}}}
    local next_door = {key = 2, pos = {x = 100, y = 5}, available = {wood = 10}, has_space = true}
    local on_the_way = {key = 3, pos = {x = 50, y = 5}, available = {wood = 10}, has_space = true}
    -- Hauler at the origin: next_door = 100.12 + 5 = 105.12, on_the_way = 50.25 + 50.25 = 100.5.
    local task = hp.match({house}, {}, {next_door, on_the_way}, nil, 20, {x = 0, y = 0})
    truthy(task)
    eq(task.kind, "supply")
    eq(task.source.key, 3)
  end)
end)

describe("housing", function()
  local h = require("scripts.model.housing")
  it("consumes food and fuel per occupant", function()
    local stock, acc = {["colony-forage"] = 10, wood = 10}, {}
    local c, sat, score = h.step(h.TIERS.tent, 4, stock, false, acc)
    eq(c["colony-forage"], 4); eq(c.wood, 2); eq(sat.food, true); eq(sat.heat, true); eq(score, 1)
  end)
  it("satisfies food from mixed options without debt spiral", function()
    -- 2 forage + 2 fish for 4 occupants satisfies food completely
    local stock, acc = {["colony-forage"] = 2, ["colony-fish"] = 2, wood = 2}, {}
    local c, sat, score, crit = h.step(h.TIERS.tent, 4, stock, false, acc)
    eq(c["colony-forage"], 2); eq(c["colony-fish"], 2); eq(sat.food, true); eq(crit, false); eq(score, 1)
    eq(stock["colony-forage"], 0); eq(stock["colony-fish"], 0)

    -- Eats fresh food before preserved food
    local stock2 = {["colony-forage"] = 2, ["colony-preserved-meat"] = 10, wood = 2}
    local c2, sat2 = h.step(h.TIERS.tent, 4, stock2, false, {})
    eq(c2["colony-forage"], 2); eq(c2["colony-preserved-meat"], 2); eq(sat2.food, true)
    eq(stock2["colony-forage"], 0); eq(stock2["colony-preserved-meat"], 8)

    -- Shortfall in interval 1 does not inflate food debt in interval 2
    local stock3 = {["colony-forage"] = 1, wood = 2}
    local _, sat3, _, crit3 = h.step(h.TIERS.tent, 4, stock3, false, acc)
    eq(sat3.food, false); eq(crit3, true)
    -- Next interval: 4 food arrives for 4 occupants and must satisfy them immediately
    local stock4 = {["colony-forage"] = 4, wood = 2}
    local c4, sat4, _, crit4 = h.step(h.TIERS.tent, 4, stock4, false, acc)
    eq(c4["colony-forage"], 4); eq(sat4.food, true); eq(crit4, false)
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
  it("uses hysteresis for demands: only reorders below threshold unless forced", function()
    -- Cabin (6 occupants, 1 food/eval, buffer 6 intervals = 36 target, reorder threshold 3 intervals = 18)
    -- When stock has 30 food (deficit 6): no demand generated because stock > 18
    local d_full = h.demand(h.TIERS.cabin, {["colony-forage"] = 30}, {}, true, 6)
    eq(#d_full, 0)
    -- When stock drops to 18 (threshold): generates demand for full deficit (36 - 18 = 18)
    local d_low = by_need(h.demand(h.TIERS.cabin, {["colony-forage"] = 18}, {}, true, 6))
    eq(d_low.food.count, 18)
    -- When stock drops to 0: generates demand for 36
    local d_zero = by_need(h.demand(h.TIERS.cabin, {}, {}, true, 6))
    eq(d_zero.food.count, 36)
    -- When forced (e.g. need is unmet), reorders even if stock > threshold
    local d_forced = by_need(h.demand(h.TIERS.cabin, {["colony-forage"] = 30}, {}, true, 6, true))
    eq(d_forced.food.count, 6)
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
  it("uses hysteresis for demand crates: only requests when stock <= 50% or deficit >= 10", function()
    -- Target 50: threshold is 25.
    -- Have 45 (deficit 5 < 10, have > 25): no demand
    eq(#c.demands({{item = "iron-ore", count = 50}}, {["iron-ore"] = 45}, {}), 0)
    -- Have 40 (deficit 10 >= 10): generates demand for 10
    local d10 = c.demands({{item = "iron-ore", count = 50}}, {["iron-ore"] = 40}, {})
    eq(#d10, 1); eq(d10[1].count, 10)
    -- Have 20 (deficit 30, have <= 25): generates demand for 30
    local d30 = c.demands({{item = "iron-ore", count = 50}}, {["iron-ore"] = 20}, {})
    eq(#d30, 1); eq(d30[1].count, 30)
    -- Forced reorder requests small deficit even above threshold
    local d_force = c.demands({{item = "iron-ore", count = 50}}, {["iron-ore"] = 48}, {}, true)
    eq(#d_force, 1); eq(d_force[1].count, 2)
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
  it("comes after every real request, but before topping up houses that are already fed", function()
    local hp = require("scripts.model.haul_plan")
    for name, band in pairs(hp.PRIORITY) do
      if name ~= "compost" and name ~= "buffer" then truthy(band < hp.PRIORITY.compost) end
    end
    truthy(hp.PRIORITY.compost < hp.PRIORITY.buffer)
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
  it("groups enabled ores by rank in order", function()
    local p = {["copper-ore"] = 1, ["iron-ore"] = 2, stone = 0, coal = 2}
    local groups = mp.by_rank(p)
    eq(#groups, 2)
    eq(groups[1].rank, 1); eq(#groups[1].ores, 1); eq(groups[1].ores[1], "copper-ore")
    eq(groups[2].rank, 2); eq(#groups[2].ores, 2)
    eq(groups[2].ores[1], "iron-ore"); eq(groups[2].ores[2], "coal")
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
  it("steel tiers last 45 trips and work 20% faster (#95)", function()
    eq(l.uses_for("colony-steel-axe"), 45)
    eq(l.uses_for("colony-steel-pickaxe"), 45)
    eq(l.uses_for("colony-steel-hoe"), 45)
    eq(l.uses_for("colony-axe"), l.TOOL_USES)
    eq(l.uses_for(nil), l.TOOL_USES)
    local c, broke = 0, false
    for _ = 1, 30 do c, broke = l.wear(c, "colony-steel-axe") end
    eq(broke, false)  -- steel is not done at the tier-1 count
    for _ = 1, 15 do c, broke = l.wear(c, "colony-steel-axe") end
    eq(broke, true); eq(c, 0)
    eq(l.uses_left(0, "colony-steel-axe"), 45)
    eq(l.work_ticks(480, "colony-steel-axe"), 384)
    eq(l.work_ticks(480, "colony-steel-pickaxe"), 384)
    eq(l.work_ticks(480, "colony-axe"), 480)
    eq(l.work_ticks(480, nil), 480)
  end)
  it("steel ladders pick best for service and worst for consumption (#95)", function()
    local def = l.HUTS["colony-woodcutter-hut"]
    eq(table.concat(def.tools, ","), "colony-steel-axe,colony-axe")
    eq(table.concat(l.HUTS["colony-miner-hut"].tools, ","), "colony-steel-pickaxe,colony-pickaxe")
    eq(table.concat(l.HUTS["colony-farm-hut"].tools, ","), "colony-steel-hoe,colony-hoe")
    eq(l.best_tool({["colony-steel-axe"] = 1, ["colony-axe"] = 2}, def.tools), "colony-steel-axe")
    eq(l.best_tool({["colony-axe"] = 2}, def.tools), "colony-axe")
    eq(l.best_tool({}, def.tools), nil)
    eq(l.worst_tool({["colony-steel-axe"] = 1, ["colony-axe"] = 2}, def.tools), "colony-axe")
    eq(l.worst_tool({["colony-steel-axe"] = 1}, def.tools), "colony-steel-axe")
    eq(l.worst_tool({}, def.tools), nil)
  end)
  it("sums free slots by job", function()
    local f = l.free_slots({{job = "mine", allowed = 3, workers = 1}, {job = "mine", allowed = 1, workers = 1}, {job = "chop", allowed = 0, workers = 0}})
    eq(f.mine, 2); eq(f.chop, nil)
  end)
  it("sums tooled capacity by job", function()
    local c = l.capacity_by_job({{job = "mine", allowed = 3}, {job = "mine", allowed = 1}, {job = "chop", allowed = 0}})
    eq(c.mine, 4); eq(c.chop, 0)
  end)
  it("spreads a role's workers across its huts, least staffed first", function()
    -- Oldest hut is lowest id, but it must not get a second worker while another hut has none.
    local slots = l.spread({
      {id = 10, job = "mine", allowed = 3, workers = 2},
      {id = 11, job = "mine", allowed = 3, workers = 1},
      {id = 12, job = "mine", allowed = 3, workers = 0},
      {id = 13, job = "mine", allowed = 0, workers = 0},   -- no tools: not a candidate
    })
    eq(#slots, 3)
    eq(slots[1].id, 12); eq(slots[2].id, 11); eq(slots[3].id, 10)
  end)
  it("ignores full huts and breaks ties deterministically by id", function()
    local slots = l.spread({{id = 9, job = "chop", allowed = 2, workers = 0},
      {id = 4, job = "chop", allowed = 2, workers = 0}, {id = 7, job = "chop", allowed = 2, workers = 2}})
    eq(#slots, 2); eq(slots[1].id, 4); eq(slots[2].id, 9)
  end)
  it("spread prioritizes huts with lower building_priority number", function()
    local slots = l.spread({
      {id = 10, job = "mine", allowed = 3, workers = 0, priority = 4},
      {id = 11, job = "mine", allowed = 3, workers = 0, priority = 2},
      {id = 12, job = "mine", allowed = 3, workers = 0, priority = 3},
    })
    eq(#slots, 3)
    eq(slots[1].id, 11); eq(slots[2].id, 12); eq(slots[3].id, 10)
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
  it("includes zero-count resources when include_zero is provided", function()
    local res = ledger.aggregate{
      stock = {},
      huts = {},
      transit = {},
      include_zero = {["iron-ore"] = true, ["copper-ore"] = true},
    }
    eq(#res.items, 2)
    eq(res.items[1].item, "iron-ore")
    eq(res.items[1].total, 0)
    eq(res.items[2].item, "copper-ore")
    eq(res.items[2].total, 0)
  end)
end)

describe("harvest quotas (#84)", function()
  local quota = require("scripts.model.quota")
  it("defaults to 0 (unlimited) when unconfigured, but DEFAULT_QUOTA is 20", function()
    eq(quota.DEFAULT_QUOTA, 20)
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
  it("determines overflow allowance properly", function()
    eq(quota.overflow_allowed(nil, "wood"), true)
    eq(quota.overflow_allowed({}, "iron-ore"), true)
    eq(quota.overflow_allowed({wood = true}, "wood"), true)
    eq(quota.overflow_allowed({wood = false}, "wood"), false)
    eq(quota.overflow_allowed({wood = false}, "iron-ore"), true)
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

describe("advice", function()
  local base = {pop = 4, capacity = 8, food = 20, haul_rank = 1, haulers = 1, houses = 2, hall_stock = {}, tool_gaps = {}}
  local function keys(f) local k = {} for _, a in ipairs(advice.colony(f)) do k[#k + 1] = a.key end return table.concat(k, ",") end
  it("a healthy colony has no blockers", function() eq(keys(base), "") end)
  it("flags starvation, hauling off and missing beds", function()
    eq(keys({pop = 4, capacity = 4, food = 0, haul_rank = 0, haulers = 0, houses = 1, hall_stock = {}}), "haul-off,no-food,no-beds")
  end)
  it("flags a tool the hall cannot supply", function()
    eq(keys({pop = 4, capacity = 8, food = 5, houses = 1, hall_stock = {}, haulers = 1, tool_gaps = {{tool = "colony-axe", short = 2}}}), "no-tool")
    eq(keys({pop = 4, capacity = 8, food = 5, houses = 1, hall_stock = {["colony-axe"] = 3}, haulers = 1, tool_gaps = {{tool = "colony-axe", short = 2}}}), "")
  end)
  it("explains an empty hut", function()
    local hut = {needs_tool = true, tool = "colony-axe", tools = 0, capacity = 3, workers = 0, hall_stock = 0, inflight = 0}
    eq((advice.hut(hut)), "no-tool-in-hall")
    hut.hall_stock = 2; eq((advice.hut(hut)), "tool-waiting")
    hut.inflight = 1; eq((advice.hut(hut)), "tool-coming")
    hut.limit = 0; eq((advice.hut(hut)), "paused")
    eq((advice.hut({needs_tool = true, tools = 2, capacity = 3, workers = 2, sites = 0})), "no-sites")
    eq((advice.hut({needs_tool = true, tools = 0, capacity = 3, workers = 0, sites = 0})), "no-sites")
    -- A hut at its stock limit stands down (even short of a tool), and says which item; an idle Toolsmith says so.
    local r, it = advice.hut({needs_tool = true, tools = 0, capacity = 3, workers = 0, quota_item = "wood"})
    eq(r, "quota-met"); eq(it, "wood")
    eq((advice.hut({capacity = 1, workers = 0, inputs_missing = true, nothing_to_do = true})), "nothing-to-do")
    eq((advice.hut({needs_tool = true, tools = 0, capacity = 3, limit = 0, quota_item = "wood"})), "paused")
    eq(advice.hut({needs_tool = true, tools = 2, capacity = 3, workers = 2, sites = 5}), nil)
  end)
  it("classifies a machine request", function()
    eq(advice.request({have = 10, count = 10}), "stocked")
    eq(advice.request({have = 0, count = 10, inflight = 5}), "delivering")
    eq(advice.request({have = 0, count = 10, stock = 0}), "no-stock")
    eq(advice.request({have = 0, count = 10, stock = 9, haul_rank = 0}), "haul-off")
    eq(advice.request({have = 0, count = 10, stock = 9}), "queued")
  end)
end)

describe("advice: houses and growth", function()
  local needs = {{id = "food", critical = true}, {id = "heat"}}
  it("reports a house by its worst unmet need", function()
    eq(advice.house({needs = needs}), nil)
    eq(advice.house({needs = needs, sat = {}, occupants = 0}).key, "house-empty")
    local r = advice.house({needs = needs, sat = {heat = true}, occupants = 3, hungry = 1, starve_after = 4})
    eq(r.key, "house-starving"); eq(r.level, "red"); eq(r.args[1], "food"); eq(r.args[2], 3)
    eq(advice.house({needs = needs, sat = {food = true}, occupants = 3}).key, "house-lacking")
    eq(advice.house({needs = needs, sat = {food = true, heat = true}, occupants = 3, capacity = 4}).key, "house-ok")
  end)
  it("explains why the town is not growing", function()
    local parts = {food = 0.35, housing = 0.2, scenic = 0.05, leisure = 0.25, pollution = 0, deaths = 0}
    eq(advice.growth({pop = 2, capacity = 4, d = 0.5, parts = parts}).key, "growth-ok")
    eq(advice.growth({pop = 4, capacity = 4, d = 0.5, parts = parts}).key, "growth-no-beds")
    eq(advice.growth({pop = 0, capacity = 0, d = 0.5, parts = parts}).key, "growth-no-houses")
    eq(advice.growth({pop = 2, capacity = 4, d = 0.5, parts = parts, accept = false}).key, "growth-closed")
    local low = advice.growth({pop = 2, capacity = 4, d = 0.1, parts = parts})
    eq(low.key, "growth-low"); eq(low.args[1], "scenic")
    eq(advice.growth({pop = 2, capacity = 4, d = -0.5, parts = {food = 0, pollution = -0.6}}).key, "growth-leaving")
    eq(advice.weakest({food = 0.35, housing = 0.2, scenic = 0.2, leisure = 0.25, pollution = -0.5}), "pollution")
  end)
end)

describe("milestones", function()
  local milestones = require("scripts.model.milestones")
  it("completes the chain in order and never skips", function()
    eq(#milestones.due({halls = 0, pop = 50}, {}), 0)
    local d = milestones.due({halls = 1, pop = 9}, {})
    eq(#d, 1); eq(d[1], "colony-settlement")
    eq(#milestones.due({halls = 1, pop = 9}, {["colony-settlement"] = true}), 0)
  end)
  it("reports the next goal", function()
    local n = milestones.next({halls = 0, pop = 0}, {})
    eq(n.tech, "colony-settlement"); eq(n.need, 1); eq(n.have, 0)
    local all = {}
    for _, m in ipairs(milestones.LIST) do all[m.tech] = true end
    eq(milestones.next({halls = 1, pop = 3}, all), nil)
  end)
end)

describe("toolsmith (tool recipes and the Toolsmith hut)", function()
  local w = require("scripts.model.workshop")
  local t = require("scripts.model.toolsmith")
  it("names the missing ingredient", function()
    eq(w.missing("colony-axe", {wood = 5})["iron-plate"], 3)
    eq(next(w.missing("colony-basket", {wood = 4})), nil)
    eq(w.RECIPES["colony-bow"].wood, 4)
    eq(w.RECIPES["colony-arrow"].wood, 1)
  end)
  it("steel tools cost steel + iron and no wood (#95)", function()
    eq(next(w.missing("colony-steel-axe", {["iron-plate"] = 2, ["steel-plate"] = 1})), nil)
    eq(w.missing("colony-steel-axe", {["iron-plate"] = 2})["steel-plate"], 1)
    eq(w.RECIPES["colony-steel-axe"].wood, nil)
    eq(w.RECIPES["colony-steel-axe"]["steel-plate"], 1)
    eq(w.RECIPES["colony-steel-axe"]["iron-plate"], 2)
    eq(w.RECIPES["colony-steel-pickaxe"]["steel-plate"], 1)
    eq(w.RECIPES["colony-steel-hoe"]["steel-plate"], 1)
  end)
  it("makes the first wanted tool it has the stock and the recipe for", function()
    local wanted = {"colony-axe", "colony-basket"}
    eq(t.pick(wanted, {wood = 10}, {["colony-axe"] = true, ["colony-basket"] = true}), "colony-basket")
    eq(t.pick(wanted, {wood = 10, ["iron-plate"] = 5}, {["colony-axe"] = true}), "colony-axe")
    eq(t.pick(wanted, {wood = 10, ["iron-plate"] = 5}, {}), nil)
    eq(t.pick({}, {wood = 10}, {["colony-basket"] = true}), nil)
  end)
  it("returns the recipe of the tool it picks", function()
    local tool, recipe = t.pick({"colony-axe"}, {wood = 2, ["iron-plate"] = 3}, {["colony-axe"] = true})
    eq(tool, "colony-axe")
    eq(recipe["iron-plate"], 3)
  end)
  it("asks for wood, iron and copper up to its buffer, counting what is there and on the way", function()
    local by = {}
    for _, item in ipairs(t.wants({wood = 3}, {["iron-plate"] = 5})) do by[item.item] = item.count end
    eq(by.wood, 5)
    eq(by["iron-plate"], 7)
    eq(by["copper-plate"], 4)
    eq(by["steel-plate"], nil)  -- no steel wanted -> no steel buffer
    eq(#t.wants({wood = 8, ["iron-plate"] = 12, ["copper-plate"] = 4}, {}), 0)
  end)
  it("buffers steel only while a steel tool is wanted (#95)", function()
    local by = {}
    for _, item in ipairs(t.wants({}, {}, {"colony-steel-axe"})) do by[item.item] = item.count end
    eq(by["steel-plate"], 4)
    eq(by.wood, 8)
    for _, item in ipairs(t.wants({["steel-plate"] = 2}, {["steel-plate"] = 1}, {"colony-steel-hoe"})) do
      if item.item == "steel-plate" then eq(item.count, 1) end
    end
    local by2 = {}
    for _, item in ipairs(t.wants({}, {}, {"colony-axe"})) do by2[item.item] = item.count end
    eq(by2["steel-plate"], nil)
  end)
  it("keeps one spare of each tool a hut uses, once the colony has none of it", function()
    local gaps = {"colony-rod", "colony-axe"}
    local built = {"colony-axe", "colony-basket"}
    local stock = {wood = 20, ["iron-plate"] = 20}
    eq(table.concat(t.wanted(gaps, built, stock), ","), "colony-rod,colony-axe,colony-basket")
    stock["colony-axe"] = 1
    eq(table.concat(t.wanted(gaps, built, stock), ","), "colony-rod,colony-basket")
    eq(#t.wanted({}, built, {wood = 20, ["iron-plate"] = 20, ["colony-axe"] = 1, ["colony-basket"] = 2}), 0)
  end)
  it("respects tool quotas when specified", function()
    local built = {"colony-axe"}
    local stock = {wood = 50, ["iron-plate"] = 50, ["colony-axe"] = 2}
    eq(#t.wanted({}, built, stock), 0)
    local quotas = {["colony-axe"] = 5}
    eq(table.concat(t.wanted({}, built, stock, quotas), ","), "colony-axe")
    stock["colony-axe"] = 5
    eq(#t.wanted({}, built, stock, quotas), 0)
    stock["colony-axe"] = 0
    local quotas_zero = {["colony-axe"] = 0}
    eq(#t.wanted({}, built, stock, quotas_zero), 0)
    eq(table.concat(t.wanted({"colony-axe"}, built, stock, quotas_zero), ","), "colony-axe")
  end)
  it("does not want a tool the colony has no ingredients for", function()
    -- A rifle needs copper: with none in colony stock it is not wanted, so the Toolsmith does not idle on it.
    eq(table.concat(t.wanted({"colony-rifle"}, {"colony-rifle", "colony-rod"}, {wood = 20, ["iron-plate"] = 20}), ","),
      "colony-rod")
    eq(table.concat(t.wanted({"colony-rifle"}, {}, {wood = 20, ["iron-plate"] = 20, ["copper-plate"] = 2}), ","),
      "colony-rifle")
  end)
  it("asks for steel only when tier-1 is covered (#95)", function()
    local stock = {wood = 20, ["iron-plate"] = 20, ["steel-plate"] = 5}
    -- Tier-1 gap exists: steel upgrade suppressed even though stock holds steel.
    eq(table.concat(t.wanted({"colony-axe"}, {"colony-axe", "colony-steel-axe"}, stock), ","),
      "colony-axe")
    -- Tier-1 covered (one in stock): steel is wanted as the upgrade spare.
    stock["colony-axe"] = 1
    eq(table.concat(t.wanted({}, {"colony-axe", "colony-steel-axe"}, stock), ","),
      "colony-steel-axe")
    -- Steel already covered if one is in stock.
    stock["colony-steel-axe"] = 1
    eq(#t.wanted({}, {"colony-axe", "colony-steel-axe"}, stock), 0)
    -- Steel quota is also suppressed while tier-1 is short.
    stock["colony-axe"] = 0
    eq(table.concat(t.wanted({"colony-axe"}, {}, stock, {["colony-steel-axe"] = 3}), ","),
      "colony-axe")
    -- A steel gap itself is never suppressed.
    stock["colony-steel-axe"] = 0
    eq(table.concat(t.wanted({"colony-steel-axe"}, {}, stock), ","),
      "colony-steel-axe")
  end)
  it("takes three work spells per tool", function()
    eq(t.work_ticks(480), 1440)
  end)
  it("says what a short hut is told", function()
    eq(t.gap{toolsmith = false, unlocked = true, missing = {}}, "craft")
    eq(t.gap{toolsmith = true, unlocked = false, missing = {}}, "craft")
    eq(t.gap{toolsmith = true, unlocked = true, missing = {}}, "making")
    local kind, item, n = t.gap{toolsmith = true, unlocked = true, missing = {["iron-plate"] = 3}}
    eq(kind, "short")
    eq(item, "iron-plate")
    eq(n, 3)
  end)
end)

describe("motor pool (#60)", function()
  local motor = require("scripts.model.motor")
  local yields = require("scripts.model.yields")
  local advice = require("scripts.model.advice")
  it("worth_truck starts at one load past a hand carry", function()
    eq(yields.CARRY_CAP, 20)
    eq(motor.MIN_LOAD, 21)
    eq(motor.worth_truck(yields.CARRY_CAP), false)
    eq(motor.worth_truck(21), true)
    eq(motor.worth_truck(nil), false)
  end)
  it("refuel burns the richest fuel first", function()
    local item, trips = motor.refuel({coal = 1, wood = 1, ["solid-fuel"] = 1})
    eq(item, "solid-fuel"); eq(trips, 6)
    item, trips = motor.refuel({coal = 2, wood = 1})
    eq(item, "coal"); eq(trips, 2)
    item, trips = motor.refuel({wood = 3})
    eq(item, "wood"); eq(trips, 1)
    eq(motor.refuel({}), nil)
    eq(motor.refuel({car = 2}), nil)
  end)
  it("fuel_count sums all three fuels", function()
    eq(motor.fuel_count({coal = 2, wood = 3, ["solid-fuel"] = 4}), 9)
    eq(motor.fuel_count({car = 2}), 0)
  end)
  it("can_dispatch needs a car and fuel", function()
    eq(motor.can_dispatch({car = 1, coal = 1}), true)
    eq(motor.can_dispatch({car = 1}), false)
    eq(motor.can_dispatch({coal = 5}), false)
    eq(motor.can_dispatch({}), false)
  end)
  it("wants fuel up to FUEL_STOCK counting contents and inflight", function()
    eq(motor.FUEL_STOCK, 10)
    local d = motor.wants({coal = 4, wood = 2}, {["solid-fuel"] = 1}, {}, 0)
    eq(#d, 1)
    eq(d[1].count, 3)
    eq(#d[1].items, 3)
    eq(d[1].items[1], "solid-fuel"); eq(d[1].items[2], "coal"); eq(d[1].items[3], "wood")
  end)
  it("wants nothing when the pool is full", function()
    eq(#motor.wants({coal = 10, car = 4}, {}, {car = 5}, 0), 0)
  end)
  it("asks for cars only while the colony holds one", function()
    local d = motor.wants({car = 1, coal = 10}, {}, {car = 3}, 0)
    eq(#d, 1)
    eq(d[1].item, "car"); eq(d[1].count, 3)
    eq(#motor.wants({coal = 10}, {}, {}, 0), 0)
  end)
  it("cars on the road count against the car target", function()
    eq(#motor.wants({car = 1, coal = 10}, {}, {car = 3}, 3), 0)
    local d = motor.wants({coal = 10}, {car = 2}, {car = 5}, 0)
    eq(#d, 1)
    eq(d[1].item, "car"); eq(d[1].count, 2)
  end)
  it("KEEP holds cars and every fuel", function()
    truthy(motor.KEEP.car); truthy(motor.KEEP.coal); truthy(motor.KEEP.wood); truthy(motor.KEEP["solid-fuel"])
  end)
  it("advice.pool reports the pool state", function()
    local a = advice.pool({out = 1, cars = 3, fuel = 5})
    eq(a.level, "green"); eq(a.key, "pool-out")
    eq(a.args[1], 1); eq(a.args[2], 3); eq(a.args[3], 5)
    a = advice.pool({out = 0, cars = 0})
    eq(a.level, "amber"); eq(a.key, "pool-no-cars")
    a = advice.pool({out = 0, cars = 2, fuel = 0, tank = 0})
    eq(a.level, "amber"); eq(a.key, "pool-no-fuel")
    a = advice.pool({out = 0, cars = 2, fuel = 0, tank = 1})
    eq(a.level, "green"); eq(a.key, "pool-ready")
    a = advice.pool({out = 0, cars = 2, fuel = 5, tank = 0})
    eq(a.level, "green"); eq(a.key, "pool-ready")
  end)
end)

describe("advice: haul stations and collectors (#94)", function()
  local trailer = require("scripts.model.trailer")
  local well = require("scripts.model.well")
  local salt = require("scripts.model.salt")
  it("a station with trailers out reports the trips, and never goes red", function()
    local a = advice.station{trailers = 2, out = 1, uses_left = 12}
    eq(a.level, "green"); eq(a.key, "station-out")
    eq(a.args[1], 1); eq(a.args[2], 2); eq(a.args[3], 12)
  end)
  it("a station with no trailers says so, but only in amber", function()
    local a = advice.station{trailers = 0, out = 0, uses_left = 0}
    eq(a.level, "amber"); eq(a.key, "station-no-trailers")
  end)
  it("a nearly worn trailer is called out before it breaks", function()
    local a = advice.station{trailers = 3, out = 0, uses_left = advice.STATION_WORN_AT}
    eq(a.level, "amber"); eq(a.key, "station-worn"); eq(a.args[1], advice.STATION_WORN_AT)
    a = advice.station{trailers = 3, out = 0, uses_left = advice.STATION_WORN_AT + 1}
    eq(a.level, "green"); eq(a.key, "station-ready")
    eq(a.args[1], 3); eq(a.args[2], advice.STATION_WORN_AT + 1)
  end)
  it("uses_left follows the trailer wear counter, so a fresh station is never worn", function()
    eq(trailer.uses_left(0), trailer.USES)
    truthy(trailer.uses_left(0) > advice.STATION_WORN_AT)
    for _, wear in ipairs({trailer.USES - 1, trailer.USES - 2, trailer.USES - 3}) do
      eq(advice.station{trailers = 1, out = 0, uses_left = trailer.uses_left(wear)}.key, "station-worn")
    end
    eq(advice.station{trailers = 1, out = 0, uses_left = trailer.uses_left(trailer.USES - 10)}.key, "station-ready")
  end)
  it("a collector reports filling, producing and full in that order", function()
    local a = advice.collector{count = 0, cap = well.CAP, item = well.ITEM}
    eq(a.level, "green"); eq(a.key, "collector-filling"); eq(a.args[2], well.CAP)
    a = advice.collector{count = 5, cap = well.CAP, item = well.ITEM}
    eq(a.level, "green"); eq(a.key, "collector-producing")
    eq(a.args[1], well.ITEM); eq(a.args[2], 5); eq(a.args[3], well.CAP)
    a = advice.collector{count = well.CAP, cap = well.CAP, item = well.ITEM}
    eq(a.level, "amber"); eq(a.key, "collector-full"); eq(a.args[2], well.CAP)
    -- Overshooting the cap (an inserter filling a pan) is still just full, not an error.
    eq(advice.collector{count = salt.CAP + 4, cap = salt.CAP, item = salt.ITEM}.key, "collector-full")
  end)
end)

describe("recreation (#48)", function()
  local recreation = require("scripts.model.recreation")
  local adv = require("scripts.model.advice")
  local des = require("scripts.model.desirability")
  it("a stocked tavern serves the house in range and uses 0.25 ale per resident", function()
    local served, used, owed, cov = recreation.serve({{position = {x = 0, y = 0}, ale = 10}}, {{position = {x = 10, y = 0}, occupants = 4}})
    eq(served[1], 1); eq(used[1], 1); eq(cov, 1)
    truthy(owed[1] ~= nil)
  end)
  it("houses outside RADIUS are not served but count in coverage", function()
    local taverns = {{position = {x = 0, y = 0}, ale = 10}}
    local houses = {{position = {x = 10, y = 0}, occupants = 4}, {position = {x = 30, y = 0}, occupants = 4}}
    local served, used, _, cov = recreation.serve(taverns, houses)
    eq(served[1], 1); eq(served[2], nil); eq(used[1], 1)
    near(cov, 0.5)
  end)
  it("a dry tavern serves nobody", function()
    local served, used, _, cov = recreation.serve({{position = {x = 0, y = 0}, ale = 0}}, {{position = {x = 10, y = 0}, occupants = 4}})
    eq(served[1], nil); eq(used[1], 0); eq(cov, 0)
  end)
  it("the nearest tavern in range serves the house", function()
    local taverns = {{position = {x = 0, y = 0}, ale = 10}, {position = {x = 20, y = 0}, ale = 10}}
    local served, used = recreation.serve(taverns, {{position = {x = 15, y = 0}, occupants = 1}})
    eq(served[1], 2); eq(used[1], 0); eq(used[2], 0)
  end)
  it("fractions of an ale carry over in owed", function()
    local taverns = {{position = {x = 0, y = 0}, ale = 10, owed = 0}}
    local houses = {{position = {x = 10, y = 0}, occupants = 2}}
    local _, used, owed = recreation.serve(taverns, houses)
    eq(used[1], 0); near(owed[1], 0.5)
    taverns[1].owed = owed[1]
    local _, used2, owed2 = recreation.serve(taverns, houses)
    eq(used2[1], 1); near(owed2[1], 0)
  end)
  it("empty houses are ignored and zero residents means zero coverage", function()
    local served, used, _, cov = recreation.serve({{position = {x = 0, y = 0}, ale = 10}}, {{position = {x = 5, y = 0}, occupants = 0}})
    eq(next(served), nil); eq(used[1], 0); eq(cov, 0)
    local _, _, _, cov2 = recreation.serve({{position = {x = 0, y = 0}, ale = 10}}, {{position = {x = 5, y = 0}, occupants = 0}, {position = {x = 5, y = 0}, occupants = 4}})
    eq(cov2, 1)
  end)
  it("work_ticks speeds up inspired colonists by INSPIRED_SPEED", function()
    eq(recreation.work_ticks(480, true), 384)
    eq(recreation.work_ticks(480, false), 480)
  end)
  it("wants asks for ale up to STOCK, counting what is in flight", function()
    local d = recreation.wants(5, 3)
    eq(#d, 1); eq(d[1].item, "colony-ale"); eq(d[1].count, 12)
    eq(#recreation.wants(20, 0), 0)
  end)
  it("advice.tavern reports dry, idle and serving taverns", function()
    local a = adv.tavern({ale = 0})
    eq(a.level, "amber"); eq(a.key, "tavern-dry")
    a = adv.tavern({ale = 5, houses = 0})
    eq(a.level, "amber"); eq(a.key, "tavern-idle"); eq(a.args[1], 5)
    a = adv.tavern({ale = 5, houses = 2, inspired = 8})
    eq(a.level, "green"); eq(a.key, "tavern-serving")
    eq(a.args[1], 2); eq(a.args[2], 8); eq(a.args[3], 5)
  end)
  it("desirability adds exactly w_recreation for a fully served town", function()
    local base = {food_ratio = 1, free_housing_ratio = 0.5, scenic = 0.5, leisure = 0.5, pollution = 0, deaths = {}}
    local with = {food_ratio = 1, free_housing_ratio = 0.5, scenic = 0.5, leisure = 0.5, pollution = 0, deaths = {}, recreation = 1}
    local zero = {food_ratio = 1, free_housing_ratio = 0.5, scenic = 0.5, leisure = 0.5, pollution = 0, deaths = {}, recreation = 0}
    local d1 = des.compute(with)
    local d0 = des.compute(zero)
    near(d1 - d0, des.defaults.w_recreation, 1e-9)
    local _, parts = des.compute(base)
    eq(parts.recreation, 0)
  end)
end)

describe("transit (#49)", function()
  local tr = require("scripts.model.transit")
  it("sends leavers and the homeless only while another colony has room", function()
    eq(tr.departures(3, 2, 0, 10), 5)
    eq(tr.departures(3, 2, 0, 0), 0)            -- nowhere to go: they leave on foot / stay
    eq(tr.departures(3, 2, 4, 6), 2)            -- room is shared with those already waiting
    eq(tr.departures(30, 0, 0, 100), tr.WAIT_CAP)
  end)
  it("lets riders off only away from home, up to the free beds", function()
    local off, left = tr.alight({{from = 1, n = 5, stops = 0}}, 1, 10)
    eq(off, 0); eq(left[1].n, 5); eq(left[1].stops, 1)
    off, left = tr.alight({{from = 1, n = 5, stops = 0}, {from = 2, n = 3, stops = 0}}, 3, 6)
    eq(off, 6); eq(#left, 1); eq(left[1].from, 2); eq(left[1].n, 2)
  end)
  it("brings riders home after RETURN_AFTER stops with nowhere else to go", function()
    local off = tr.alight({{from = 1, n = 2, stops = tr.RETURN_AFTER}}, 1, 5)
    eq(off, 2)
  end)
  it("counts riders and seats", function()
    eq(tr.riders({{n = 3}, {n = 4}}), 7)
    eq(tr.seats({{n = 15}}), tr.SEATS - 15)
    eq(tr.seats({{n = 25}}), 0)
  end)
end)

describe("mortality (#53)", function()
  local mo = require("scripts.model.mortality")
  it("names the killer before the damage type", function()
    eq(mo.cause{cause_type = "locomotive", damage_type = "impact"}, "train")
    eq(mo.cause{cause_type = "cargo-wagon"}, "train")
    eq(mo.cause{cause_type = "car", damage_type = "impact"}, "vehicle")
    eq(mo.cause{cause_type = "unit", enemy = true, damage_type = "physical"}, "enemy")
    eq(mo.cause{damage_type = "fire"}, "fire")
    eq(mo.cause{damage_type = "physical"}, "unknown")
    eq(mo.cause(nil), "unknown")
  end)
  it("buries in the first cemetery with a free plot", function()
    eq(mo.plot({{graves = mo.CEMETERY_PLOTS}, {graves = 3}}), 2)
    eq(mo.plot({{graves = 0}, {graves = 0}}), 1)
    eq(mo.plot({{graves = mo.CEMETERY_PLOTS}}), nil)
    eq(mo.plot({}), nil)
  end)
  it("a cemetery shortens mourning, never lengthens it", function()
    eq(mo.halflife(6, false), 6)
    eq(mo.halflife(6, true), mo.BURIED_HALFLIFE)
    eq(mo.halflife(2, true), 2)
    local _, slow = desirability.compute({food_ratio = 1, free_housing_ratio = 0, deaths = {6}})
    local _, fast = desirability.compute({food_ratio = 1, free_housing_ratio = 0, deaths = {6}, death_halflife = mo.halflife(6, true)})
    eq(math.abs(fast.deaths) < math.abs(slow.deaths), true)
    eq(math.abs(slow.deaths - (-0.075)) < 1e-9, true)
  end)
  it("cemetery tooltip goes amber when full", function()
    eq(advice.cemetery{graves = 3, plots = 12}.key, "cemetery-room")
    eq(advice.cemetery{graves = 12, plots = 12}.level, "amber")
  end)
end)

describe("alarm (#61)", function()
  local al = require("scripts.model.alarm")
  it("merges nearby damage into one alarm and refreshes it", function()
    local alarms = {}
    local a, new = al.raise(alarms, {x = 0, y = 0}, 100, 1)
    eq(new, true); eq(a.ends, 100 + al.CLEAR_TICKS)
    local b, new2 = al.raise(alarms, {x = 10, y = 0}, 200, 2)
    eq(new2, false); eq(b, a); eq(a.ends, 200 + al.CLEAR_TICKS); eq(#alarms, 1)
    local _, new3 = al.raise(alarms, {x = 100, y = 0}, 200, 3)
    eq(new3, true); eq(#alarms, 2)
  end)
  it("covers colonists within the radius only", function()
    local alarms = {{pos = {x = 0, y = 0}, ends = 1}}
    eq(al.covers(alarms, {x = al.RADIUS - 1, y = 0}) ~= nil, true)
    eq(al.covers(alarms, {x = al.RADIUS + 1, y = 0}), nil)
    eq(al.covers(nil, {x = 0, y = 0}), nil)
  end)
  it("keeps an alarm up while enemies are near, clears it after the quiet time", function()
    local alarms = {{pos = {x = 0, y = 0}, ends = 100}}
    local kept, cleared = al.upkeep(alarms, {true}, 500)
    eq(#kept, 1); eq(cleared, 0); eq(kept[1].ends, 500 + al.CLEAR_TICKS)
    kept, cleared = al.upkeep(kept, {false}, 500 + al.CLEAR_TICKS)
    eq(#kept, 0); eq(cleared, 1)
  end)
  it("a quiet nest nearby cannot hold an alarm past HOLD_TICKS after the last hit", function()
    local alarms = {}
    al.raise(alarms, {x = 0, y = 0}, 0, 1)
    local kept = al.upkeep(alarms, {true}, al.HOLD_TICKS - 100)
    eq(kept[1].ends, al.HOLD_TICKS)
    kept = al.upkeep(kept, {true}, al.HOLD_TICKS)
    eq(#kept, 0)
    -- a fresh hit renews it
    alarms = {}
    al.raise(alarms, {x = 0, y = 0}, 0, 1)
    al.raise(alarms, {x = 1, y = 0}, al.HOLD_TICKS - 10, 2)
    eq(#al.upkeep(alarms, {true}, al.HOLD_TICKS + 10), 1)
  end)
  it("runs to the nearest safe shelter, else the one farthest from the threat", function()
    local shelters = {{position = {x = 5, y = 0}}, {position = {x = 40, y = 0}}, {position = {x = -30, y = 0}}}
    -- threat at (10,0): shelter 1 is 5 tiles off it; 2 is 30, 3 is 40: both safe, 3 is nearer to me at (-5,0)
    eq(al.shelter(shelters, {x = -5, y = 0}, {{x = 10, y = 0}}), 3)
    eq(al.shelter(shelters, {x = 35, y = 0}, {{x = 10, y = 0}}), 2)
    -- nothing safe: the farthest from the threat
    eq(al.shelter({{position = {x = 5, y = 0}}, {position = {x = 20, y = 0}}}, {x = 0, y = 0}, {{x = 10, y = 0}}), 2)
    eq(al.shelter({}, {x = 0, y = 0}, {{x = 1, y = 1}}), nil)
  end)
  it("never pulls drivers, passengers or the already sheltering", function()
    eq(al.EXEMPT.driving, true); eq(al.EXEMPT.waiting_train, true); eq(al.EXEMPT.sheltered, true)
    eq(al.EXEMPT.working, nil); eq(al.EXEMPT.exposed, nil)
  end)
end)

describe("commute (#50)", function()
  local cm2 = require("scripts.model.commute")
  local tr = require("scripts.model.transit")
  it("an outpost wants its job slots plus haulers, less who is there or coming", function()
    eq(cm2.deficit(13, 0, 0), math.ceil(13 / (1 - cm2.HAUL_SHARE)))
    eq(cm2.deficit(13, 15, 0), math.max(0, math.ceil(13 / (1 - cm2.HAUL_SHARE)) - 15))
    eq(cm2.deficit(4, 10, 5), 0)
    eq(cm2.deficit(nil, nil, nil), 0)
  end)
  it("sends no more idle colonists than wanted or the platform holds", function()
    eq(cm2.to_send(10, 4, 0, 20), 4)
    eq(cm2.to_send(2, 4, 0, 20), 2)
    eq(cm2.to_send(10, 4, 3, 20), 1)
    eq(cm2.to_send(30, 50, 15, 20), 5)
    eq(cm2.to_send(5, 0, 0, 20), 0)
  end)
  it("a shift ends at night, at its end, or hungry", function()
    eq(cm2.shift_over(100, 200, false, true), false)
    eq(cm2.shift_over(200, 200, false, true), true)
    eq(cm2.shift_over(100, 200, true, true), true)
    eq(cm2.shift_over(100, 200, false, false), true)
  end)
  it("the canteen feeds fractions over time and reports a shortfall", function()
    local take, owed, fed = cm2.eat(10, 3, 0.5, 0)
    eq(take, 1); eq(owed, 0.5); eq(fed, true)
    take, owed, fed = cm2.eat(10, 3, 0.5, owed)
    eq(take, 2); eq(owed, 0); eq(fed, true)
    take, owed, fed = cm2.eat(1, 4, 1, 0)
    eq(take, 1); eq(fed, false); eq(owed, 0)
  end)
  it("asks haulers for any food up to its stock line", function()
    local d = cm2.wants({"a", "b"}, 10, 5)
    eq(d[1].count, cm2.MEALS - 15); eq(#d[1].items, 2)
    eq(#cm2.wants({"a"}, cm2.MEALS, 0), 0)
  end)
  it("commuters get off at an outpost with open slots, never at home on the way out", function()
    local groups = {{from = 1, n = 5, stops = 0, kind = "commute"}, {from = 1, n = 2, stops = 0}}
    local off, left, offs = tr.alight(groups, 1, 10, 10)
    eq(off, 0); eq(#left, 2); eq(left[1].kind, "commute")
    off, left, offs = tr.alight(left, 2, 1, 3)
    eq(off, 4); eq(#offs, 2); eq(offs[1].kind, "commute"); eq(offs[1].n, 3); eq(offs[2].n, 1)
    eq(left[1].n, 2); eq(left[1].kind, "commute"); eq(left[2].n, 1)
  end)
  it("a commute with nowhere to work comes home after RETURN_AFTER stops", function()
    local off, _, offs = tr.alight({{from = 1, n = 3, stops = tr.RETURN_AFTER, kind = "commute"}}, 1, 0, 0)
    eq(off, 3); eq(offs[1].kind, "commute")
  end)
  it("commuters going home get off only at home, beds or not", function()
    local g = {{from = 2, home = 1, n = 4, stops = 0, kind = "return"}}
    local off, left = tr.alight(g, 3, 10, 10)
    eq(off, 0); eq(left[1].home, 1)
    off = tr.alight(left, 1, 0, 0)
    eq(off, 4)
  end)
  it("canteen tooltip", function()
    eq(advice.canteen{meals = 0}.key, "canteen-empty")
    eq(advice.canteen{meals = 5, commuters = 2}.key, "canteen-serving")
    eq(advice.canteen{meals = 5, open = 3}.key, "canteen-idle")
    eq(advice.canteen{meals = 5}.key, "canteen-full")
  end)
end)

describe("illness (#47)", function()
  local il = require("scripts.model.illness")
  it("rolls are deterministic and spread over [0,1)", function()
    eq(il.roll(123, 600, 1), il.roll(123, 600, 1))
    local lo, hi, sum = 1, 0, 0
    for un = 1, 2000 do
      local r = il.roll(un, 600, 1)
      lo, hi, sum = math.min(lo, r), math.max(hi, r), sum + r
    end
    eq(lo >= 0 and hi < 1, true)
    eq(math.abs(sum / 2000 - 0.5) < 0.05, true)
  end)
  it("catches lung in proportion to pollution, never in clean air", function()
    eq(il.catches("lung", 0, 0), false)
    eq(il.catches("lung", 1, il.LUNG_RATE - 0.001), true)
    eq(il.catches("lung", 0.5, il.LUNG_RATE * 0.5 + 0.001), false)
    eq(il.catches("poison", 1, il.POISON_RATE - 0.001), true)
  end)
  it("poisoning passes by itself, the lung kills if untreated", function()
    local p = {kind = "poison", age = 0}
    local out
    for _ = 1, il.DISEASES.poison.recovers_after do out = il.step(p) end
    eq(out, "recovers")
    local l = {kind = "lung", age = 0}
    for _ = 1, il.DISEASES.lung.fatal_after - 1 do eq(il.step(l), nil) end
    eq(il.step(l), "dies")
  end)
  it("cures are limited by patients, doctors and medicine", function()
    eq(il.treat(5, 1, 10), il.CURES_PER_DOCTOR)
    eq(il.treat(1, 2, 10), 1)
    eq(il.treat(5, 2, 1), 1)
    eq(il.treat(5, 0, 10), 0)
  end)
  it("the sick work at half speed", function()
    eq(il.work_ticks(100, true), 200); eq(il.work_ticks(100, false), 100)
  end)
  it("sickness is a desirability penalty", function()
    local _, parts = desirability.compute({food_ratio = 1, free_housing_ratio = 0, sickness = 0.5})
    eq(math.abs(parts.sickness + desirability.defaults.w_sickness * 0.5) < 1e-9, true)
  end)
  it("clinic tooltip: red with sick and no medicine, amber with no doctor", function()
    eq(advice.clinic{sick = 2, medicine = 0}.level, "red")
    eq(advice.clinic{sick = 2, medicine = 3, doctors = 0}.key, "clinic-no-doctor")
    eq(advice.clinic{sick = 2, medicine = 3, doctors = 1}.key, "clinic-treating")
    eq(advice.clinic{sick = 0, medicine = 3}.key, "clinic-idle")
  end)
end)

describe("breeding (#88)", function()
  local breeding = require("scripts.model.breeding")
  local function adult_m() return {sex = "male", stage = "adult"} end
  local function adult_f() return {sex = "female", stage = "adult"} end
  local function child() return {sex = "male", stage = "child"} end

  it("sex is deterministic from the unit number and splits half/half", function()
    eq(breeding.sex_of(1), "male"); eq(breeding.sex_of(2), "female")
    local m, f = 0, 0
    for un = 1, 1000 do if breeding.sex_of(un) == "male" then m = m + 1 else f = f + 1 end end
    near(m, 500, 1); near(f, 500, 1)
  end)
  it("counts adults and children in a house", function()
    local c = breeding.counts({adult_m(), adult_f(), adult_f(), child(), child()})
    eq(c.males, 1); eq(c.females, 2); eq(c.children, 2); eq(c.total, 5); eq(c.adults, 3)
  end)
  it("mouths: children eat half a portion", function()
    local c = breeding.counts({adult_m(), adult_f(), child()})
    near(breeding.mouths(c), 2.5)
  end)
  it("a house needs one adult of each sex, provisions met, a free bed and no cooldown", function()
    local pair = {adult_m(), adult_f()}
    local ok = breeding.eligible(pair, false, 1, 1000, nil)
    truthy(ok)
    local solo = breeding.eligible({adult_m(), adult_m()}, false, 1, 1000, nil)
    truthy(not solo)
    local hungry = breeding.eligible(pair, true, 1, 1000, nil)
    truthy(not hungry, "critical needs unmet blocks a birth")
    local full = breeding.eligible(pair, false, 0, 1000, nil)
    truthy(not full, "no free bed blocks a birth")
    local cooling = breeding.eligible(pair, false, 1, 500, 1000)
    truthy(not cooling, "birth cooldown blocks a birth")
  end)
  it("birth rolls are deterministic per house and tick", function()
    local r1 = breeding.roll(42, 1000, 3)
    local r2 = breeding.roll(42, 1000, 3)
    near(r1, r2)
    truthy(r1 >= 0 and r1 < 1)
    local other = breeding.roll(42, 1001, 3)
    truthy(r1 ~= other)
  end)
end)

describe("supply graph (#90)", function()
  local sg = require("scripts.model.supply_graph")
  local recipes = sg.build({
    {name = "iron-plate", products = {{"iron-plate", 1}}, ingredients = {{"iron-ore", 1}}},
    {name = "copper-plate", products = {{"copper-plate", 1}}, ingredients = {{"copper-ore", 1}}},
    {name = "iron-gear-wheel", products = {{"iron-gear-wheel", 1}}, ingredients = {{"iron-plate", 2}}},
    {name = "copper-cable", products = {{"copper-cable", 2}}, ingredients = {{"copper-plate", 1}}},
    {name = "electronic-circuit", products = {{"electronic-circuit", 1}},
      ingredients = {{"iron-plate", 1}, {"copper-cable", 3}}},
  })
  it("keeps one recipe per product", function()
    truthy(recipes["iron-plate"])
    truthy(recipes["electronic-circuit"])
    local n = 0
    for _ in pairs(recipes) do n = n + 1 end
    eq(n, 5)
  end)
  it("picks the recipe with the fewest ingredient types, ties by name", function()
    local r = sg.build({
      {name = "b-alternate", products = {{"widget", 1}}, ingredients = {{"a", 1}, {"b", 1}, {"c", 1}}},
      {name = "a-base", products = {{"widget", 1}}, ingredients = {{"a", 1}}},
    })
    eq(#r.widget.ingredients, 1)
    eq(r.widget.ingredients[1][1], "a")
  end)
  it("walks demand up one floor per recipe step, damped", function()
    local up = sg.propagate(recipes, {["electronic-circuit"] = 10})
    local d = sg.DAMPING
    near(up["iron-plate"], 10 * 1 * d)                    -- floor 1
    near(up["copper-cable"], 10 * 3 * d)                  -- floor 1
    near(up["copper-plate"], 10 * 3 * d / 2 * d * d)      -- floor 2, and a cable recipe yields 2
    near(up["copper-ore"], 10 * 3 * d / 2 * d * d * d * d * d, 1e-9) -- floor 3
    near(up["iron-ore"], 10 * 1 * d * d * d)              -- floor 2 through the plate
  end)
  it("reports the floors above a seed, and the seed only if a recipe feeds it back", function()
    local up = sg.propagate(recipes, {["iron-plate"] = 10})
    eq(up["iron-plate"], nil, "nothing produces a plate from a plate")
    near(up["iron-ore"], 10 * sg.DAMPING)
    -- Ore demanded in its own right (a crate) still pulls nothing, but a chain that consumes it adds up.
    local both = sg.merge({["iron-ore"] = 20}, sg.propagate(recipes, {["iron-ore"] = 20, ["iron-plate"] = 10}))
    near(both["iron-ore"], 20 + 10 * sg.DAMPING, 1e-9)
  end)
  it("stops at the depth limit and terminates on a cycle", function()
    local cyclic = sg.build({
      {name = "a", products = {{"a", 1}}, ingredients = {{"b", 1}}},
      {name = "b", products = {{"b", 1}}, ingredients = {{"a", 1}}},
    })
    local up = sg.propagate(cyclic, {a = 100})
    truthy(up.b and up.b > 0)
    truthy(up.b < 200, "a cycle stays bounded instead of exploding")
    truthy(up.a and up.a < 100, "a seed fed back through a cycle is damped, not doubled")
    local shallow = sg.propagate(cyclic, {a = 100}, 1)
    near(shallow.b, 100 * sg.DAMPING)
    truthy(shallow.a == nil, "one step only reaches b")
  end)
  it("merges the floors into the direct demand and rounds to whole items", function()
    local merged = sg.whole(sg.merge({["iron-gear-wheel"] = 10}, sg.propagate(recipes, {["iron-gear-wheel"] = 10})))
    eq(merged["iron-gear-wheel"], 10)
    local plate = 10 * 2 * sg.DAMPING
    eq(merged["iron-plate"], math.floor(plate + 0.5))          -- 2 plates per gear
    eq(merged["iron-ore"], math.floor(plate * sg.DAMPING * sg.DAMPING + 0.5))
    for _, v in pairs(merged) do truthy(v == math.floor(v)) end
  end)
  it("ignores seeds with no recipe and zero or negative counts", function()
    eq(next(sg.propagate(recipes, {["raw-fish"] = 10})), nil)
    eq(next(sg.propagate(recipes, {["iron-plate"] = 0, wood = -4})), nil)
    eq(next(sg.propagate(nil, {["iron-plate"] = 10})), nil)
  end)
end)

describe("site picking (#93)", function()
  local sites = require("scripts.model.sites")
  local function node(un, x, y, extra)
    local n = {unit_number = un, position = {x = x, y = y}, valid = true}
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
  end
  local hut = {x = 0, y = 0}

  it("picks the nearest site and breaks exact ties by unit number", function()
    local far = node(9, 10, 0)
    local near_a = node(7, 3, 0)
    local near_b = node(5, 0, 3)
    eq(sites.best({far, near_a, near_b}, hut).unit_number, 5, "same distance: lower unit number wins")
  end)
  it("within the same distance band, prefers the site nearest home", function()
    -- Both within the 8-tile band of the hut; the one by the house wins.
    local away = node(1, 7, 0)
    local by_home = node(2, 0, 5)
    eq(sites.best({away, by_home}, hut, nil, {x = 0, y = 8}).unit_number, 2)
    -- ...the other way round when the house is on the other side.
    eq(sites.best({away, by_home}, hut, nil, {x = 9, y = 0}).unit_number, 1)
  end)
  it("a site in a nearer band always beats a distant one that suits the house", function()
    local by_hut = node(1, 2, 0)     -- band 0
    local by_house = node(2, 30, 0)  -- band 2, right next to home
    eq(sites.best({by_house, by_hut}, hut, nil, {x = 30, y = 1}).unit_number, 1)
  end)
  it("skips invalid candidates and anything the predicate rejects", function()
    local dead = node(1, 1, 0, {valid = false})
    local claimed = node(2, 2, 0)
    local ok = node(3, 9, 0)
    local picked = sites.best({dead, claimed, ok}, hut, function(c) return c.unit_number ~= 2 end)
    eq(picked.unit_number, 3)
    eq(sites.best({dead}, hut), nil)
  end)
  it("is deterministic for the same set in any order", function()
    local a, b, c = node(3, 4, 0), node(1, 4, 0), node(2, 4, 0)
    eq(sites.best({a, b, c}, hut, nil, {x = 0, y = 0}).unit_number, 1)
    eq(sites.best({c, a, b}, hut, nil, {x = 0, y = 0}).unit_number, 1)
  end)
end)

describe("material_priority (#91)", function()
  local mp = require("scripts.model.material_priority")
  it("defaults every rankable material to 3 and enabled", function()
    eq(mp.rank(nil, "iron-ore"), 3)
    eq(mp.rank({}, "iron-ore"), 3)
    eq(mp.enabled(nil, "iron-ore"), true)
    eq(mp.score(nil, "iron-ore"), 3)
    eq(mp.rank(nil, "stone"), 3)
    eq(mp.score(nil, "wood"), 3)
  end)
  it("respects explicit ranks and clamps to 1..5", function()
    local r = {["iron-ore"] = {rank = 1, enabled = true}, ["copper-ore"] = {rank = 5, enabled = true}}
    eq(mp.rank(r, "iron-ore"), 1)
    eq(mp.rank(r, "copper-ore"), 5)
    eq(mp.score(r, "iron-ore"), 1)
    eq(mp.score(r, "copper-ore"), 5)
    local r2 = {}
    mp.shift(r2, "iron-ore", -1)
    eq(mp.rank(r2, "iron-ore"), 2)
    mp.shift(r2, "iron-ore", -3)
    eq(mp.rank(r2, "iron-ore"), 1)
    mp.shift(r2, "iron-ore", 10)
    eq(mp.rank(r2, "iron-ore"), 5)
    mp.shift(r2, "iron-ore", 1)
    eq(mp.rank(r2, "iron-ore"), 5)
  end)
  it("disabled sorts after every enabled material, but does not stop", function()
    local r = {["iron-ore"] = {rank = 1, enabled = false}, ["copper-ore"] = {rank = 5, enabled = true}}
    eq(mp.score(r, "iron-ore"), mp.DISABLED)
    eq(mp.score(r, "copper-ore"), 5)
    eq(mp.enabled(r, "iron-ore"), false)
    eq(mp.mine_rank(r, "iron-ore"), mp.DISABLED)
    eq(mp.rank(r, "iron-ore"), 1, "rank is preserved while disabled")
    mp.set_enabled(r, "iron-ore", true)
    eq(mp.score(r, "iron-ore"), 1)
  end)
  it("knows which items are rankable (quota + intermediates, not tools)", function()
    truthy(mp.is_rankable("iron-ore"))
    truthy(mp.is_rankable("iron-plate"))
    truthy(mp.is_rankable("wood"))
    eq(mp.is_rankable("colony-axe"), false)
    eq(mp.is_rankable("colony-rifle"), false)
    eq(mp.is_rankable("repair-pack"), false)
  end)
  it("best picks the lowest rank, demand breaks ties", function()
    local r = {["iron-ore"] = {rank = 2, enabled = true}, ["copper-ore"] = {rank = 2, enabled = true}}
    local rank, dem = mp.best({"iron-ore", "copper-ore"}, r, {["iron-ore"] = 10, ["copper-ore"] = 20})
    eq(rank, 2); eq(dem, 20)
    -- even demand cannot beat a better rank
    local r2 = {["iron-ore"] = {rank = 1, enabled = true}, ["copper-ore"] = {rank = 2, enabled = true}}
    local rank2, dem2 = mp.best({"iron-ore", "copper-ore"}, r2, {["iron-ore"] = 0, ["copper-ore"] = 100})
    eq(rank2, 1); eq(dem2, 0)
  end)
  it("order sorts most-wanted first, then demand, then RANKABLE order", function()
    local r = {["stone"] = {rank = 1, enabled = true}}
    local rows = mp.order(r, {["stone"] = 0, ["wood"] = 100, ["iron-ore"] = 50})
    eq(rows[1].item, "stone")
    -- stone at 1 beats wood at 3 despite wood having more demand
    eq(rows[2].item, "wood")
    eq(rows[3].item, "iron-ore")
  end)
  it("mine_rank mirrors rank but disabled reads DISABLED (6)", function()
    eq(mp.mine_rank(nil, "iron-ore"), 3)
    local r = {["iron-ore"] = {rank = 2, enabled = true}}
    eq(mp.mine_rank(r, "iron-ore"), 2)
    local r2 = {["iron-ore"] = {rank = 2, enabled = false}}
    eq(mp.mine_rank(r2, "iron-ore"), 6)
  end)
end)

describe("work_plan ranked missing (#91)", function()
  local wp = require("scripts.model.work_plan")
  local function s(t) local b = {pop = 3, counts = {}, slots = {chop = 2, mine = 2, forage = 2}, capacity = {chop = 2, mine = 2, forage = 2}, priority = {haul = 1, forage = 2, chop = 2, mine = 2, farm = 2, hunt = 2, fish = 2}}; for k, v in pairs(t or {}) do b[k] = v end; return b end
  it("staffs the best-ranked missing job first (iron before copper via rank)", function()
    -- ranked list: chop (wood) rank 1, mine rank 5; both missing, counts 0
    local state = s{pop = 3, missing = {{job = "chop", rank = 1, demand = 0}, {job = "mine", rank = 5, demand = 0}}}
    eq(wp.choose(state), "chop")
  end)
  it("prefers demand when material ranks tie", function()
    local state = s{pop = 3, missing = {{job = "chop", rank = 3, demand = 5}, {job = "mine", rank = 3, demand = 50}}}
    eq(wp.choose(state), "mine", "mine has bigger demand at same rank")
  end)
  it("keeps the unstaffed-first rule: an unstaffed low rank still beats doubling a staffed best rank", function()
    -- chop is best ranked and already staffed; mine is worse ranked but unstaffed
    local state = s{pop = 3, counts = {chop = 1, mine = 0}, missing = {{job = "chop", rank = 1, demand = 0}, {job = "mine", rank = 5, demand = 0}}}
    eq(wp.choose(state), "mine")
  end)
  it("doubles up on the best missing rank once every missing role is staffed", function()
    -- forage has no slot here, so once chop and mine are staffed the best missing rank doubles
    local state = s{pop = 3, counts = {chop = 1, mine = 1}, slots = {chop = 2, mine = 2}, capacity = {chop = 2, mine = 2}, missing = {{job = "chop", rank = 1, demand = 0}, {job = "mine", rank = 5, demand = 0}}}
    eq(wp.choose(state), "chop", "best rank doubles, not the worse one")
  end)
  it("ignores missing jobs whose job-matrix rank is worse than the best harvest rank", function()
    -- chop is rank 1 in the job matrix, mine is rank 4; material rank alone cannot pull mine ahead
    local state = s{pop = 3, priority = {haul = 1, forage = 2, chop = 1, mine = 4, farm = 2, hunt = 2, fish = 2}, missing = {{job = "mine", rank = 1, demand = 0}}}
    eq(wp.choose(state), "chop", "job matrix wins over material rank")
  end)
end)

describe("haul_plan material tie-break (#91)", function()
  local hp = require("scripts.model.haul_plan")
  it("order prefers the higher-ranked material within the same band", function()
    local rank_ctx = {ratings = {["iron-ore"] = {rank = 1, enabled = true}, ["copper-ore"] = {rank = 5, enabled = true}}, demand = {}}
    local offers = {
      {priority = hp.PRIORITY.request, building_priority = 3, key = 1, demands = {{item = "copper-ore", count = 10}}},
      {priority = hp.PRIORITY.request, building_priority = 3, key = 2, demands = {{item = "iron-ore", count = 10}}},
    }
    hp.order(offers, rank_ctx)
    eq(offers[1].key, 2, "iron first")
    eq(offers[2].key, 1)
  end)
  it("order without rank_ctx keeps the old deficit order", function()
    local offers = {
      {priority = hp.PRIORITY.request, building_priority = 3, key = 1, deficit = 5, demands = {{item = "copper-ore", count = 5}}},
      {priority = hp.PRIORITY.request, building_priority = 3, key = 2, deficit = 20, demands = {{item = "iron-ore", count = 20}}},
    }
    hp.order(offers)
    eq(offers[1].key, 2, "bigger deficit still wins without ranks")
    local rank_ctx = {ratings = {["iron-ore"] = {rank = 5, enabled = true}, ["copper-ore"] = {rank = 1, enabled = true}}, demand = {}}
    -- re-sort with ranks: copper (rank 1) now beats iron (rank 5) despite smaller deficit
    hp.order(offers, rank_ctx)
    eq(offers[1].key, 1)
  end)
  it("match picks the higher-ranked haul when bands and buildings tie", function()
    local rank_ctx = {ratings = {["iron-ore"] = {rank = 1, enabled = true}, ["copper-ore"] = {rank = 5, enabled = true}}, demand = {}}
    local storage = {key = 99, pos = {x = 0, y = 0}, available = {["iron-ore"] = 20, ["copper-ore"] = 20}, has_space = true}
    local r_iron = {key = 1, priority = hp.PRIORITY.request, building_priority = 3, pos = {x = 10, y = 10}, demands = {{item = "iron-ore", count = 10}}}
    local r_copper = {key = 2, priority = hp.PRIORITY.request, building_priority = 3, pos = {x = 12, y = 10}, demands = {{item = "copper-ore", count = 10}}}
    local task = hp.match({r_iron, r_copper}, {}, {storage}, {}, 20, {x = 0, y = 0}, rank_ctx)
    truthy(task)
    eq(task.load[1].item, "iron-ore")
    eq(task.target.key, 1)
  end)
  it("match without rank_ctx keeps distance order", function()
    local storage = {key = 99, pos = {x = 0, y = 0}, available = {["iron-ore"] = 20, ["copper-ore"] = 20}, has_space = true}
    local near = {key = 1, priority = hp.PRIORITY.request, building_priority = 3, pos = {x = 2, y = 0}, demands = {{item = "copper-ore", count = 10}}}
    local far = {key = 2, priority = hp.PRIORITY.request, building_priority = 3, pos = {x = 40, y = 0}, demands = {{item = "iron-ore", count = 10}}}
    local task = hp.match({near, far}, {}, {storage}, {}, 20, {x = 0, y = 0})
    eq(task.target.key, 1, "near copper still wins without ranks")
  end)
end)

describe("haul station + wooden trailer (#94)", function()
  local trailer = require("scripts.model.trailer")
  it("worth_trailer starts at one load past a hand carry", function()
    eq(trailer.MIN_LOAD, 21)
    eq(trailer.CAPACITY, 60)
    eq(trailer.SPEED, 0.6)
    eq(trailer.USES, 30)
    eq(trailer.worth_trailer(20), false)
    eq(trailer.worth_trailer(21), true)
    eq(trailer.worth_trailer(nil), false)
  end)
  it("nearest picks the closest station in reach holding a trailer", function()
    local stations = {
      {pos = {x = 10, y = 0}, trailers = 1, key = 7},
      {pos = {x = 3, y = 0}, trailers = 1, key = 9},
      {pos = {x = 200, y = 0}, trailers = 1, key = 8},
    }
    eq(trailer.nearest(stations, {x = 0, y = 0}), 2)
    eq(trailer.nearest(stations, {x = -100, y = 0}), nil)
  end)
  it("nearest skips empty stations and breaks ties by key", function()
    local stations = {
      {pos = {x = 5, y = 0}, trailers = 0, key = 1},
      {pos = {x = 5, y = 0}, trailers = 2, key = 3},
      {pos = {x = -5, y = 0}, trailers = 1, key = 2},
    }
    eq(trailer.nearest(stations, {x = 0, y = 0}), 3)
  end)
  it("wear breaks after USES trips like a tool", function()
    local w, broke = trailer.wear(0)
    eq(w, 1); eq(broke, false)
    eq(trailer.uses_left(0), 30)
    eq(trailer.uses_left(29), 1)
    local w2, broke2 = trailer.wear(29)
    eq(w2, 0); eq(broke2, true)
    eq(trailer.uses_left(nil), 30)
  end)
end)
