-- M1 integration test: hall -> territory -> houses (tent+powered cabin) -> hauling -> work -> tools. Run: TICKS=7000 scripts/headless-spike.sh m1_colony
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")

core.register("m1_colony", {
  issue = 28, auto = true, desc = "town hall + housing + hauling + tools", usage = "",
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
    ctx.check("overlapping hall rejected", not (build("colony-town-hall", {p.x + 10, p.y}) or {valid = false}).valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    local cabin_pos = {p.x + 6, p.y + 8}
    ctx.power_at({x = cabin_pos[1], y = cabin_pos[2]})
    local cabin = build("colony-housing-cabin", cabin_pos)
    local forager = build("colony-forager-hut", {p.x - 6, p.y})
    local woodcutter = build("colony-woodcutter-hut", {p.x - 6, p.y + 6})
    local miner = build("colony-miner-hut", {p.x - 6, p.y - 6})
    ctx.check("houses registered", tent and cabin and c.houses[tent.unit_number] and c.houses[cabin.unit_number] ~= nil)
    ctx.check("capacity 10", colony.capacity(c) == 10, colony.capacity(c))
    local furnace = s.create_entity{name = "stone-furnace", position = {p.x - 8, p.y + 12}, force = "player"}
    c.machines[furnace.unit_number] = {entity = furnace, enabled = true, collect = true, inflight = {},
      requests = {{item = "iron-ore", count = 20}, {item = "wood", count = 10}}}
    hall.insert{name = "iron-ore", count = 100}
    hall.insert{name = "raw-fish", count = 100}
    hall.insert{name = "wood", count = 100}
    hall.insert{name = "colony-basket", count = 3}
    hall.insert{name = "colony-axe", count = 3}
    hall.insert{name = "colony-pickaxe", count = 3}
    for i = 1, 12 do s.create_entity{name = "tree-01", position = {p.x + 12 + i * 2, p.y + 8}} end
    s.create_entity{name = "iron-ore", position = {p.x - 14, p.y - 6}, amount = 500}
    s.create_entity{name = "iron-ore", position = {p.x - 15, p.y - 6}, amount = 500}
    ctx.after(colony.INTERVAL * 10, function()
      local tcnt = function(e, i) return e.get_inventory(defines.inventory.chest).get_item_count(i) end
      local th, ch = c.houses[tent.unit_number], c.houses[cabin.unit_number]
      ctx.log(string.format("pop=%d D=%.2f tent: fish=%d wood=%d score=%s | cabin: fish=%d wood=%d score=%s powered=%s",
        colony.live_colonists(c), c.d or 0, tcnt(tent, "raw-fish"), tcnt(tent, "wood"), tostring(th.score),
        tcnt(cabin, "raw-fish"), tcnt(cabin, "wood"), tostring(ch.score), tostring(colony.is_powered(ch))))
      ctx.log("hall: forage=" .. hall.get_item_count("colony-forage") .. " wood=" .. hall.get_item_count("wood") ..
        " iron-ore=" .. hall.get_item_count("iron-ore") .. " axes=" .. hall.get_item_count("colony-axe") ..
        " picks=" .. hall.get_item_count("colony-pickaxe"))
      ctx.check("hauled food to tent", tcnt(tent, "raw-fish") + tcnt(tent, "colony-forage") > 0)
      ctx.check("hauled wood to tent", tcnt(tent, "wood") > 0)
      ctx.check("cabin is powered", colony.is_powered(ch) == true)
      ctx.check("cabin got no wood (power substitutes)", tcnt(cabin, "wood") == 0, tcnt(cabin, "wood"))
      ctx.check("cabin got food", tcnt(cabin, "raw-fish") + tcnt(cabin, "colony-forage") > 0)
      ctx.log("furnace: ore=" .. furnace.get_item_count("iron-ore") .. " plates=" .. furnace.get_item_count("iron-plate") ..
        " hall plates=" .. hall.get_item_count("iron-plate"))
      ctx.check("opt-in furnace supplied and output collected to hall", hall.get_item_count("iron-plate") > 0, hall.get_item_count("iron-plate"))
      ctx.check("tools hauled to huts", hall.get_item_count("colony-axe") < 3 or hall.get_item_count("colony-pickaxe") < 3 or hall.get_item_count("colony-basket") < 3)
      ctx.check("colonists alive", colony.live_colonists(c) >= 1, colony.live_colonists(c))
      ctx.check("hall received resources", hall.get_item_count("iron-ore") + hall.get_item_count("colony-forage") > 0 or hall.get_item_count("wood") > 100)
      ctx.finish()
    end)
  end,
})
