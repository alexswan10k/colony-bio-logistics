-- M4 cross-planet gear (#69): the two late tech tiers and the five endgame unlocks, checked against real
-- Factorio prototypes and a live colony. The pure rules live in model/gear.lua and are covered by unit tests;
-- this spike pins the seams the offline tests cannot: prototype registration, pack costs, the cryo pass
-- reviving a near-spoiled stack, the arcology being a real house, and panacea clearing sickness in the
-- adapter's evaluation. Run: scripts/headless-spike.sh m4_gear
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local cold = require("scripts.cold")
local gear_speed = require("scripts.gear_speed")
local militia = require("scripts.militia")
local armour = require("scripts.model.armour")
local enviro = require("scripts.model.enviro")
local pods = require("scripts.model.pods")
local nursery = require("scripts.model.nursery")
local hydro = require("scripts.model.hydroponics")
local hydroponics = require("scripts.hydroponics")
local eva = require("scripts.model.eva")
local resorts = require("scripts.model.resorts")
local training = require("scripts.model.training")
local science = require("scripts.model.science")
local hotels = require("scripts.model.hotels")
local launch = require("scripts.model.launch")
local gear = require("scripts.model.gear")
local labour = require("scripts.model.labour")
local housing = require("scripts.model.housing")
local tech_mod = require("scripts.tech")

core.register("m4_gear", {
  issue = 69, auto = true,
  desc = "cross-planet gear: Bio-Ecological Data + Sovereignty Codex, tungsten tier, cryo store, arcology, panacea",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(120, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- prototypes ----------
    for _, name in ipairs({"colony-tungsten-pickaxe", "colony-exoskeleton-harness", "colony-panacea-serum",
      "colony-cryo-pod", "colony-nursery", "colony-hydroponics-bay", "colony-eva-airlock", "colony-eva-jetpack",
      "colony-enviro-suit", "colony-heavy-siege-armor", "colony-personal-shield-pack",
      "colony-federation-plating", "colony-federation-vault", "colony-resort", "colony-grand-hotel",
      "colony-space-training-center", "colony-sovereignty-pack", "colony-federation-archive",
      "colony-cryo-warehouse", "colony-fusion-arcology"}) do
      ctx.check(name .. " is a real item", prototypes.item[name] ~= nil)
      ctx.check(name .. " has a recipe", prototypes.recipe[name] ~= nil)
    end
    ctx.check("cryo warehouse and arcology are buildings",
      prototypes.entity["colony-cryo-warehouse"] ~= nil and prototypes.entity["colony-fusion-arcology"] ~= nil)
    ctx.check("arcology is a 4x4 container in the housing replace group",
      prototypes.entity["colony-fusion-arcology"].type == "container"
        and prototypes.entity["colony-fusion-arcology"].fast_replaceable_group == "colony-housing")

    -- The two new tiers pay with Civic Treatises, not Frontier Charters (the §8 gap this closes).
    local f = game.forces.player
    for _, name in ipairs({"colony-bio-ecological-data", "colony-sovereignty-codex"}) do
      local t = f.technologies[name]
      ctx.check(name .. " exists and is researchable", t ~= nil and t.enabled == true)
      local ing = t and t.research_unit_ingredients and t.research_unit_ingredients[1]
      ctx.check(name .. " costs Civic Treatises", ing and ing.name == "colony-civic-pack",
        ing and ing.name or "?")
      ctx.check(name .. " is not researched yet", t ~= nil and t.researched == false)
    end
    local data_prereqs = f.technologies["colony-bio-ecological-data"].prerequisites or {}
    local codex_prereqs = f.technologies["colony-sovereignty-codex"].prerequisites or {}
    ctx.check("codex requires the data tier", codex_prereqs["colony-bio-ecological-data"] ~= nil)
    ctx.check("data tier requires Civic Governance + the bioflux interlock",
      data_prereqs["colony-civic-governance"] ~= nil and data_prereqs["bioflux"] ~= nil)
    local panacea_ing = prototypes.recipe["colony-panacea-serum"].ingredients
    local has_bioflux = false
    for _, i in ipairs(panacea_ing or {}) do if i.name == "bioflux" then has_bioflux = true end end
    ctx.check("panacea is brewed from bioflux, not raw fruit", has_bioflux)

    local federation = f.technologies["colony-interplanetary-federation"]
    local fprereqs = federation and federation.prerequisites or {}
    local fing = federation and federation.research_unit_ingredients and federation.research_unit_ingredients[1]
    ctx.check("the third tier costs Civic Treatises and requires the codex",
      federation ~= nil and fing and fing.name == "colony-civic-pack"
        and fprereqs["colony-sovereignty-codex"] ~= nil)
    local plating_ing = prototypes.recipe["colony-federation-plating"].ingredients
    local consumes_civic = false
    for _, i in ipairs(plating_ing or {}) do if i.name == "colony-civic-pack" then consumes_civic = true end end
    ctx.check("Federation Plating is minted from Civic Treatises", consumes_civic)
    local capstone = f.technologies["colony-transcendent-codex"]
    local cing = capstone and capstone.research_unit_ingredients and capstone.research_unit_ingredients[1]
    ctx.check("the capstone costs Sovereign Codex packs only",
      capstone ~= nil and cing and cing.name == "colony-sovereignty-pack",
      cing and cing.name or "?")
    -- Engine fact pinned by this spike: LuaEntityPrototype does not expose `inputs` at runtime, so lab
    -- coverage is asserted from the model the haulers actually use (science.PACKS_BY_LAB).
    ctx.check("only the Federation Archive studies Sovereign Codex packs",
      #science.PACKS_BY_LAB[science.FEDERATION_ARCHIVE] == 1
        and science.PACKS_BY_LAB[science.FEDERATION_ARCHIVE][1] == science.SOVEREIGNTY_PACK
        and science.PACKS_BY_LAB[science.UNIVERSITY][2] == science.CIVIC_PACK)
    ctx.check("the Federation Archive staffs as a research lab",
      labour.HUTS["colony-federation-archive"] ~= nil
        and labour.HUTS["colony-federation-archive"].job == "research")

    f.technologies["colony-bio-ecological-data"].researched = true
    f.technologies["colony-sovereignty-codex"].researched = true
    federation.researched = true
    tech_mod.sync_force(f)
    ctx.check("the data tier unlocks the personal gear recipes",
      f.recipes["colony-tungsten-pickaxe"].enabled == true
        and f.recipes["colony-exoskeleton-harness"].enabled == true
        and f.recipes["colony-panacea-serum"].enabled == true
        and f.recipes["colony-cryo-pod"].enabled == true
        and f.recipes["colony-pod-refill"].enabled == true
        and f.recipes["colony-nursery"].enabled == true
        and f.recipes["colony-space-training-center"].enabled == true
        and f.recipes["colony-enviro-suit"].enabled == true
        and f.recipes["colony-heavy-siege-armor"].enabled == true
        and f.recipes["colony-personal-shield-pack"].enabled == true)
    ctx.check("the codex unlocks the late buildings",
      f.recipes["colony-cryo-warehouse"].enabled == true and f.recipes["colony-fusion-arcology"].enabled == true
        and f.recipes["colony-hydroponics-bay"].enabled == true
        and f.recipes["colony-eva-airlock"].enabled == true
        and f.recipes["colony-eva-jetpack"].enabled == true
        and f.recipes["colony-federation-plating"].enabled == true
        and f.recipes["colony-federation-vault"].enabled == true
        and f.recipes["colony-grand-hotel"].enabled == true,
      "federation=" .. tostring(f.recipes["colony-federation-vault"].enabled)
        .. " grand=" .. tostring(f.recipes["colony-grand-hotel"].enabled))
    local rail_effects = prototypes.technology["colony-rail-transit"].effects or {}
    local resort_unlocked = false
    for _, e in ipairs(rail_effects) do if e.recipe == "colony-resort" then resort_unlocked = true end end
    ctx.check("the resort rides the existing rail-transit tech", resort_unlocked)

    -- ---------- pure rules through the real modules ----------
    ctx.check("tungsten wear and work spell come from the gear model",
      labour.uses_for("colony-tungsten-pickaxe") == gear.TUNGSTEN_TOOL_USES
        and labour.work_ticks(480, "colony-tungsten-pickaxe") == 312,
      tostring(labour.work_ticks(480, "colony-tungsten-pickaxe")))
    ctx.check("a tungsten pickaxe is the best tool in the miner's ladder",
      labour.best_tool({["colony-pickaxe"] = 2, ["colony-steel-pickaxe"] = 1, ["colony-tungsten-pickaxe"] = 1},
        labour.HUTS["colony-miner-hut"].tools) == "colony-tungsten-pickaxe")
    ctx.check("the arcology is a housing tier with 48 beds",
      housing.TIERS.arcology ~= nil and housing.TIERS.arcology.capacity == 48
        and colony.HOUSES["colony-fusion-arcology"] == "arcology")
    -- Engine fact pinned by this spike: LuaItemPrototype does not expose `spoil_ticks` at runtime, so the
    -- shelf life is asserted from the pure model/constant, not by reading the live prototype.
    ctx.check("a pod's 20-minute timer is its life support",
      pods.SHELF_TICKS == 20 * 60 * 60 and pods.needs_refill(0.6) and not pods.needs_refill(0.2))
    ctx.check("pod refill product always_fresh (2.1 API)",
      prototypes.recipe["colony-pod-refill"].products[1].always_fresh == true)
    ctx.check("the platform launch needs a hub and a centre and packs a pod",
      launch.can_launch(6, 100, nil, true, true) == true
        and launch.can_launch(6, 100, nil, false, true) == false
        and launch.can_launch(4, 100, nil, true, true) == false
        and launch.manifest()[launch.POD_ITEM] == 1)
    ctx.check("a training center needs a minimum town and rations",
      training.pop_ok(4, 100, nil) == false and training.pop_ok(5, 100, nil) == true
        and training.can_launch(6, 100, nil, {["colony-canned-meat"] = 2, ["colony-water"] = 2}) == true
        and training.can_launch(6, 100, nil, {}) == false)
    ctx.check("a Grand Hotel hosts eight and triples insights only when served",
      hotels.CAPACITY == 8 and hotels.premium(2, 2) == true and hotels.premium(1, 2) == false
        and resorts.host_capacity(0, 0, 0, 0, 0, 1) == 8
        and resorts.insights(false, 2, true) == 6)
    ctx.check("a resort hosts four visitors and doubles insights",
      resorts.host_capacity(1, 1, 0, 0, 0) == 6 and resorts.insights(true, 2) == 4
        and resorts.hospitality(true, 2) == 4)
    ctx.check("EVA crew needs an airlock and a jetpack on a platform",
      eva.work_ticks(480, false, false) == 480 and eva.work_ticks(480, true, false) == 240
        and eva.work_ticks(480, true, true) == 480)
    ctx.check("a hydroponics cycle crushes a chunk into food",
      hydro.cycle({["metallic-asteroid-chunk"] = 1}, 0).produce == hydro.FOOD_PER_CYCLE
        and hydro.cycle({}, 0) == nil)
    ctx.check("off-world births need a Nursery and double there",
      nursery.birth_chance(true, false) == 0 and nursery.birth_chance(false, false) == 0.05
        and nursery.birth_chance(true, true) == 0.1)
    ctx.check("an Enviro-Suit lifts the off-world work penalty",
      enviro.work_ticks(480, false, false) == 480 and enviro.work_ticks(480, true, false) == 240
        and enviro.work_ticks(480, true, true) == 480)
    ctx.check("siege armour is the best mitigation and a shield is a flat pool",
      armour.best({[armour.SIEGE] = 1, ["power-armor-mk2"] = 1}) == armour.SIEGE
        and armour.mitigation(armour.SIEGE, "normal") == 0.55
        and armour.mitigation(armour.SHIELD, "legendary") == 0)
    local absorbed, left = armour.shield_drain(armour.SHIELD_CAPACITY, 20)
    ctx.check("a shield drains and recharges by pure rules",
      absorbed == 20 and left == 40 and armour.shield_recharge(0, 100) == 10)

    -- The cryo pass is a separately armed scheduler chain: a pre-#69 save must gain it without resetting
    -- the existing refrigerated chain.
    local scheduled_cryo = false
    for _, bucket in pairs(storage.scheduled or {}) do
      for _, job in ipairs(bucket) do if job.handler == "cold.cryo.tick" then scheduled_cryo = true end end
    end
    ctx.check("the cryo pass is armed on the scheduler", scheduled_cryo)

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    ctx.check("colony registered", c ~= nil)
    local grand = build("colony-grand-hotel", {p.x + 4, p.y + 12})
    ctx.check("grand hotel built and registered", grand and grand.valid and c and c.grand_hotels[grand.unit_number] ~= nil)
    local resort = build("colony-resort", {p.x + 8, p.y + 10})
    ctx.check("resort built and registered", resort and resort.valid and c and c.resorts[resort.unit_number] ~= nil)

    local bay = build("colony-hydroponics-bay", {p.x + 16, p.y + 8})
    ctx.check("hydroponics bay built and registered", bay and bay.valid and c and c.hydroponics[bay.unit_number] ~= nil)
    if bay and bay.valid and c then
      bay.insert{name = "carbonic-asteroid-chunk", count = 1}
      bay.insert{name = "spoilage", count = 3}
      ctx.check("a live hydroponics cycle grew food and recycled spoilage",
        hydroponics.run_colony(c) >= 1 and bay.get_item_count("colony-produce") >= hydro.FOOD_PER_CYCLE,
        "produce=" .. tostring(bay.get_item_count("colony-produce")))
    end
    local defender = militia.spawn(c, {x = p.x + 24, y = p.y}, {armour = armour.SHIELD})
    local dgear = defender and storage.unit_state[defender.unit_number]
      and storage.unit_state[defender.unit_number].gear
    ctx.check("a militia issued a shield starts with a full charge",
      dgear ~= nil and dgear.shield == armour.SHIELD_CAPACITY,
      dgear and tostring(dgear.shield) or "no gear")

    -- Cryo store: restamp a near-spoiled stack; a plain chest beside it must keep decaying.
    local cryo = build("colony-cryo-warehouse", {p.x + 12, p.y + 2})
    ctx.check("cryo warehouse built", cryo and cryo.valid)
    if cryo and cryo.valid then
      cryo.insert{name = "colony-preserved-meat", count = 2}
      local stack = cryo.get_inventory(defines.inventory.chest)[1]
      stack.spoil_tick = game.tick + 1
      ctx.check("cryo stack is near-spoiled before the pass", stack.spoil_percent > 0.99,
        tostring(stack.spoil_percent))
    end
    local control = s.create_entity{name = "iron-chest", position = {p.x + 16, p.y + 2}, force = "player", raise_built = true}
    control.insert{name = "colony-preserved-meat", count = 1}
    local control_stack = control.get_inventory(defines.inventory.chest)[1]
    control_stack.spoil_tick = game.tick + 1
    ctx.check("cryo pass restamped the cryo stack", cold.pause_cryo() >= 1)
    if cryo and cryo.valid then
      ctx.check("cryo stack revived to 0% spoilage",
        cryo.get_inventory(defines.inventory.chest)[1].spoil_percent == 0)
    end
    ctx.check("control chest was NOT revived", control_stack.spoil_percent > 0.99,
      tostring(control_stack.spoil_percent))
    ctx.check("cryo store is ordinary colony stock",
      c ~= nil and c.crates[cryo.unit_number] ~= nil)

    -- Panacea: a sick colonist is cured on the next evaluation and pollution cannot make a new one sick
    -- while the serum sits in the hall.
    local person = colony.spawn_colonist(c)
    ctx.check("colonist spawned", person and person.valid)
    if person and person.valid and c then
      storage.sick = storage.sick or {}
      storage.sick[person.unit_number] = {kind = "lung", age = 3}
      hall.insert{name = "colony-panacea-serum", count = 1}
      c.stock_cache = nil
      c.pollution = 1
      colony.evaluate({colony_id = c.id})   -- the live scheduled path, not a mocked call
      ctx.check("panacea cleared the existing illness", storage.sick[person.unit_number] == nil)
      ctx.check("panacea prevents new illness at full pollution",
        (c.sick_lung or 0) + (c.sick_poison or 0) + (c.sick_swamp_fever or 0) == 0,
        tostring(c.sick_lung) .. "/" .. tostring(c.sick_poison) .. "/" .. tostring(c.sick_swamp_fever))

      -- Exoskeleton: the live unit-speed hook doubles a colonist while a harness sits in stock, and gives
      -- the exact base speed back when the last harness leaves (no permanent stacking).
      local base = person.speed
      ctx.check("colonist has a positive base speed", type(base) == "number" and base > 0, tostring(base))
      hall.insert{name = "colony-exoskeleton-harness", count = 1}
      c.stock_cache = nil
      gear_speed.apply(c)
      ctx.check("exoskeleton doubles live colonist speed", math.abs(person.speed - base * 2) < 1e-6,
        tostring(base) .. " -> " .. tostring(person.speed))
      ctx.check("the speed overlay is durable plain data", storage.gear_speed[person.unit_number] ~= nil)
      hall.remove_item{name = "colony-exoskeleton-harness", count = 1}
      c.stock_cache = nil
      gear_speed.apply(c)
      ctx.check("speed returns to base when the harness is gone", math.abs(person.speed - base) < 1e-6,
        tostring(person.speed))
      ctx.check("the overlay is cleared with the buff", storage.gear_speed[person.unit_number] == nil)
    end

    -- Space Training Center: with a full town and rations, one volunteer is packed into a pod.
    local center = build("colony-space-training-center", {p.x + 8, p.y - 10})
    ctx.check("training center built and registered",
      center and center.valid and c and c.training_centers[center.unit_number] ~= nil)
    if center and center.valid and c then
      for _ = 1, 5 do colony.spawn_colonist(c) end
      hall.insert{name = "colony-canned-meat", count = 4}
      hall.insert{name = "colony-water", count = 4}
      c.stock_cache = nil
      local before = colony.live_colonists(c)
      local pods_before = hall.get_item_count("colony-cryo-pod")
      local launched = colony.launch_training(c)
      ctx.check("a volunteer launched into a fresh pod",
        launched == true and colony.live_colonists(c) == before - 1
          and hall.get_item_count("colony-cryo-pod") == pods_before + 1,
        "pop " .. tostring(before) .. " -> " .. tostring(colony.live_colonists(c)))
    end

    ctx.finish()
  end,
})
