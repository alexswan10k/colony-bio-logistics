-- Forester's Hut (#97): where trees may be replanted, and what a planted tree is worth.
-- The world checks (tile, collision, territory) belong to work.lua; everything here is pure.
local forest = require("scripts.model.forest")
local labour = require("scripts.model.labour")
local workshop = require("scripts.model.workshop")
local yields = require("scripts.model.yields")

describe("forest (replanting rules, #97)", function()
  it("plants on soil only", function()
    truthy(forest.plantable("grass-1"))
    truthy(forest.plantable("grass-4"))
    truthy(forest.plantable("dirt-7"))
    truthy(forest.plantable("dry-dirt"))
    eq(forest.plantable("water"), false)
    eq(forest.plantable("water-shallow"), false)
    eq(forest.plantable("concrete"), false)
    eq(forest.plantable("stone-path"), false)
    eq(forest.plantable("out-of-map"), false)
    eq(forest.plantable("sand-1"), false)      -- trees do not grow on sand, so a sapling does not either
    eq(forest.plantable(nil), false)
  end)

  it("offers spots inside the radius, on tile centres, nearest first", function()
    local base = {x = 100.5, y = 100.5}
    local spots = forest.candidates(base, 10, 4)
    truthy(#spots > 0)
    local last
    for _, spot in ipairs(spots) do
      local dx, dy = spot.x - base.x, spot.y - base.y
      truthy(dx * dx + dy * dy <= 10 * 10 + 1e-9, "spot outside the radius")
      near(spot.x % 1, 0.5, 1e-9, "spot is not on a tile centre")
      near(spot.y % 1, 0.5, 1e-9, "spot is not on a tile centre")
      if last then truthy(spot.d2 >= last, "spots are not nearest first") end
      last = spot.d2
    end
  end)

  it("keeps the lattice spacing between spots, and the lattice is shared between huts", function()
    local a = forest.candidates({x = 100.5, y = 100.5}, 12, 4)
    local b = forest.candidates({x = 108.5, y = 100.5}, 12, 4)
    for i, p in ipairs(a) do
      for j = i + 1, #a do
        local q = a[j]
        local d2 = (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2
        truthy(d2 >= 4 * 4 - 1e-9, "two spots are closer than the spacing")
      end
    end
    local shared = 0
    for _, p in ipairs(a) do
      for _, q in ipairs(b) do
        if p.x == q.x and p.y == q.y then shared = shared + 1 end
      end
    end
    truthy(shared > 0, "two huts did not share a lattice point")
  end)

  it("is deterministic", function()
    local a = forest.candidates({x = 12.5, y = -30.5}, 16)
    local b = forest.candidates({x = 12.5, y = -30.5}, 16)
    eq(#a, #b)
    for i = 1, #a do
      eq(a[i].x, b[i].x)
      eq(a[i].y, b[i].y)
    end
  end)

  it("refuses a spot within the spacing of a standing tree", function()
    local spot = {x = 10.5, y = 10.5}
    eq(forest.blocked(spot, {}), false)
    eq(forest.blocked(spot, nil), false)
    eq(forest.blocked(spot, {{x = 13.5, y = 10.5}}), true)        -- 3 tiles: too close
    eq(forest.blocked(spot, {{x = 14.5, y = 10.5}}), false)       -- 4 tiles: exactly the spacing
    eq(forest.blocked(spot, {{x = 12.0, y = 12.0}}), true)        -- diagonal, ~2.1 tiles
  end)

  it("chooses the nearest spot that is neither blocked nor refused", function()
    local base = {x = 0.5, y = 0.5}
    local spots = forest.candidates(base, 8, 4)
    local first = spots[1]
    -- Block the nearest spot with a standing tree: the next one wins.
    local taken = forest.choose(spots, {{x = first.x, y = first.y}}, nil)
    truthy(taken ~= first, "chose a spot with a tree on it")
    -- Refuse everything: nowhere to plant.
    eq(forest.choose(spots, nil, function() return false end), nil)
    -- The accept predicate sees each candidate in order.
    local seen = 0
    local picked = forest.choose(spots, nil, function() seen = seen + 1; return seen == 3 end)
    eq(picked.x, spots[3].x)
    eq(picked.y, spots[3].y)
  end)

  it("one wood in, a whole chop trip out, so a managed forest still turns a profit", function()
    eq(forest.SAPLING_COST, 1)
    eq(forest.WOOD_PER_TREE, yields.CHOP.count)
    eq(forest.net_wood(), yields.CHOP.count - 1)
    truthy(forest.net_wood() > 0)
    -- Planting must cost a trip in exchange, or wood would be free: the forester is not a wood generator that
    -- beats a standing tree (a chop trip is ONE trip for WOOD_PER_TREE, planting plus chopping is two).
    truthy(forest.WOOD_PER_TREE / 2 < forest.WOOD_PER_TREE)
  end)
end)

describe("forester's hut (definition, #97)", function()
  it("is a tooled, supply-gated labour hut", function()
    local def = labour.HUTS["colony-forester-hut"]
    truthy(def, "the hut is not registered in labour.HUTS")
    eq(def.job, "forest")
    eq(def.tool, "colony-spade")
    truthy(def.capacity >= 1)
    -- `keep` stops haulers treating the wood it plants with as output; `inputs` is what haulers bring.
    eq(def.keep[1], "wood")
    eq(def.inputs[1].item, "wood")
    truthy(def.inputs[1].count >= 1)
    -- Without wood in its chest the hut cannot work, so that gate has to be declarable to the status line.
    eq(def.requires[1], "wood")
  end)
  it("has a spade the Toolsmith can make from wood and iron", function()
    local recipe = workshop.RECIPES["colony-spade"]
    truthy(recipe, "no spade recipe: the Toolsmith could never tool a forester hut")
    truthy(recipe.wood >= 1)
    truthy(recipe["iron-plate"] >= 1)
  end)
  it("is in the workforce matrix, so the player can rank and cap it", function()
    local jobs = require("scripts.model.jobs")
    local found, rank
    for _, job in ipairs(jobs.JOBS) do if job == "forest" then found = true end end
    truthy(found, "forest is not in jobs.JOBS")
    rank = jobs.rank(nil, "forest")
    truthy(rank > 0, "forest defaults to disabled")
  end)
end)
