-- M1 desirability spike (#29): the two live inputs (surroundings + pollution) and colonists leaving.
-- Run: TICKS=4000 scripts/headless-spike.sh m1_desirability
-- The pure maths is covered by tests/model_test.lua; this proves the adapter feeds it real world data and
-- that a colony below the leave line actually loses colonists (without the starvation path).
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local desirability = require("scripts.model.desirability")

core.register("m1_desirability", {
  issue = 29, auto = true, desc = "scenic + pollution inputs, migrants in, colonists out", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    -- Before the hall: on_built schedules the first evaluation with the current interval, and the default
    -- is 60 s = 3600 ticks, which would put every check below before the first evaluation.
    storage.interval_override = 150          -- fast evaluations: this spike is about D, not about timing
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not c then return ctx.finish() end

    build("colony-housing-cabin", {p.x + 6, p.y}); ctx.power_at({x = p.x + 6, y = p.y})
    build("colony-housing-cabin", {p.x + 6, p.y + 8}); ctx.power_at({x = p.x + 6, y = p.y + 8})
    hall.insert{name = "raw-fish", count = 400}
    ctx.check("food stocked", hall.get_item_count("raw-fish") >= 400)

    -- Phase 1: a fed, housed colony migrates (#28 already covers this; here it just populates the town).
    local migrated
    ctx.after(1500, function()
      local pop = colony.live_colonists(c)
      migrated = pop
      ctx.check("migrants arrived on a desirable site", pop >= 3, pop)
      ctx.check("D is above the migration line", (c.d or -1) > desirability.defaults.migrate_in,
        string.format("%.2f", c.d or 0))
      ctx.check("nobody leaves a desirable colony", #c.deaths == 0, #c.deaths)
    end)

    -- Phase 2: scenic is sampled from the world - a bare flat area scores 0, planting trees lifts it.
    local before
    ctx.after(1600, function()
      before = c.scenic or 0
      ctx.check("bare ground is not scenic", before < 0.1, string.format("%.2f", before))
      local n = 0
      for i = 0, 299 do
        local a = i * 2.399              -- golden angle: scattered, deterministic, no clumps
        local r = 8 + (i % 20) * 1.5
        local e = s.create_entity{name = "tree-0" .. (i % 5 + 1),
          position = {p.x + math.cos(a) * r, p.y + math.sin(a) * r}, force = "neutral"}
        if e then n = n + 1 end
      end
      ctx.check("trees planted in the scenic box", n > 250, n)
    end)
    ctx.after(2400, function()      -- 4+ evaluations later, so the scenic sample has rerun
      local after = c.scenic or 0
      ctx.check("trees raise scenic", after > before + 0.01, string.format("%.2f -> %.2f", before, after))
      ctx.check("scenic feeds the D components", (c.d_parts or {}).scenic > 0,
        string.format("%.3f", (c.d_parts or {}).scenic or 0))
    end)

    -- Phase 3: pollution is read at the hall and subtracts from D.
    ctx.after(2550, function()
      s.pollute(hall.position, 40000)
      ctx.check("pollution landed in the chunk", s.get_pollution(hall.position) > 0, s.get_pollution(hall.position))
    end)
    ctx.after(2700, function()
      ctx.check("pollution ratio is high", (c.pollution or 0) > 0.9, string.format("%.2f", c.pollution or 0))
      ctx.check("pollution subtracts from D", (c.d_parts or {}).pollution < -0.5,
        string.format("%.2f", (c.d_parts or {}).pollution or 0))
    end)

    -- Phase 4: with food gone and the air foul, D drops under the leave line and colonists pack up. The
    -- window is short enough (3 evaluations) that starvation has not started, so any population loss is
    -- people leaving, not dying.
    local pop_before, deaths_before, left_seen
    ctx.after(2850, function()
      pop_before = colony.live_colonists(c)
      deaths_before = #c.deaths
      local inv = hall.get_inventory(defines.inventory.chest)
      for _, st in ipairs(inv.get_contents()) do inv.remove{name = st.name, count = st.count} end
      ctx.check("hall emptied of food", colony.food_in(c) == 0)
    end)
    ctx.after(3300, function()
      local pop = colony.live_colonists(c)
      left_seen = pop_before - pop
      ctx.check("D fell under the leave line", (c.d or 0) < desirability.defaults.leave_below,
        string.format("%.2f", c.d or 0))
      ctx.check("colonists left", left_seen >= 1, left_seen)
      ctx.check("leaving is not starvation", #c.deaths == deaths_before and pop_before > 0,
        string.format("deaths %d -> %d", deaths_before, #c.deaths))
      local stale, live = 0, 0
      for un, e in pairs(c.colonists) do
        live = live + 1
        if not (e and e.valid) then stale = stale + 1 end
      end
      ctx.check("colonist registry matches reality", stale == 0 and live == pop, stale .. "/" .. live .. " vs " .. pop)
      ctx.check("no job lock left behind", (function()
        for un in pairs(colony.locks or {}) do
          if not (c.colonists[un] and c.colonists[un].valid) then return false end
        end
        return true
      end)())
    end)

    ctx.after(3600, function() ctx.finish() end)
  end,
})
