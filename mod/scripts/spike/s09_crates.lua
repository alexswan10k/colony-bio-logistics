-- SPIKE #9: Colony crates vs native logistic network. Do bots service logistic-containers? What does the requester API look like?
-- /spike run s09_crates
-- Builds a powered roboport with 2 logistic robots, a provider chest (iron plate), and a requester chest requesting iron plate.
local core = require("scripts.spike.core")

core.register("s09_crates", {
  issue = 9, auto = true, desc = "logistic-container + bot interop + requester API", usage = "",
  run = function(ctx)
    ctx.flat_area(30)
    local s, p = ctx.surface, ctx.position
    local f = game.forces.player
    ctx.power_at(p)
    local roboport = s.create_entity{name = "roboport", position = {p.x + 8, p.y}, force = f}
    local provider = s.create_entity{name = "passive-provider-chest", position = {p.x + 3, p.y + 6}, force = f}
    local requester = s.create_entity{name = "requester-chest", position = {p.x + 12, p.y + 6}, force = f}
    provider.insert{name = "iron-plate", count = 200}
    ctx.check("entities placed", roboport and provider and requester)
    roboport.insert{name = "logistic-robot", count = 2}
    ctx.probe("requester.get_logistic_sections()", function() return tostring(requester.get_logistic_sections()) end)
    local set = false
    for i, filter in ipairs({
      {value = "iron-plate", min = 50},
      {value = {type = "item", name = "iron-plate", quality = "normal", comparator = "="}, min = 50},
    }) do
      if not set then
        local ok = ctx.probe("set requester filter (variant " .. i .. ")", function()
          local sections = requester.get_logistic_sections()
          local sec = sections.add_section()
          sec.set_slot(1, filter)
          return "ok"
        end)
        set = ok
      end
    end
    ctx.probe("requester.get_requester_point()", function() return tostring(requester.get_requester_point()) end)
    ctx.probe("requester.get_logistic_point()", function() return tostring(requester.get_logistic_point()) end)
    ctx.probe("logistic_network at requester", function() return requester.logistic_network and requester.logistic_network.network_id or "nil" end)
    ctx.after(60 * 30, function()
      local n = requester.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
      ctx.check("bots delivered to a mod-visible requester chest (interop is real/unavoidable)", n > 0, n .. " plates")
      ctx.log("If PASS: using real logistic-containers means bots will service colony crates - decide whether that's a feature.")
      ctx.log("If FAIL on API probes: crates need a custom container + own GUI/filters (plan B).")
      ctx.finish()
    end)
  end,
})
