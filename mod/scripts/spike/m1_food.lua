-- M1 bootstrap test: NO food supplied. Colonists must forage and feed themselves. Run: TICKS=9000 scripts/headless-spike.sh m1_food
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")

core.register("m1_food", {
  issue = 28, auto = true, desc = "bootstrap: forage with no starting food", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(100, "grass-1")   -- forage only seeds on natural ground; concrete would have nothing to eat
    storage.interval_override = 600
    local function build(name, pos) return s.create_entity{name = name, position = pos, force = "player", raise_built = true} end
    local hall = build("colony-town-hall", {p.x, p.y})
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    local fhut = build("colony-forager-hut", {p.x - 6, p.y})
    hall.insert{name = "colony-basket", count = 3}
    hall.insert{name = "wood", count = 50}
    local peak, max_forage_seen = 0, 0
    for k = 1, 14 do
      ctx.after(colony.INTERVAL * k, function()
        local pop = colony.live_colonists(c)
        peak = math.max(peak, pop)
        local inv = tent.get_inventory(defines.inventory.chest)
        local cur_forage = hall.get_item_count("colony-forage") + inv.get_item_count("colony-forage")
        max_forage_seen = math.max(max_forage_seen, cur_forage)
        ctx.log(string.format("t=%d pop=%d D=%.2f hall forage=%d tent forage=%d wood=%d hungry=%s", k, pop, c.d or 0,
          hall.get_item_count("colony-forage"), inv.get_item_count("colony-forage"), inv.get_item_count("wood"),
          tostring((c.houses[tent.unit_number] or {}).hungry)))
      end)
    end
    ctx.after(colony.INTERVAL * 14 + 5, function()
      ctx.check("colonists survive without starting food", colony.live_colonists(c) >= 1, "pop=" .. colony.live_colonists(c))
      ctx.check("food was foraged", max_forage_seen > 0, "max_seen=" .. max_forage_seen)
      ctx.finish()
    end)
  end,
})
