-- M2 specialisation spike (#46): the town's spec comes from the huts the player builds there. One
-- forest town (woodcutter + forester), one industrial town (3 miners), one coast town (dock), one
-- farm town (farm hut) - after enough work ticks each colony reports the specialization matching its
-- huts, and bonus() pays the bonus for the right job.
-- Run: TICKS=19500 scripts/headless-spike.sh m2_specialization
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local specialization = require("scripts.model.specialization")

core.register("m2_specialization", {
  issue = 46, auto = true,
  desc = "specialisation: the hut composition of a town names its spec and pays its job bonus",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(160, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    ctx.check("model is a pure module like the others",
      type(specialization.score) == "function" and type(specialization.bonus) == "function"
        and type(specialization.census) == "function")
    ctx.check("bonus table names all four jobs",
      specialization.bonus("coast", "fish") == 1 and specialization.bonus("forest", "chop") == 1
        and specialization.bonus("industrial", "mine") == 1 and specialization.bonus("fertile", "farm") == 1)

    -- ---------- setup: four isolated towns on one long plain, one per specialization ----------
    local hallA = build("colony-town-hall", {p.x - 100, p.y})   -- forest
    local hallB = build("colony-town-hall", {p.x - 34, p.y})    -- industrial
    local hallC = build("colony-town-hall", {p.x + 32, p.y})    -- coast
    local hallD = build("colony-town-hall", {p.x + 98, p.y})    -- fertile
    ctx.check("four halls built", hallA and hallB and hallC and hallD ~= nil)
    local cA = storage.colonies[territory.owner_at(s.index, {x = p.x - 100, y = p.y})]
    local cB = storage.colonies[territory.owner_at(s.index, {x = p.x - 34, y = p.y})]
    local cC = storage.colonies[territory.owner_at(s.index, {x = p.x + 32, y = p.y})]
    local cD = storage.colonies[territory.owner_at(s.index, {x = p.x + 98, y = p.y})]
    ctx.check("four colony records seen", cA and cB and cC and cD ~= nil)
    storage.interval_override = 600

    build("colony-housing-tent", {p.x - 100 + 4, p.y})
    build("colony-housing-tent", {p.x - 34 + 4, p.y})
    build("colony-housing-tent", {p.x + 32 + 4, p.y})
    build("colony-housing-tent", {p.x + 98 + 4, p.y})
    for _ = 1, 6 do colony.spawn_colonist(cA); colony.spawn_colonist(cB); colony.spawn_colonist(cC); colony.spawn_colonist(cD) end

    local woodcutter = build("colony-woodcutter-hut", {p.x - 100 + 8, p.y + 6})
    local forester = build("colony-forester-hut", {p.x - 100 + 8, p.y + 14})
    if woodcutter then woodcutter.insert{name = "colony-axe", count = 2} end
    if forester then forester.insert{name = "colony-spade", count = 2} end
    ctx.check("woodcutter registered", cA and cA.huts[woodcutter.unit_number] ~= nil)
    ctx.check("forester registered", cA and cA.huts[forester.unit_number] ~= nil)

    local miner1 = build("colony-miner-hut", {p.x - 34 + 8, p.y + 6})
    local miner2 = build("colony-miner-hut", {p.x - 34 + 8, p.y + 14})
    local miner3 = build("colony-miner-hut", {p.x - 34 + 8, p.y - 8})
    if miner1 then miner1.insert{name = "colony-pickaxe", count = 2} end
    if miner2 then miner2.insert{name = "colony-pickaxe", count = 2} end
    if miner3 then miner3.insert{name = "colony-pickaxe", count = 2} end
    ctx.check("3 miner huts registered", cB
      and cB.huts[miner1.unit_number] ~= nil and cB.huts[miner2.unit_number] ~= nil
      and cB.huts[miner3.unit_number] ~= nil)

    -- Coast needs water for the dock's shore rule: carve a small pond around town C.
    for dx = -2, 6 do
      for dy = -2, 2 do
        s.set_tiles({{name = "water", position = {p.x + 32 + 12 + dx, p.y + 2 + dy}}}, true)
      end
    end
    for dx = 0, 6 do
      for dy = -6, 6 do
        s.set_tiles({{name = "water", position = {p.x + 32 + 12 + dx, p.y + 2 + dy}}}, true)
      end
    end
    local dock = build("colony-fishing-dock", {p.x + 32 + 12, p.y + 4})
    if dock then dock.insert{name = "colony-rod", count = 2} end
    ctx.check("dock registered", cC and cC.huts[dock.unit_number] ~= nil)

    local farmhut = build("colony-farm-hut", {p.x + 98 + 8, p.y + 6})
    if farmhut then farmhut.insert{name = "colony-hoe", count = 2} end
    ctx.check("farm hut registered", cD and cD.huts[farmhut.unit_number] ~= nil)

    -- Defer the verdict to the end of the run so the colony world has time to evaluate
    ctx.after(15000, function()
      local sa, sb, sc, sd = cA and cA.spec, cB and cB.spec, cC and cC.spec, cD and cD.spec
      ctx.log("parts A=" .. serpent.line(cA and cA.spec_parts))
      ctx.log("parts B=" .. serpent.line(cB and cB.spec_parts))
      ctx.log("parts C=" .. serpent.line(cC and cC.spec_parts))
      ctx.log("parts D=" .. serpent.line(cD and cD.spec_parts))
      ctx.log(string.format("spec A=%s B=%s C=%s D=%s", tostring(sa), tostring(sb), tostring(sc), tostring(sd)))
      ctx.check("town A claimed forest (woodcutter + forester)", sa == "forest", tostring(sa))
      ctx.check("town B claimed industrial (3 miner huts)", sb == "industrial", tostring(sb))
      ctx.check("town C claimed coast (fishing dock)", sc == "coast", tostring(sc))
      ctx.check("town D claimed fertile (farm hut)", sd == "fertile", tostring(sd))
      ctx.finish()
    end)
  end,
})
