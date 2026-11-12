-- M1 forestry spike (#97): chopping was a one-way drain on the colony's own territory, so a Forester's Hut
-- replants the trees a woodcutter fells. The hut spends one wood out of its own chest per tree, has to be
-- supplied (an empty chest closes its slots and reports a supply problem), plants only on soil and never within
-- SPACING of a standing tree, and a woodcutter gets the tree back later. Daytime is frozen so night cannot stop
-- the work. Run: TICKS=9000 scripts/headless-spike.sh m1_forest
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local feedback = require("scripts.feedback")
local work = require("scripts.work")
local labour = require("scripts.model.labour")
local forest = require("scripts.model.forest")
local territory = require("scripts.territory")

core.register("m1_forest", {
  issue = 97, auto = true,
  desc = "forester hut: replants felled forest with hut wood, spacing + soil respected, spade wears, woodcutter recuts",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")   -- bare grass: every tree seen after this was planted by the hut
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    for i = 0, 3 do build("colony-housing-cabin", {p.x - 12 + i * 8, p.y - 9}) end
    hall.insert{name = "raw-fish", count = 400}
    c.accept_migrants = false
    for _ = 1, 4 do colony.spawn_colonist(c) end

    -- ---------- the rules, before anyone walks ----------
    local def = labour.HUTS["colony-forester-hut"]
    ctx.check("forester hut is a labour hut on the forest job", def ~= nil and def.job == "forest")
    ctx.check("it holds two foresters", def ~= nil and def.capacity == 2)
    ctx.check("it needs a spade", def ~= nil and def.tool == "colony-spade")
    ctx.check("wood in its chest is input, not output", def ~= nil and def.keep ~= nil and def.keep[1] == "wood")
    ctx.check("it asks haulers for wood", def ~= nil and def.inputs ~= nil and def.inputs[1] ~= nil
      and def.inputs[1].item == "wood")
    ctx.check("it is supply-gated on wood", def ~= nil and def.requires ~= nil and def.requires[1] == "wood")
    ctx.check("one tree costs one wood", forest.SAPLING_COST == 1)
    ctx.check("a planted tree is worth 4 wood to a woodcutter", forest.WOOD_PER_TREE == 4, forest.WOOD_PER_TREE)
    ctx.check("forestry nets 3 wood per tree over the sapling", forest.net_wood() == 3, forest.net_wood())
    ctx.check("grass is plantable", forest.plantable("grass-1") == true)
    ctx.check("dirt is plantable", forest.plantable("dirt-2") == true)
    ctx.check("concrete is not plantable", forest.plantable("refined-concrete") == false)
    ctx.check("water is not plantable", forest.plantable("water") == false)
    ctx.check("sand is not plantable", forest.plantable("sand-1") == false)
    local tree_name = forest.tree(function(name) return prototypes.entity[name] ~= nil end)
    ctx.check("a tree prototype resolves in game", tree_name ~= nil, tostring(tree_name))
    local cands = forest.candidates({x = 0, y = 0}, forest.RADIUS)
    local on_lattice, nearest_first, in_radius = true, true, true
    local last_d2 = -1
    for _, spot in ipairs(cands) do
      if (spot.x - 0.5) % 4 ~= 0 or (spot.y - 0.5) % 4 ~= 0 then on_lattice = false end
      if spot.d2 < last_d2 then nearest_first = false end
      last_d2 = spot.d2
      if spot.d2 > forest.RADIUS * forest.RADIUS then in_radius = false end
    end
    ctx.check("planting spots sit on the shared 4-tile lattice", on_lattice and #cands > 0, #cands .. " spots")
    ctx.check("planting spots are nearest-first", nearest_first)
    ctx.check("no planting spot is outside the hut's radius", in_radius)

    -- ---------- the hut in the world ----------
    local hut = build("colony-forester-hut", {p.x + 12, p.y + 4})
    ctx.check("forester hut built inside territory", hut and hut.valid)
    if not (hut and hut.valid) then return ctx.finish() end
    local h = c.huts[hut.unit_number]
    ctx.check("forester hut registered as a labour hut", h ~= nil and h.job == "forest")
    if not h then return ctx.finish() end
    ctx.check("the nursery is inside the colony's land", territory.owner_at(c.surface_index, hut.position) == c.id,
      tostring(territory.owner_at(c.surface_index, hut.position)))

    -- Empty chest: the hut must not look busy. It closes its slots and its status line names the missing supply.
    ctx.check("an unsupplied forester hut reports no site to plant", work.site_count(h) == nil)

    -- Stock it the way a hauler would: wood to plant with, and two spades.
    hut.insert{name = "wood", count = 12}
    hut.insert{name = "colony-spade", count = 2}
    ctx.check("hut holds 12 wood and 2 spades", hut.get_item_count("wood") == 12
      and hut.get_item_count("colony-spade") == 2)
    local sites = work.site_count(h)
    ctx.check("a supplied forester hut sees somewhere to plant", (sites or 0) > 0, sites)

    -- Two foresters only; the other two stay free so the town has someone to haul with.
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    c.locks[ids[1]], c.locks[ids[2]] = "forest", "forest"
    colony.reassign_workforce(c)

    local watch = {
      planted_at = nil,     -- tick the first tree appeared
      trees_max = 0,
      wood_min = 12,
      trips = 0,            -- planting trips completed
      plant_trees = 0,      -- trees standing at the end of the planting phase
      chopped = nil,        -- trees left once the woodcutter started
      furthest = 0,         -- furthest planting spot from the hut
      bad_soil = 0,
      bad_spacing = 0,
      off_lattice = 0,
      cutter = nil,
      chop_from = nil,
      wood_before_chop = 0,
    }
    local function trees_around(r)
      local out = {}
      for _, t in ipairs(s.find_entities_filtered{area = {{hut.position.x - r, hut.position.y - r},
          {hut.position.x + r, hut.position.y + r}}, type = "tree"}) do
        if t.valid then out[#out + 1] = t end
      end
      return out
    end
    local function audit(trees)
      watch.bad_soil, watch.bad_spacing, watch.off_lattice = 0, 0, 0
      watch.furthest = 0
      for i, t in ipairs(trees) do
        if not forest.plantable(s.get_tile(t.position).name) then watch.bad_soil = watch.bad_soil + 1 end
        if (t.position.x - 0.5) % 4 ~= 0 or (t.position.y - 0.5) % 4 ~= 0 then watch.off_lattice = watch.off_lattice + 1 end
        local dx, dy = t.position.x - hut.position.x, t.position.y - hut.position.y
        watch.furthest = math.max(watch.furthest, math.sqrt(dx * dx + dy * dy))
        for j = i + 1, #trees do
          local u = trees[j]
          local ddx, ddy = u.position.x - t.position.x, u.position.y - t.position.y
          if ddx * ddx + ddy * ddy < forest.SPACING * forest.SPACING then watch.bad_spacing = watch.bad_spacing + 1 end
        end
      end
    end
    local function wood_held()
      return hut.get_item_count("wood")
        + (watch.cutter and watch.cutter.valid and watch.cutter.get_item_count("wood") or 0)
        + hall.get_item_count("wood")
    end

    local phase = "plant"
    local phase_end = game.tick + 4600
    local function poll()
      if not (hut.valid and h) then return end
      local n = #trees_around(forest.RADIUS + 8)
      if n > watch.trees_max then watch.trees_max = n end
      if n > 0 and not watch.planted_at then watch.planted_at = game.tick end
      watch.wood_min = math.min(watch.wood_min, hut.get_item_count("wood"))
      for un in pairs(c.colonists) do
        local st = storage.unit_state[un]
        if st and st.job == "forest" then watch.trips = watch.trips + 1 end
      end
      if phase == "chop" and watch.chopped == nil and n < watch.plant_trees then watch.chopped = n end
      if phase == "plant" and game.tick >= phase_end then
        phase = "audit"
        watch.plant_trees = n
        audit(trees_around(forest.RADIUS + 8))
        ctx.check("the forester planted trees", n >= 2, n .. " trees")
        ctx.check("planting happened within the hut's own radius", watch.furthest <= forest.RADIUS + 0.01,
          string.format("%.1f max (radius %d)", watch.furthest, forest.RADIUS))
        ctx.check("every tree stands on plantable soil", watch.bad_soil == 0, watch.bad_soil .. " on bad soil")
        ctx.check("no two trees are closer than the spacing", watch.bad_spacing == 0, watch.bad_spacing .. " too close")
        ctx.check("every tree is on the shared lattice", watch.off_lattice == 0, watch.off_lattice .. " off lattice")
        ctx.check("the hut paid wood for what it planted", hut.get_item_count("wood") < 12,
          hut.get_item_count("wood") .. " of 12 wood left")
        ctx.check("the spade wore with the planting", (h.wear or 0) > 0, "wear " .. tostring(h.wear))
        ctx.check("a planter plants from outside the sapling", (work.PLANT_REACH or 0) > 0,
          "reach " .. tostring(work.PLANT_REACH))
        -- A woodcutter now gets the same trees back: build the lodge beside the nursery and let it work.
        local cutter = build("colony-woodcutter-hut", {p.x + 24, p.y - 6})
        ctx.check("woodcutter hut built next to the nursery", cutter and cutter.valid)
        if cutter and cutter.valid then
          cutter.insert{name = "colony-axe", count = 1}
          c.locks[ids[3]] = "chop"
          colony.reassign_workforce(c)
          watch.cutter = cutter
          watch.chop_from = game.tick
          watch.wood_before_chop = wood_held()
          phase = "chop"
        end
      end
    end
    -- Poll on the spike's own timer, not every tick: one scan a second is all the audit needs.
    local function every()
      ctx.after(60, function()
        poll()
        if game.tick < phase_end + 3900 then every() end
      end)
    end
    every()

    ctx.after(300, function()
      local pop = colony.live_colonists(c)
      ctx.check("colonists are on the payroll", pop >= 2, pop)
    end)

    ctx.after(8700, function()
      if not (hut.valid and h) then ctx.check("the nursery survived the run", false) return ctx.finish() end
      local cutter = watch.cutter
      local gained = wood_held() - watch.wood_before_chop
      ctx.check("the woodcutter felled a planted tree",
        watch.chopped ~= nil or (cutter and cutter.valid and cutter.get_item_count("wood") > 0), "trees "
          .. watch.plant_trees .. " -> " .. tostring(watch.chopped))
      ctx.check("wood came back out of the planted forest", gained > 0 or (cutter and cutter.valid
        and cutter.get_item_count("wood") > 0), gained .. " wood gained (lodge "
        .. tostring(cutter and cutter.valid and cutter.get_item_count("wood")) .. ")")
      -- A hut with nothing to plant must say so instead of claiming it is working.
      local left = hut.get_item_count("wood")
      if left > 0 then hut.remove_item{name = "wood", count = left} end
      feedback.update(c)
      local cs = hut.valid and hut.custom_status
      local key = cs and type(cs.label) == "table" and tostring(cs.label[1]) or nil
      ctx.check("an empty-chest nursery reports waiting for supplies",
        key ~= nil and key:find("hut%-no%-inputs") ~= nil, key or "none")
      hut.insert{name = "wood", count = 4}
      ctx.probe("planting spots visible in one scan", function() return work.site_count(h) end)
      ctx.profile("site_count(forester) x50", function() work.site_count(h) end, 50)
      ctx.probe("forestry numbers", function()
        return string.format("spacing %d radius %d cost %d/tree yield %d wood net %+d", forest.SPACING, forest.RADIUS,
          forest.SAPLING_COST, forest.WOOD_PER_TREE, forest.net_wood())
      end)
      ctx.probe("over the run", function()
        return (watch.trees_max or 0) .. " trees at peak, min wood " .. tostring(watch.wood_min)
      end)
      ctx.finish()
    end)
  end,
})
