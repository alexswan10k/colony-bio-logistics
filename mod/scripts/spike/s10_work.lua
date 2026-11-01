-- SPIKE #10: Script-simulated work: trees, ore, pollution, ghosts.
-- /spike run s10_work    (stand ON/next to an ore patch and near trees)
local core = require("scripts.spike.core")
local events = require("scripts.events")
local S

events.on(defines.events.on_built_entity, function(ev) if S and ev.entity.type == "entity-ghost" then S.ghost_events.built = S.ghost_events.built + 1 end end)
events.on(defines.events.script_raised_built, function(ev) if S and ev.entity.type == "entity-ghost" then S.ghost_events.raised = S.ghost_events.raised + 1 end end)
events.on(defines.events.script_raised_revive, function(ev) if S then S.ghost_events.revive = S.ghost_events.revive + 1 end end)

core.register("s10_work", {
  issue = 10, auto = false, desc = "tree/ore/pollution/ghost script work", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    S = {ghost_events = {built = 0, raised = 0, revive = 0}}
    -- Trees
    local trees = s.find_entities_filtered{position = p, radius = 40, type = "tree", limit = 1}
    if trees[1] then
      local t = trees[1]
      ctx.probe("tree prototype mineable products", function()
        local mp = t.prototype.mineable_properties
        return "mining_time=" .. tostring(mp.mining_time) .. " products=" .. serpent.line(mp.products)
      end)
      ctx.probe("tree.mine{inventory=chest}", function()
        local chest = s.create_entity{name = "wooden-chest", position = {p.x + 1, p.y + 1}, force = "player"}
        local ok = t.mine{inventory = chest.get_inventory(defines.inventory.chest)}
        return tostring(ok) .. " wood in chest=" .. chest.get_inventory(defines.inventory.chest).get_item_count("wood")
      end)
    else ctx.check("trees nearby", false, "stand near trees") end
    -- Ore
    local ores = s.find_entities_filtered{position = p, radius = 40, type = "resource", limit = 20}
    local solid
    for _, o in ipairs(ores) do if not o.prototype.mineable_properties.fluid_amount and not solid then solid = o end end
    if solid then
      local f = game.forces.player
      ctx.probe("ore mineable_properties", function() return serpent.line(solid.prototype.mineable_properties) end)
      ctx.probe("ore prototype infinite_resource / minimum", function() return tostring(solid.prototype.infinite_resource) .. "/" .. tostring(solid.prototype.minimum_resource_amount) end)
      ctx.probe("mining_drill_productivity_bonus", function() return f.mining_drill_productivity_bonus end)
      ctx.probe("decrement ore amount 1:1", function()
        local before = solid.amount; solid.amount = before - 1; return before .. " -> " .. solid.amount
      end)
      ctx.profile("find resources radius 40", function() s.find_entities_filtered{position = p, radius = 40, type = "resource"} end, 50)
    else ctx.check("solid ore nearby", false, "stand on an ore patch") end
    -- Fluid resources
    local fluid = s.find_entities_filtered{position = p, radius = 100, type = "resource"}
    for _, o in ipairs(fluid) do if o.prototype.mineable_properties.fluid_amount then ctx.log("fluid resource present: " .. o.name .. " (must be excluded from colonist mining)") break end end
    -- Pollution
    ctx.probe("pollute(source, amount) + get_pollution", function()
      local before = s.get_pollution(p)
      s.pollute(p, 100)
      return before .. " -> " .. s.get_pollution(p)
    end)
    ctx.probe("pollution_statistics input_counts", function() return serpent.line(s.pollution_statistics.input_counts) end)
    -- Ghosts
    local g = s.create_entity{name = "entity-ghost", inner_name = "iron-chest", position = {p.x + 5, p.y + 5}, force = "player", raise_built = true}
    ctx.check("ghost created", g ~= nil and g.valid)
    ctx.probe("ghost.ghost_prototype.items_to_place_this", function() return serpent.line(g.ghost_prototype.items_to_place_this) end)
    ctx.probe("ghost.revive{raise_revive=true}", function() local a, e = g.revive{raise_revive = true}; return tostring(a) .. " " .. tostring(e and e.name) end)
    ctx.log("ghost events seen:", serpent.line(S.ghost_events))
    ctx.profile("find ghosts radius 64 (what registry avoids)", function() s.find_entities_filtered{position = p, radius = 64, type = "entity-ghost"} end, 50)
    ctx.log("Spike conclusions: registry-based ghost discovery is needed iff find_entities cost above is significant at your scale.")
    ctx.finish()
  end,
})
