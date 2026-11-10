-- M1 distance-aware hauling spike (#93): a house that is only being topped up is served straight from the hut
-- beside it, not hauled into the town hall and back out again; and when the load really does come from stock,
-- the hauler picks a source on its way rather than the one nearest the destination. Also shows the commute
-- term landing in desirability once colonists work near home.
-- Run: TICKS=3600 scripts/headless-spike.sh m1_haul_dist
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local work = require("scripts.work")
local haul_plan = require("scripts.model.haul_plan")
local crates = require("scripts.model.crates")

core.register("m1_haul_dist", {
  issue = 93, auto = true, desc = "hauling: local hut -> house top-up, source on the way, commute term", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150

    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not (c and hall and hall.valid) then return ctx.finish() end
    c.accept_migrants = false

    local tower = build("colony-watchtower", {p.x + 44, p.y})
    ctx.check("watchtower extends the territory", tower and tower.valid)

    -- Three tents in a row, a forager hut at the end of them: every house is a short walk from the food.
    local tents = {}
    for i = 0, 2 do tents[i + 1] = build("colony-housing-tent", {p.x + 6 + i * 4, p.y + 4}) end
    local hut = build("colony-forager-hut", {p.x + 20, p.y + 4})
    ctx.check("tents and a forager hut built", tents[1] and tents[1].valid and hut and hut.valid)
    if not (hut and hut.valid) then return ctx.finish() end
    for i = 0, 5 do s.create_entity{name = "colony-forage-patch", position = {p.x + 22 + i, p.y + 8}} end
    hall.insert{name = "colony-basket", count = 3}
    colony.set_quota(c, "colony-forage", 0)     -- 0 = unlimited: the stock we seeded must not stop the hut working

    -- The hall is stocked well away from the houses: if a load comes from there it is a real round trip.
    hall.insert{name = "colony-forage", count = 200}
    for _, t in ipairs(tents) do t.insert{name = "colony-forage", count = 2} end      -- fed, but below the buffer
    hut.insert{name = "colony-forage", count = 10}
    for _ = 1, 3 do colony.spawn_colonist(c) end

    local min_house_dist, max_house_dist = math.huge, 0
    for _, t in ipairs(tents) do
      local d = math.sqrt((t.position.x - hall.position.x) ^ 2 + (t.position.y - hall.position.y) ^ 2)
      min_house_dist, max_house_dist = math.min(min_house_dist, d), math.max(max_house_dist, d)
    end
    ctx.check("the houses stand well away from the hall", min_house_dist > 5, string.format("%.1f tiles", min_house_dist))

    ctx.after(1000, function()
      -- 0. The town has settled: colonists live in the tents and the forager hut is working.
      local mouths = 0
      for _, t in ipairs(tents) do
        if t.valid then mouths = mouths + (c.houses[t.unit_number].occupants or 0) end
      end
      ctx.check("0 the tents are occupied", mouths > 0, mouths .. " colonists housed")
      local hrec = hut.valid and c.huts[hut.unit_number]
      local _, tools_now, allowed, workers = work.hut_info(hrec or {})
      ctx.check("0 the forager hut is staffed", workers > 0, string.format("%d workers, %d baskets, %d allowed",
        workers or -1, tools_now or -1, allowed or -1))

      -- 1. The top-up case: a fed-but-low house and a hut with food beside it.
      for _, t in ipairs(tents) do
        local have = t.get_item_count("colony-forage")
        if have > 0 then t.remove_item{name = "colony-forage", count = have} end
        t.insert{name = "colony-forage", count = 2}          -- fed, but below the reorder line
      end
      if hut.get_item_count("colony-forage") < 4 then hut.insert{name = "colony-forage", count = 60} end
      local task = work.find_haul_task(c, nil, hall.position)
      ctx.check("1 a fed-but-low house wants a top-up", task ~= nil)
      if task then
        ctx.check("1 the load goes straight from the hut to the house (no hall round trip)",
          task.kind == "direct" and task.target and task.target.house ~= nil
            and task.source and task.source.hut ~= nil,
          task.kind .. " -> " .. tostring(task.target and (task.target.house and "house" or task.target.kind)))
        ctx.check("1 the hauler never carries that load into the hall first",
          not (task.target and task.target.entity == hall), "target is the hall")
        ctx.check("1 it is a top-up (request band), not a starvation run",
          task.priority == haul_plan.PRIORITY.request, "priority " .. tostring(task.priority))
        local d_house = math.sqrt((task.target.entity.position.x - task.source.entity.position.x) ^ 2
          + (task.target.entity.position.y - task.source.entity.position.y) ^ 2)
        ctx.check("1 the hut is next door to the house it serves", d_house < 24, string.format("%.1f tiles", d_house))
      end

      -- 2. Drain the hut: now the house can only be served from colony stock, and the task changes shape.
      local have = hut.get_item_count("colony-forage")
      if have > 0 then hut.remove_item{name = "colony-forage", count = have} end
      local task2 = work.find_haul_task(c, nil, hall.position)
      ctx.check("2 with the hut empty the house is served from storage", task2 ~= nil and task2.kind == "supply",
        task2 and task2.kind or "none")
      ctx.check("2 ...from the hall, because that is where the food is", task2 ~= nil and task2.source
        and task2.source.entity == hall, task2 and task2.source and tostring(task2.source.entity.name))
    end)

    -- 3. Source on the way: the hauler stands by one warehouse, the destination crate is beside another.
    -- Picking the source nearest the *destination* would take the second one; the route from the hauler takes
    -- the one it is standing next to, which is the shorter walk.
    local far_warehouse = build("colony-warehouse", {p.x, p.y - 30})
    local near_crate_warehouse = build("colony-warehouse", {p.x + 20, p.y - 30})
    local crate = build("colony-demand-crate", {p.x + 20, p.y - 40})
    ctx.after(1100, function()
      for _, e in ipairs({far_warehouse, near_crate_warehouse}) do
        if e and e.valid then e.insert{name = "wood", count = 50} end
      end
      -- A direct engine insert is invisible to the 30-tick storage snapshot (M.STORAGE_TTL): a hauler would see
      -- the wood on its next assign, but this check asks for a task in the same tick.
      c.storage_cache, c.storage_tick = nil, nil
      ctx.check("3 warehouses and a demand crate built",
        far_warehouse and far_warehouse.valid and near_crate_warehouse and near_crate_warehouse.valid
          and crate and crate.valid)
      if not (crate and crate.valid) then return end
      local rec = c.crates and c.crates[crate.unit_number]
      if rec then
        rec.filters = {}
        crates.set_filter(rec.filters, 1, "wood")
        crates.set_count(rec.filters, 1, 40)
      end
      ctx.check("3 crate demands wood", rec ~= nil and rec.filters[1] ~= nil, tostring(rec ~= nil))
      if not (rec and rec.filters[1]) then return end

      -- Quiet the rest of the town, so the crate is the only thing asking for a haul. Runners-up are real jobs
      -- on the same passes: a hut short of a basket outranks a crate (tools band 2 vs request 4) and is served
      -- from the hall, and a tent being topped up ties the crate on band and wins on deficit. Either would make
      -- this check measure the wrong trip; the rule under test is the source choice for *one* request.
      for _, t in ipairs(tents) do
        if t.valid then
          t.insert{name = "colony-forage", count = 100}
          local trec = c.houses[t.unit_number]
          if trec then trec.stock_tick = nil end
        end
      end
      if hut.valid then
        hut.insert{name = "colony-basket", count = 5}
        local hrec = c.huts[hut.unit_number]
        if hrec then hrec.tool_cache, hrec.tool_tick = nil, nil end
        local grown = hut.get_item_count("colony-forage")
        if grown > 0 then hut.remove_item{name = "colony-forage", count = grown} end
      end

      local hauler = far_warehouse.position
      local function route(e)
        if not (e and e.valid) then return math.huge end
        local a = math.sqrt((e.position.x - hauler.x) ^ 2 + (e.position.y - hauler.y) ^ 2)
        local b = math.sqrt((e.position.x - crate.position.x) ^ 2 + (e.position.y - crate.position.y) ^ 2)
        return a + b
      end
      local task = work.find_haul_task(c, nil, hauler)
      ctx.check("3 the task exists", task ~= nil)
      if task then
        local src = task.source and task.source.entity
        ctx.check("3 the hauler loads on the way, not from the warehouse by the destination",
          src == far_warehouse,
          string.format("source %s (%s -> %s, band %s): route %.1f vs %.1f beside the crate",
            tostring(src and src.name), tostring(task.kind),
            tostring(task.target and task.target.kind or (task.target and task.target.entity and task.target.entity.name)),
            tostring(task.priority), route(src), route(near_crate_warehouse)))
      end

      -- 4. Commute: the workers are all at the hut beside their houses, so the D term is a bonus.
      local workers = 0
      for un, st in pairs(storage.unit_state or {}) do
        if c.colonists[un] and st.hut then workers = workers + 1 end
      end
      ctx.check("4 colonists are working at the nearby hut", workers > 0, workers .. " workers")
      ctx.check("4 a short commute feeds a bonus into desirability",
        c.d_parts ~= nil and (c.d_parts.commute or 0) > 0 and (c.commute or 0) > 0.5,
        string.format("commute %.2f -> %+.3f D", c.commute or -1, c.d_parts and (c.d_parts.commute or 0) or 0))
      ctx.check("4 ...and it is small enough not to flip a bad town",
        (c.d_parts and (c.d_parts.commute or 0) or 0) <= 0.06, tostring(c.d_parts and c.d_parts.commute))
      ctx.finish()
    end)
  end,
})
