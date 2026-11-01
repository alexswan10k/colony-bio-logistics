-- SPIKE #3: script-driven car (hidden character driver) with request_path + riding_state steering.
-- /spike run s03_cars [seconds=30]
-- Measures: can a character driver be set, does riding_state steer, does the car reach a goal around a wall, per-tick cost, stuck.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local S

events.on(defines.events.on_script_path_request_finished, function(ev)
  if not (S and ev.id == S.req) then return end
  if ev.path then
    S.path = ev.path; S.idx = 1
    S.ctx.log("path found, waypoints=" .. #ev.path)
  else
    S.ctx.check("pathfinder found a car path", false, ev.try_again_later and "try_again_later" or "no path")
    S.done = true; S.ctx.finish()
  end
end)

events.on(defines.events.on_tick, function(ev)
  if not (S and S.path and not S.done) then return end
  local p = core.mkprof()
  local car = S.car
  if not car.valid then S.done = true return end
  local wp = S.path[S.idx]
  local pos = car.position
  local dx, dy = wp.position.x - pos.x, wp.position.y - pos.y
  if dx * dx + dy * dy < 16 then
    S.idx = S.idx + 1
    if S.idx > #S.path then
      S.done = true
      car.riding_state = {acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight}
      S.ctx.check("car reached goal", true, "in " .. (ev.tick - S.t0) .. " ticks")
      p.stop(); S.acc.add(p); S.ticks = S.ticks + 1
      S.acc.divide(S.ticks); S.ctx.log({"", "[PROF] steering handler avg/tick: ", S.acc})
      S.ctx.finish()
      return
    end
    wp = S.path[S.idx]; dx, dy = wp.position.x - pos.x, wp.position.y - pos.y
  end
  local desired = (math.atan2(dx, -dy) / (2 * math.pi)) % 1
  local diff = (desired - car.orientation + 0.5) % 1 - 0.5
  local dir = defines.riding.direction.straight
  if diff > 0.01 then dir = defines.riding.direction.right elseif diff < -0.01 then dir = defines.riding.direction.left end
  car.riding_state = {acceleration = defines.riding.acceleration.accelerating, direction = dir}
  -- stuck detection
  if math.abs(car.speed) < 0.001 then S.stuck = S.stuck + 1 else S.stuck = 0 end
  if S.stuck > 180 then
    S.done = true; S.ctx.check("car not stuck", false, "stationary 3s at waypoint " .. S.idx)
    S.ctx.finish()
  end
  p.stop(); S.acc.add(p); S.ticks = S.ticks + 1
  if ev.tick > S.deadline then
    S.done = true; S.ctx.check("car reached goal before timeout", false, "waypoint " .. S.idx .. "/" .. #S.path); S.ctx.finish()
  end
end)

core.register("s03_cars", {
  issue = 3, auto = false, desc = "character-driven car pathing/steering", usage = "[seconds=30]",
  run = function(ctx)
    ctx.flat_area(40)
    local s, p = ctx.surface, ctx.position
    for dy = -10, 7 do s.create_entity{name = "stone-wall", position = {p.x + 20, p.y + dy}, force = "player"} end
    local car = s.create_entity{name = "car", position = p, force = "player"}
    car.get_fuel_inventory().insert{name = "coal", count = 20}
    local char = s.create_entity{name = "character", position = {p.x, p.y - 4}, force = "player"}
    ctx.probe("car.set_driver(character)", function() car.set_driver(char); return car.get_driver() and "seated" or "NOT seated" end)
    local goal = {x = p.x + 38, y = p.y}
    S = {ctx = ctx, car = car, stuck = 0, acc = core.mkprof(), ticks = 0, t0 = game.tick,
         deadline = game.tick + 60 * (tonumber(ctx.args[1]) or 30)}
    S.acc.stop()
    ctx.probe("surface.request_path (car bbox/mask)", function()
      S.req = s.request_path{bounding_box = car.prototype.collision_box, collision_mask = car.prototype.collision_mask,
        start = car.position, goal = goal, force = car.force, radius = 3, can_open_gates = true,
        pathfind_flags = {cache = false, prefer_straight_paths = true}}
      return S.req
    end)
  end,
})
