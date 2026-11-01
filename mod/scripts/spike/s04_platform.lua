-- SPIKE #4: Colonist units on a space platform.
-- /spike run s04_platform
-- Creates a platform via starter pack, spawns a colonist on foundation, tests walking on / off foundation, reads surface properties.
local core = require("scripts.spike.core")

core.register("s04_platform", {
  issue = 4, auto = false, desc = "units on space platform surface", usage = "",
  run = function(ctx)
    local force = game.forces.player
    local ok, platform = ctx.probe("force.create_space_platform", function()
      return force.create_space_platform{name = "spike-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (ok and platform) then ctx.finish() return end
    ctx.probe("platform.apply_starter_pack", function() return platform.apply_starter_pack() ~= nil end)
    ctx.after(90, function()
      local surface = platform.surface
      ctx.check("platform surface valid", surface and surface.valid)
      if not (surface and surface.valid) then ctx.finish() return end
      local counts = {}
      for _, t in pairs(surface.find_tiles_filtered{area = {{-40, -40}, {40, 40}}}) do counts[t.name] = (counts[t.name] or 0) + 1 end
      for n, c in pairs(counts) do ctx.log("tile", n, c) end
      ctx.probe("surface.platform ~= nil", function() return surface.platform ~= nil end)
      for _, prop in ipairs({"pressure", "gravity", "magnetic-field", "solar-power", "temperature"}) do
        ctx.probe("surface.get_property(" .. prop .. ")", function() return surface.get_property(prop) end)
      end
      ctx.probe("platform.hub", function() return platform.hub and platform.hub.position.x .. "," .. platform.hub.position.y end)
      local hub = platform.hub
      local origin = hub and hub.position or {x = 0, y = 0}
      local pos
      ctx.probe("find_non_colliding_position for colony-colonist near hub", function()
        pos = surface.find_non_colliding_position("colony-colonist", {origin.x, origin.y + 6}, 15, 0.5)
        return pos and (pos.x .. "," .. pos.y) or "nil (no valid spot!)"
      end)
      if not pos then ctx.finish() return end
      local unit
      ctx.probe("create_entity colony-colonist on platform", function()
        unit = surface.create_entity{name = "colony-colonist", position = pos, force = "player"}
        return unit and unit.unit_number
      end)
      if not unit then ctx.finish() return end
      -- walk 60 tiles toward empty space beyond the platform
      unit.commandable.set_command{type = defines.command.go_to_location, destination = {pos.x + 60, pos.y},
        radius = 1, distraction = defines.distraction.none}
      ctx.probe("request_path on platform", function()
        return surface.request_path{bounding_box = unit.prototype.collision_box, collision_mask = unit.prototype.collision_mask,
          start = pos, goal = {pos.x + 10, pos.y}, force = unit.force, radius = 1, pathfind_flags = {cache = false}} ~= nil
      end)
      ctx.after(60 * 15, function()
        if unit.valid then
          local tile = surface.get_tile(unit.position)
          ctx.log("after 15s unit at", unit.position.x, unit.position.y, "tile=", tile.name, "health=", unit.health)
          ctx.check("unit stayed on foundation (did not walk into space)", tile.name:find("platform") ~= nil, tile.name)
        else
          ctx.check("unit survived on platform", false, "unit became invalid (killed/removed)")
        end
        ctx.log("Also try manually: send platform out; does the unit survive transit / chunk unloading?")
        ctx.finish()
      end)
    end)
  end,
})
