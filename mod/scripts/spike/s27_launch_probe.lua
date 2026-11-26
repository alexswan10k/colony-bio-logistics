-- Engine probe (#69): the exact character-in-platform launch path. A Space Platform Hub can create a cargo
-- pod, a real `character` can ride it as a passenger, and setting a non-invalid `cargo_pod_destination`
-- launches it. The colony's colonists are `unit` entities, so this probe pins the facts needed to swap one
-- for a character before boarding. Run: scripts/headless-spike.sh s27_launch_probe
local core = require("scripts.spike.core")
local events = require("scripts.events")

core.register("s27_launch_probe", {
  issue = 69, auto = true,
  desc = "platform hub cargo pod + character passenger + launch destination",
  usage = "",
  run = function(ctx)
    local okp, platform = pcall(function()
      return game.forces.player.create_space_platform{
        name = "s27-launch-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (okp and platform) then
      ctx.check("platform created", false, tostring(platform)); ctx.finish(); return
    end
    platform.apply_starter_pack()
    local surface, hub = platform.surface, platform.hub
    ctx.check("hub exists after starter pack", hub ~= nil and hub.valid)

    local pod = nil
    ctx.probe("hub.create_cargo_pod", function()
      pod = hub and hub.create_cargo_pod()
      return pod and pod.valid or "nil"
    end)
    ctx.check("a cargo pod was created", pod ~= nil and pod.valid)

    local pos = surface.find_non_colliding_position("character", hub.position, 6, 0.5)
    local rider = pos and surface.create_entity{name = "character", position = pos, force = "player"}
    ctx.check("a real character was placed on the deck", rider ~= nil and rider.valid)

    if pod and pod.valid and rider and rider.valid then
      ctx.probe("pod.set_passenger(character)", function()
        pod.set_passenger(rider)
        return pod.get_passenger() == rider
      end)
      ctx.check("the character is riding the pod", pod.get_passenger() == rider)
      ctx.probe("pod.cargo_pod_destination = surface", function()
        pod.cargo_pod_destination = {type = defines.cargo_destination.surface,
          surface = game.surfaces[1].index, position = {x = 0, y = 0}}
        return pod.cargo_pod_state
      end)
      -- Engine fact: a destination change does NOT flip cargo_pod_state inside the same script tick; the
      -- ascent begins on the next tick and raises on_cargo_pod_started_ascending there.
      ctx.check("the pod still reports awaiting_launch until the next tick",
        pod.cargo_pod_state == "awaiting_launch", tostring(pod and pod.cargo_pod_state))
    end

    local started = 0
    events.on(defines.events.on_cargo_pod_started_ascending, function(ev)
      started = started + 1
      ctx.log("pod ascending: " .. tostring(ev.cargo_pod and ev.cargo_pod.unit_number))
    end)
    ctx.after(300, function()
      ctx.log("ascending events seen: " .. tostring(started))
      ctx.check("the engine started the ascent on a later tick", started >= 1)
      ctx.finish()
    end)
  end,
})
