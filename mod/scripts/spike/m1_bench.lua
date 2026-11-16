-- SPIKE #39: build a synthetic colony at a target scale, then save it so scripts/bench-colony.sh can measure
-- it with `--benchmark`. This is a *load* spike, not a behaviour spike: it reports the sizes it actually
-- managed to build so the benchmark can be read honestly.
-- Usage: m1_bench:500:2000[:mode]  (colonists, opted-in machines, mode)
--   ""       working town: trees, ore and forage planted, quotas unlimited, hall stocked with tools
--   inert    the same entities, nothing registered with the colony (the engine-cost control)
--   demand   the working town, and every machine also asks for ore
--   idle     the town with no work sites at all - the degenerate measurement the gate used to report
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local work = require("scripts.work")
local forest = require("scripts.model.forest")
local stats = require("scripts.stats")

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- Ticks the town works before it is saved. The benchmark must read a staffed town with tools delivered and
-- trips under way, not the warm-up where every colonist is still walking out to its first site.
local WARMUP = 3600

-- Quota 0 = unlimited (#54). A hut must never stop working because the town already happens to hold twenty
-- wood: the bench wants work forever, and a met quota is the fastest way to make it measure nothing.
local SITE_ITEMS = {"wood", "iron-ore", "copper-ore", "coal", "stone", "colony-forage"}
local ORES = {"iron-ore", "copper-ore", "coal", "stone"}

-- The bench town was degenerate until the #22 re-baseline: `flat_area` clears every tree, ore and forage off
-- its square, so no hut ever found a site, every assignment ended in `work.idle` and the gate measured retry
-- churn in a town with nothing to do. Plant real work instead, in the bands the buildings do not use.
-- Everything is inside the hut's own radius (48 for harvest, 96 for forage), or it would be scenery.
local function plant_sites(s, p)
  local trees, ores, patches = 0, 0, 0
  local function tree(x, y)
    if s.create_entity{name = forest.TREE, position = {x = x, y = y}, force = "neutral"} then
      trees = trees + 1
    end
  end
  -- Forest west and east of the hut line, clear of the cabins (x -46.5..+33.5) and close enough that a
  -- woodcutter finishes a round trip inside the warm-up: 7 tiles to the nearest trunk, not 21.
  for x = p.x - 100, p.x - 52, 4 do
    for y = p.y - 24, p.y + 56, 4 do tree(x, y) end
  end
  for x = p.x + 54, p.x + 100, 4 do
    for y = p.y - 24, p.y + 56, 4 do tree(x, y) end
  end
  -- One bed per ore between the huts (y +16) and the furnace field (y +30), so every miner has all four ores
  -- in range and the ore-priority ordering runs instead of short-circuiting on the first one it finds.
  for i, ore in ipairs(ORES) do
    for col = 0, 12 do
      for row = 0, 4 do
        local e = s.create_entity{name = ore, amount = 100000,
          position = {x = p.x - 52 + (i - 1) * 27 + col * 2, y = p.y + 20 + row * 2}}
        if e then ores = ores + 1 end
      end
    end
  end
  -- Forage patches east of the huts. They regrow in place after a harvest, so unlike the forest they cannot
  -- be worked out from under a forager during a run.
  for x = p.x + 20, p.x + 110, 6 do
    for y = p.y - 54, p.y + 58, 6 do
      if s.create_entity{name = "colony-forage-patch", position = {x = x, y = y}, force = "neutral"} then
        patches = patches + 1
      end
    end
  end
  return trees, ores, patches
end

core.register("m1_bench", {
  issue = 39, auto = true, desc = "synthetic 500-colonist working town for the UPS benchmark", usage = ":pop:machines:mode",
  run = function(ctx)
    local pop = tonumber(ctx.args[1] or "") or 500
    local machine_count = tonumber(ctx.args[2] or "") or 2000
    -- "inert" builds the same entities but registers nothing with the colony: it is the engine-cost
    -- baseline for the same map, so bench-colony.sh can net the colony's own Lua out of the total.
    -- "demand" also gives every machine a request, which is the realistic case (a furnace wants ore) and
    -- exercises the demand half of the machine index instead of just the collect half.
    -- "idle" skips the work sites, reproducing the old degenerate town so the gate can still report it.
    local mode = ctx.args[3] or ""
    local inert, demand = mode == "inert", mode == "demand"
    local sites = mode ~= "idle"
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
    -- Bulk stock (#33): harvested goods land in the warehouses instead of filling the hall, so hauling keeps
    -- flowing for the whole run instead of stalling once the hall's 48 slots are taken.
    local warehouses = 0
    for i = 0, 1 do
      local e = s.create_entity{name = "colony-warehouse", position = {x = p.x - 12 + i * 8, y = p.y - 8},
        force = "player", raise_built = true}
      if e then warehouses = warehouses + 1 end
    end
    -- Huts: real places to work, split by job so the harness exercises chop, mine and forage rather than one
    -- job that is capped by its share of the workforce.
    local huts = 0
    for i = 1, 20 do
      local name = i <= 8 and "colony-woodcutter-hut"
        or (i <= 14 and "colony-miner-hut" or "colony-forager-hut")
      local e = s.create_entity{name = name, position = {x = p.x - 45 + (i - 1) * 5, y = p.y + 16},
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
          if not inert then
            colony.set_machine(c, e, true)
            if demand then c.machines[e.unit_number].requests = {{item = "iron-ore", count = 20}} end
          end
          machines = machines + 1
        end
      end
    end
    local trees, ores, patches = 0, 0, 0
    if sites then trees, ores, patches = plant_sites(s, p) end
    for _, item in ipairs(SITE_ITEMS) do colony.set_quota(c, item, 0) end
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
    -- Stocked so the town neither starves nor is left without tools, and *not* so full that harvested goods
    -- have nowhere to go. The hall used to be over-filled (4000 fish + 4000 wood wanted 80 of its 48 slots),
    -- which silently dropped the tools and left every hut waiting for equipment that never arrived.
    hall.insert{name = "raw-fish", count = 1200}
    hall.insert{name = "colony-forage", count = 300}
    hall.insert{name = "wood", count = 800}
    hall.insert{name = "colony-axe", count = 60}
    hall.insert{name = "colony-pickaxe", count = 60}
    hall.insert{name = "colony-basket", count = 60}

    ctx.log(string.format("built: pop=%d cabins=%d huts=%d machines=%d warehouses=%d sites=%d trees/%d ore/%d forage",
      spawned, cabins, huts, machines, warehouses, trees, ores, patches))
    ctx.check("colonists spawned", spawned > 0, spawned)
    ctx.check("machines registered", machines > 0, machines)

    ctx.after(WARMUP, function()
      -- The colony records every harvest through stats.produced (#89), so its own accounting is the honest
      -- answer to "did this town actually work" - no guessing from chest contents that hauling has moved.
      local st = stats.stats(hall.force, s)
      local function made(item)
        local n = st and st.get_input_count(item)   -- 2.1 flow-statistics methods are bound: no explicit self
        return (n and tonumber(n)) or 0
      end
      local wood, ore, forage = made("wood"), 0, made("colony-forage")
      for _, o in ipairs(ORES) do ore = ore + made(o) end
      local chop_axes, chop_sites, chop_workers = 0, 0, 0
      for _, h in pairs(c.huts or {}) do
        if h.job == "chop" then
          chop_axes = chop_axes + (h.entity.get_item_count("colony-axe") or 0)
          chop_sites = chop_sites + work.site_count(h)
          for _ in pairs(h.workers or {}) do chop_workers = chop_workers + 1 end
        end
      end
      ctx.log(string.format("at save: pop=%d machines=%d scheduled=%d harvested=%d wood/%d ore/%d forage axes=%d sites=%d workers=%d",
        colony.live_colonists(c), machines, count(storage.scheduled), wood, ore, forage, chop_axes, chop_sites, chop_workers))
      -- The guard that stops this bench going degenerate again: with sites planted, the town must harvest.
      if sites and not inert then
        ctx.check("woodcutters felled trees", wood > 0, wood)
        ctx.check("miners dug ore", ore > 0, ore)
        ctx.check("foragers picked patches", forage > 0, forage)
      end
      -- server_save only writes in multiplayer (scripts/bench-colony.sh runs a headless server).
      game.server_save(mode == "" and "colony-bench" or ("colony-bench-" .. mode))
      ctx.check("benchmark save requested", true)
      ctx.finish()
    end)
  end,
})

return core
