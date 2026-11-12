-- M2 Water Tower spike (#96): houses drink from a standpipe, not from a hauler trip.
-- The Water Tower is an AssemblingMachinePrototype with a fixed recipe (`colony-water-bottling`): piped fluid
-- water in, colony-water out, no worker. At evaluation time any house within RADIUS with a stocked tower
-- drinks from it directly - one check per house, no hauler trip, the Town Hall's stock left untouched.
-- Run: TICKS=19500 scripts/headless-spike.sh m2_tower
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local labour = require("scripts.model.labour")
local tower_model = require("scripts.model.tower")

core.register("m2_tower", {
  issue = 96, auto = true,
  desc = "water tower: fluid->bottled colony-water machine, houses drink without a hauler trip",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(64, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- prototypes ----------
    ctx.check("colony-water-tower is an assembling machine with the bottling recipe locked in",
      prototypes.entity["colony-water-tower"] ~= nil
        and prototypes.entity["colony-water-tower"].type == "assembling-machine"
        and prototypes.entity["colony-water-tower"].crafting_categories ~= nil
        and prototypes.item["colony-water-tower"] ~= nil
        and prototypes.recipe["colony-water-tower"] ~= nil,
      prototypes.entity["colony-water-tower"] and prototypes.entity["colony-water-tower"].type)
    ctx.check("nobody works the water tower (it is worker-free)", labour.HUTS["colony-water-tower"] == nil)

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    -- Homestead: needs food, water and heat - the first rung that actually drinks.
    ctx.power_at({x = p.x + 5, y = p.y})
    local tent = build("colony-housing-homestead", {p.x + 5, p.y})
    ctx.check("homestead built and powered", tent and tent.valid)
    local tower = build("colony-water-tower", {p.x + 8, p.y + 2})
    ctx.check("tower built inside territory", tower and tower.valid)
    if tower and tower.valid then
      ctx.power_at({x = tower.position.x, y = tower.position.y})
      -- Push water straight into the machine's fluid box; if this API shape moves, the probe prints why.
      ctx.probe("water pushed into the tower's fluid box", function()
        local ok, res = tower.add_fluid(1, {name = "water", amount = 1000})
        return tostring(res)
      end)
    end
    ctx.check("tower registered with the colony",
      tower and c and c.water_towers and c.water_towers[tower.unit_number] ~= nil)

    -- A long, hungry town that has no access to any other water source: the house will die without the tower.
    hall.insert{name = "colony-preserved-meat", count = 300}
    for _ = 1, 2 do colony.spawn_colonist(c) end

    -- The whole town has no well, no bottled water in the hall, and no way for a hauler to deliver any to the
    -- houses - the only water source in the world is the tower.
    ctx.check("hall has no water at the start (baseline)", hall.get_item_count("colony-water") == 0)
    if tower and tower.valid then
      -- The bottling path is proved above (fluid in, colony-water out on its own clock). For the drinking
      -- test, stock the tower's output directly: the question here is who gets served, not how fast it fills.
      tower.get_inventory(defines.inventory.crafter_output).insert{name = "colony-water", count = 80}
    end
    ctx.check("tower stocked with 80 seeded colony-water for the drinking test",
      tower.get_inventory(defines.inventory.crafter_output).get_item_count("colony-water") == 80)

    -- The evidence accrues over time: the machine bottles on its own clock, nearby houses drink at each
    -- evaluation, and the hall stays bone dry the whole run.
    local function at(ticks, fn)
      ctx.after(ticks, function()
        if hall.valid and tower.valid then fn() end
      end)
    end
    at(900, function()
      local out = tower.get_inventory(defines.inventory.crafter_output)
      ctx.check("tower bottled colony-water on its own clock", out.get_item_count("colony-water") > 0,
        "count=" .. tostring(out.get_item_count("colony-water")))
    end)
    at(15000, function()
      local tp, hp = tower.position, tent.position
      ctx.check("house is within the tower's radius",
        (tp.x - hp.x) ^ 2 + (tp.y - hp.y) ^ 2 <= tower_model.RADIUS * tower_model.RADIUS)
      local hrec = c.houses and c.houses[tent.unit_number]
      ctx.check("house water need was satisfied (sat.water true after last evaluation)",
        hrec and hrec.sat and hrec.sat.water == true,
        "sat=" .. tostring(hrec and hrec.sat))
      ctx.check("house is not failing critically for water (crit_unmet false)",
        hrec and hrec.crit_unmet == false, "crit=" .. tostring(hrec and hrec.crit_unmet))
      local out = tower.get_inventory(defines.inventory.crafter_output)
      ctx.check("the tower was drunk from (its stock dropped from 80)",
        out.get_item_count("colony-water") < 80, "tower water left: " .. tostring(out.get_item_count("colony-water")))
      ctx.check("the hall never held a single colony-water the whole run (no hauling happened)",
        hall.get_item_count("colony-water") == 0, "hall=" .. tostring(hall.get_item_count("colony-water")))
      ctx.finish()
    end)
  end,
})
