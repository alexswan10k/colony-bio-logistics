-- M1 integration test: Town Hall -> territory -> tent -> food -> migrant. Run: scripts/headless-spike.sh m1_colony (TICKS>=2500)
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")

core.register("m1_colony", {
  issue = 28, auto = true, desc = "town hall + housing + migration loop", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(100)
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local far = build("colony-housing-tent", {p.x + 200, p.y})
    ctx.check("tent outside territory rejected", not (far and far.valid))
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    ctx.check("hall claims territory", territory.owner_at(s.index, p) ~= nil)
    local hall2 = build("colony-town-hall", {p.x + 10, p.y})
    ctx.check("overlapping hall rejected", not (hall2 and hall2.valid))
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    ctx.check("tent inside territory kept", tent and tent.valid)
    local c = storage.colonies[territory.owner_at(s.index, p)]
    ctx.check("capacity 4", colony.capacity(c) == 4, colony.capacity(c))
    hall.insert{name = "raw-fish", count = 100}
    for i = 1, 12 do s.create_entity{name = "tree-01", position = {p.x + 12 + i * 2, p.y + 8}} end
    s.create_entity{name = "iron-ore", position = {p.x - 14, p.y - 6}, amount = 500}
    s.create_entity{name = "iron-ore", position = {p.x - 15, p.y - 6}, amount = 500}
    ctx.after(colony.INTERVAL * 6, function()
      local forage, wood, iron = hall.get_item_count("colony-forage"), hall.get_item_count("wood"), hall.get_item_count("iron-ore")
      ctx.log("hall: forage=" .. forage .. " wood=" .. wood .. " iron-ore=" .. iron)
      ctx.check("colonists delivered something", forage + wood + iron > 0)
    end)
    ctx.after(colony.INTERVAL * 6 + 30, function()
      local pop = colony.live_colonists(c)
      ctx.check("migrants arrived (D > threshold)", pop >= 1, "pop=" .. pop .. " D=" .. tostring(c.d))
      ctx.log("food in hall: ", colony.food_in(c))
      ctx.finish()
    end)
  end,
})
