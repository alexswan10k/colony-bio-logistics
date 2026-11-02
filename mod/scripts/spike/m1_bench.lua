-- SPIKE #39: build a synthetic colony at a target scale, then save it so scripts/bench-colony.sh can measure
-- it with `--benchmark`. This is a *load* spike, not a behaviour spike: it reports the sizes it actually
-- managed to build so the benchmark can be read honestly.
-- Usage: m1_bench:500:2000  (colonists, opted-in machines)
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local work = require("scripts.work")

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

core.register("m1_bench", {
  issue = 39, auto = true, desc = "synthetic 500-colonist town for the UPS benchmark", usage = ":pop:machines",
  run = function(ctx)
    local pop = tonumber(ctx.args[1] or "") or 500
    local machine_count = tonumber(ctx.args[2] or "") or 2000
    -- "inert" builds the same entities but registers nothing with the colony: it is the engine-cost
    -- baseline for the same map, so bench-colony.sh can net the colony's own Lua out of the total.
    local inert = ctx.args[3] == "inert"
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(115, "grass-1")            -- cleared square: cabins, huts and the machine field
    local hall = s.create_entity{name = "colony-town-hall", position = p, force = "player", raise_built = true}
    local c = hall and storage.colonies[territory.owner_at(s.index, p)]
    ctx.check("colony created", c ~= nil)
    if not c then return ctx.finish() end

    -- Housing: 6 beds per cabin, stocked so nobody starves while the benchmark runs.
    local cabins = 0
    for i = 0, math.ceil(pop / 6) - 1 do
      local pos = {x = p.x - 45 + (i % 12) * 7, y = p.y - 48 + math.floor(i / 12) * 6}
      local h = s.create_entity{name = "colony-housing-cabin", position = pos, force = "player", raise_built = true}
      if h then
        cabins = cabins + 1
        h.insert{name = "raw-fish", count = 60}
        h.insert{name = "colony-forage", count = 60}
      end
    end
    -- Huts: places for colonists to work, so assignments are not all "idle".
    local huts = 0
    for i = 0, 19 do
      local e = s.create_entity{name = "colony-woodcutter-hut", position = {x = p.x - 45 + i * 5, y = p.y + 16},
        force = "player", raise_built = true}
      if e then huts = huts + 1 end
    end
    -- Machine field: opted-in so the haul planner iterates over them on every assignment.
    local machines = 0
    for row = 0, 60 do
      for col = 0, 60 do
        if machines >= machine_count then break end
        local e = s.create_entity{name = "stone-furnace",
          position = {x = p.x - 61 + col * 2, y = p.y + 30 + row * 2}, force = "player"}
        if e then
          if not inert then colony.set_machine(c, e, true) end
          machines = machines + 1
        end
      end
    end
    -- Colonists, spread on a grid and snapped to a free tile so none of them fail to spawn.
    local spawned = 0
    for i = 0, pop - 1 do
      local at = {x = p.x - 20 + (i % 40), y = p.y - 4 + math.floor(i / 40) * 1.5}
      local pos = s.find_non_colliding_position("colony-colonist", at, 4, 0.25)
      local e = pos and s.create_entity{name = "colony-colonist", position = pos, force = hall.force}
      if e then
        if not inert then
          c.colonists[e.unit_number] = e
          script.register_on_object_destroyed(e)
          work.assign(c, e.unit_number)
        end
        spawned = spawned + 1
      end
    end
    hall.insert{name = "raw-fish", count = 4000}
    hall.insert{name = "wood", count = 4000}
    hall.insert{name = "colony-axe", count = 200}
    hall.insert{name = "colony-hoe", count = 200}

    ctx.log(string.format("built: pop=%d cabins=%d huts=%d machines=%d", spawned, cabins, huts, machines))
    ctx.check("colonists spawned", spawned > 0, spawned)
    ctx.check("machines registered", machines > 0, machines)

    ctx.after(600, function()
      ctx.log(string.format("at save: pop=%d machines=%d scheduled=%d", colony.live_colonists(c),
        machines, count(storage.scheduled)))
      -- server_save only writes in multiplayer (scripts/bench-colony.sh runs a headless server).
      game.server_save(inert and "colony-bench-inert" or "colony-bench")
      ctx.check("benchmark save requested", true)
      ctx.finish()
    end)
  end,
})

return core
