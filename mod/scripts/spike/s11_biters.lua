-- SPIKE #11: Biter targeting of colonists vs turrets, flee behaviour, pollute() -> evolution.
-- /spike run s11_biters [biters=10] [seconds=20] [flee=0|1]
-- Setup: 2 gun turrets (ammo) + 10 colonists in the middle; biters attack from +40.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local S

events.on(defines.events.on_tick, function(ev)
  if not (S and not S.done) then return end
  if S.flee and ev.tick % 30 == 0 then
    for _, c in ipairs(S.colonists) do
      if c.valid then
        local b = c.surface.find_nearest_enemy{position = c.position, max_distance = 25, force = c.force}
        if b then c.commandable.set_command{type = defines.command.flee, from = b, distraction = defines.distraction.none} end
      end
    end
  end
  if ev.tick >= S.end_tick then
    S.done = true
    local alive, turrets, biters = 0, 0, 0
    for _, c in ipairs(S.colonists) do if c.valid then alive = alive + 1 end end
    for _, t in ipairs(S.turrets) do if t.valid then turrets = turrets + 1 end end
    for _, b in ipairs(S.biters) do if b.valid then biters = biters + 1 end end
    S.ctx.log(string.format("colonists alive %d/%d, turrets alive %d/%d, biters alive %d/%d (flee=%s)",
      alive, #S.colonists, turrets, #S.turrets, biters, #S.biters, tostring(S.flee)))
    S.ctx.check("colonists survive with turret cover", alive >= #S.colonists * 0.7, alive .. "/" .. #S.colonists)
    S.ctx.finish()
  end
end)

core.register("s11_biters", {
  issue = 11, auto = false, desc = "biter vs colonist targeting; pollute->evolution", usage = "[biters=10] [seconds=20] [flee=0|1]",
  run = function(ctx)
    local nb, secs, flee = tonumber(ctx.args[1]) or 10, tonumber(ctx.args[2]) or 20, tonumber(ctx.args[3]) == 1
    ctx.flat_area(60)
    local s, p = ctx.surface, ctx.position
    S = {ctx = ctx, colonists = {}, turrets = {}, biters = {}, flee = flee, end_tick = game.tick + secs * 60}
    for dx = -3, 3, 6 do
      local t = s.create_entity{name = "gun-turret", position = {p.x + dx, p.y + 6}, force = "player"}
      if t then t.insert{name = "firearm-magazine", count = 20}; S.turrets[#S.turrets + 1] = t end
    end
    for i = 1, 10 do
      local c = s.create_entity{name = "colony-colonist", position = {p.x - 4 + i * 0.8, p.y}, force = "player"}
      if c then S.colonists[#S.colonists + 1] = c end
    end
    for i = 1, nb do
      local b = s.create_entity{name = "small-biter", position = {p.x + 40, p.y - 5 + i}, force = "enemy"}
      if b then
        b.commandable.set_command{type = defines.command.attack_area, destination = p, radius = 40, distraction = defines.distraction.by_enemy}
        S.biters[#S.biters + 1] = b
      end
    end
    -- evolution/pollution
    local f = game.forces.enemy
    local ev0, evp0
    ctx.probe("enemy.get_evolution_factor_by_pollution before", function() evp0 = f.get_evolution_factor_by_pollution(s); return evp0 end)
    for _ = 1, 100 do s.pollute{source = p, amount = 10000} end
    ctx.probe("enemy.get_evolution_factor_by_pollution after 1M pollute()", function() return f.get_evolution_factor_by_pollution(s) end)
    ctx.log("Compare: evolution only changes if pollute() counts as production-side pollution. If unchanged, colonist mining won't drive evolution (balance issue).")
  end,
})
