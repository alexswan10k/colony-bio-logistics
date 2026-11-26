-- Engine probe (#69): a real space platform exposes `damage_tile`/`repair_tile`, and the colony adapter reads
-- `damaged_tiles` on its evaluation cadence (2.1 has no tile-damaged event). This probe pins the engine facts
-- around those calls and the pure task picker; a parked headless platform reports no damaged tiles, so a
-- synthetic damage record from a real foundation tile is used for the picker check.
-- Run: scripts/headless-spike.sh s26_eva_repair
local core = require("scripts.spike.core")
local repair = require("scripts.model.eva_repair")

core.register("s26_eva_repair", {
  issue = 69, auto = true,
  desc = "platform tile damage/repair API and the EVA task picker",
  usage = "",
  run = function(ctx)
    local okp, platform = pcall(function()
      return game.forces.player.create_space_platform{
        name = "s26-eva-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (okp and platform) then
      ctx.check("a space platform can be created headlessly", false, tostring(platform))
      ctx.finish()
      return
    end
    platform.apply_starter_pack()
    local surface = platform.surface
    ctx.check("platform surface is valid", surface ~= nil and surface.valid)

    local origin = platform.hub and platform.hub.position or {x = 0, y = 0}
    local tiles = surface.find_tiles_filtered{name = "space-platform-foundation",
      area = {{origin.x - 10, origin.y - 10}, {origin.x + 10, origin.y + 10}}, limit = 20}
    ctx.check("a real foundation tile is available", #tiles >= 1)
    local pos = tiles[1] and tiles[1].position or {x = math.floor(origin.x), y = math.floor(origin.y)}

    ctx.probe("platform.damage_tile", function()
      platform.damage_tile{position = pos, damage = 1000}
      return "called"
    end)
    ctx.probe("platform.repair_tile", function()
      platform.repair_tile(pos, 1000)
      return "called"
    end)
    ctx.log("damaged_tiles after damage/repair on a parked platform: " .. tostring(#platform.damaged_tiles))

    -- The pure picker works off whatever the platform reports; use a real tile position with a synthetic
    -- damage record so the selection/tie rules are pinned even while the parked platform reports none.
    local synthetic = {{position = pos, damage = 80}, {position = {x = pos.x + 1, y = pos.y}, damage = 20}}
    local task = repair.task(synthetic, pos, 1)
    ctx.check("the pure picker chooses the most damaged tile in airlock range",
      task ~= nil and task.position.x == pos.x and task.spend == 1,
      task and (task.position.x .. "," .. task.position.y) or "nil")
    ctx.check("the pure picker refuses an out-of-range tile",
      repair.task({{position = {x = pos.x + 100, y = pos.y}, damage = 500}}, pos, 5) == nil)
    ctx.check("EVA airlock can be placed on a platform deck",
      prototypes.entity["colony-eva-airlock"].surface_conditions == nil)

    ctx.finish()
  end,
})
