-- SPIKE: why do migrants stall? Flat area, hall, fast evaluations, stocked hall; log pop and D over time.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")

core.register("m1_migrant", {
  issue = 88, auto = true, desc = "migration pacing probe", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(60, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    storage.interval_override = 600
    local hall = s.create_entity{name = "colony-town-hall", position = {p.x, p.y}, force = "player", raise_built = true}
    s.create_entity{name = "colony-housing-cabin", position = {p.x + 6, p.y}, force = "player", raise_built = true}
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not c then return ctx.finish() end
    hall.insert{name = "raw-fish", count = 400}
    for i = 1, 35 do
      ctx.after(600 * i, function()
        ctx.log(string.format("t=%d pop=%d d=%.2f away=%s cap=%s next_mig=%s food=%d",
          game.tick, colony.live_colonists(c), c.d or -1, tostring(c.away or 0), tostring(colony.capacity(c)),
          tostring(c.next_migrant), colony.total_food(c)))
      end)
    end
    ctx.after(21500, function() ctx.finish() end)
  end,
})
