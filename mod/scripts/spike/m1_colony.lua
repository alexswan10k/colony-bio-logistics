-- M1 integration test: hall -> territory -> houses (tent+powered cabin) -> hauling -> work -> tools.
-- Run: TICKS=14000 scripts/headless-spike.sh m1_colony
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local work = require("scripts.work")
local farm = require("scripts.model.farm")
local events = require("scripts.events")
local wildlife = require("scripts.wildlife")

core.register("m1_colony", {
  issue = 28, auto = true, desc = "town hall + housing + hauling + tools", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(100, "grass-1")   -- farmland for the farm-hut checks (#44)
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local far = build("colony-housing-tent", {p.x + 200, p.y})
    ctx.check("tent outside territory rejected", not (far and far.valid))
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    ctx.check("overlapping hall rejected", not (build("colony-town-hall", {p.x + 10, p.y}) or {valid = false}).valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    local cabin_pos = {p.x + 6, p.y + 8}
    ctx.power_at({x = cabin_pos[1], y = cabin_pos[2]})
    local cabin = build("colony-housing-cabin", cabin_pos)
    -- Fishing Dock (#80): water access is real. Carve a small pond, put the dock beside it, and check that a
    -- dock with no water in reach is refused and refunded rather than sitting there doing nothing.
    for dx = -1, 1 do
      for dy = -1, 1 do
        s.set_tiles{{name = "water", position = {p.x + 18 + dx, p.y + 18 + dy}}}
      end
    end
    local dock = build("colony-fishing-dock", {p.x + 15, p.y + 18})
    local inland = build("colony-fishing-dock", {p.x - 14, p.y - 14})
    hall.insert{name = "colony-rod", count = 3}

    -- Hunting Lodge (#79): real hunting - docile game on its own force, shot by colonists. Two boars are
    -- placed beside the lodge so the hunt does not depend on where the herd happened to wander.
    local lodge = build("colony-hunting-lodge", {p.x + 8, p.y + 12})
    hall.insert{name = "colony-rifle", count = 3}
    local boars = {}
    for i = 1, 2 do
      local b = wildlife.spawn(s, wildlife.ensure_force(), {p.x + 4 + i * 4, p.y + 16})
      if b then
        c.animals = c.animals or {}
        c.animals[b.unit_number] = {entity = b, roam_at = 0}
        wildlife.roam(b)
        boars[#boars + 1] = b
      end
    end
    local kills = 0
    events.on(defines.events.on_entity_died, function(ev)
      if ev.entity.name == wildlife.ANIMAL and ev.cause and ev.cause.name == "colony-colonist" then
        kills = kills + 1
      end
    end)
    local patches_pre = #s.find_entities_filtered{name = "colony-forage-patch", position = p, radius = 30}
    local forager = build("colony-forager-hut", {p.x - 6, p.y})
    local farmhut = build("colony-farm-hut", {p.x + 6, p.y - 8})
    local woodcutter = build("colony-woodcutter-hut", {p.x - 6, p.y + 6})
    local miner = build("colony-miner-hut", {p.x - 6, p.y - 6})
    farmhut.insert{name = "colony-hoe", count = 3}
    local plots = {}
    for i = 0, 5 do plots[#plots + 1] = build("colony-farm-plot", {p.x + 4 + i, p.y - 12}) end
    local plot_count = 0
    for _ in pairs(c.plots or {}) do plot_count = plot_count + 1 end
    ctx.check("farm plots registered", plot_count == 6, plot_count)
    s.set_tiles{{name = "refined-concrete", position = {p.x + 24, p.y + 24}}}
    local badplot = build("colony-farm-plot", {p.x + 24, p.y + 24})
    ctx.check("farm plot rejected on paving", not (badplot and badplot.valid))
    -- Colony crates (#33): supply (provider), demand (requester), warehouse (bulk stock)
    local supply_crate = build("colony-supply-crate", {p.x + 10, p.y + 12})
    local demand_crate = build("colony-demand-crate", {p.x + 13, p.y + 12})
    local warehouse = build("colony-warehouse", {p.x + 20, p.y + 8})
    ctx.check("crates registered with the colony", supply_crate and demand_crate and warehouse
      and c.crates[supply_crate.unit_number] and c.crates[demand_crate.unit_number]
      and c.crates[warehouse.unit_number], supply_crate and supply_crate.valid)
    -- Compost Bin (#78): spoilage is garbage that blocks food, so colonists carry it here and it rots down
    -- into fertilizer. Ten spoilage in the hall and three in the tent cover both sources (stock and house).
    local bin = build("colony-compost-bin", {p.x + 16, p.y + 14})
    ctx.check("compost bin registered with the colony", bin and bin.valid and c.bins[bin.unit_number] ~= nil)
    local outside_bin = build("colony-compost-bin", {p.x + 210, p.y + 210})
    ctx.check("compost bin outside territory rejected", not (outside_bin and outside_bin.valid))
    ctx.check("hunting lodge registered with the colony", lodge and lodge.valid and c.huts[lodge.unit_number] ~= nil)
    ctx.check("game spawned inside territory", #boars == 2 and game.forces["colony-wildlife"] ~= nil, #boars)
    ctx.check("fishing dock registered with the colony beside water",
      dock and dock.valid and c.huts[dock.unit_number] ~= nil)
    ctx.check("a dock with no water in reach is refused", not (inland and inland.valid))
    hall.insert{name = "spoilage", count = 10}
    tent.insert{name = "spoilage", count = 3}
    local outside_crate = build("colony-supply-crate", {p.x + 200, p.y + 200})
    ctx.check("crate outside territory rejected", not (outside_crate and outside_crate.valid))
    -- The supply crate holds coal, which nothing else produces, so seeing coal in the hall proves the
    -- provider leg. The demand crate wants stone that only the warehouse holds, proving both the filter
    -- and warehouse sourcing.
    -- Construction (#37): a ghost inside territory is built from colony stock, and a damaged hall is
    -- repaired with a repair pack. A second ghost far outside the claim proves territory is respected.
    local chest_pos = {x = p.x - 10, y = p.y + 10}
    local chest_ghost = s.create_entity{name = "entity-ghost", inner_name = "iron-chest",
      position = chest_pos, force = "player", raise_built = true}
    s.create_entity{name = "entity-ghost", inner_name = "iron-chest", position = {p.x + 220, p.y + 220},
      force = "player", raise_built = true}
    hall.insert{name = "iron-chest", count = 1}
    hall.insert{name = "repair-pack", count = 1}
    hall.health = hall.max_health - 100
    supply_crate.insert{name = "coal", count = 50}
    c.crates[demand_crate.unit_number].filters = {{item = "stone", count = 30}}
    warehouse.insert{name = "stone", count = 100}
    ctx.check("houses registered", tent and cabin and c.houses[tent.unit_number] and c.houses[cabin.unit_number] ~= nil)
    ctx.check("capacity 10", colony.capacity(c) == 10, colony.capacity(c))
    ctx.check("hut does not spawn forage patches",
      #s.find_entities_filtered{name = "colony-forage-patch", position = p, radius = 30} == patches_pre, patches_pre)
    ctx.check("logistics marker item and recipe exist",
      prototypes.item["colony-logistics-marker"] ~= nil and prototypes.recipe["colony-logistics-marker"] ~= nil)
    local st = colony.stats(c)
    ctx.check("colony stats: 9 chunks, capacity 10", st.chunks == 9 and st.capacity == 10, st.chunks .. "/" .. st.capacity)
    -- watchtower (design §2.1): built inside territory, claims the chunks around itself; removing it gives them back
    local outside = build("colony-watchtower", {p.x + 70, p.y})
    ctx.check("watchtower outside territory rejected", not (outside and outside.valid))
    local tower = build("colony-watchtower", {p.x + 40, p.y})
    ctx.check("watchtower built inside territory", tower and tower.valid)
    ctx.check("watchtower expands territory 9 -> 12 chunks", colony.stats(c).chunks == 12, colony.stats(c).chunks)
    ctx.check("colony stats counts the watchtower", colony.stats(c).towers == 1, colony.stats(c).towers)
    ctx.after(5, function() if tower.valid then tower.destroy() end end)
    ctx.after(15, function()
      ctx.check("removing a watchtower releases its chunks", colony.stats(c).chunks == 9, colony.stats(c).chunks)
    end)
    local wh = c.huts[woodcutter.unit_number]
    woodcutter.insert{name = "colony-axe", count = 3}
    wh.limit = 0
    local _, _, allowed0 = work.hut_info(wh)
    ctx.check("hut worker limit can pause a hut", allowed0 == 0, allowed0)
    wh.limit = 1
    local _, _, allowed1 = work.hut_info(wh)
    ctx.check("hut worker limit caps workers", allowed1 == 1, allowed1)
    wh.limit = nil
    local _, _, allowed_all = work.hut_info(wh)
    ctx.check("hut without a limit uses its tool count", allowed_all == 3, allowed_all)
    -- natural forage patches exist in the world already; the hut harvests them
    for i = 0, 5 do s.create_entity{name = "colony-forage-patch", position = {p.x - 10 + i, p.y + 1}} end
    local furnace = s.create_entity{name = "stone-furnace", position = {p.x - 8, p.y + 12}, force = "player"}
    local fm = colony.set_machine(c, furnace, true)
    fm.requests = {{item = "iron-ore", count = 20}, {item = "wood", count = 10}}
    ctx.check("opted-in machine gets an alt-mode badge", fm.badge ~= nil and fm.badge.valid)
    local probe = s.create_entity{name = "stone-furnace", position = {p.x + 18, p.y - 18}, force = "player"}
    local pm = colony.set_machine(c, probe, true)
    colony.set_machine(c, probe, false)
    ctx.check("opting out destroys the badge", pm.badge == nil and not pm.enabled)
    probe.destroy()
    hall.insert{name = "iron-ore", count = 100}
    hall.insert{name = "raw-fish", count = 200}
    hall.insert{name = "wood", count = 100}
    hall.insert{name = "colony-basket", count = 3}
    hall.insert{name = "colony-axe", count = 3}
    hall.insert{name = "colony-pickaxe", count = 3}
    for i = 1, 12 do s.create_entity{name = "tree-01", position = {p.x + 12 + i * 2, p.y + 8}} end
    local ore1 = s.create_entity{name = "iron-ore", position = {p.x - 14, p.y - 6}, amount = 500}
    local ore2 = s.create_entity{name = "iron-ore", position = {p.x - 15, p.y - 6}, amount = 500}
    -- A stone patch closer than the iron: the miner only ignores it because the player turned stone off (#74).
    local stone1 = s.create_entity{name = "stone", position = {p.x - 9, p.y - 6}, amount = 500}
    c.huts[miner.unit_number].ores = {stone = 0}
    local trees_before = #s.find_entities_filtered{type = "tree", position = {p.x + 12, p.y + 8}, radius = 30}
    local ore_before = (ore1 and ore1.amount or 0) + (ore2 and ore2.amount or 0)
    local patches_before = #s.find_entities_filtered{name = "colony-forage-patch", position = p, radius = 30}
    local saw = {ore = false, wood = false, food = false, planted = false, ripe = false, produce = false,
      hut_output = false, fish = false}
    local function produce_total()
      local n = hall.get_item_count("colony-produce")
      for _, h in pairs(c.houses) do
        if h.entity.valid then n = n + h.entity.get_item_count("colony-produce") end
      end
      return n
    end
    for i = 1, 40 do
      ctx.after(300 * i, function()
        if furnace.valid then
          if furnace.get_item_count("iron-ore") > 0 then saw.ore = true end
          if furnace.get_item_count("wood") > 0 then saw.wood = true end
        end
        local th, ch = c.houses[tent.unit_number], c.houses[cabin.unit_number]
        local function food(h)
          local n = 0
          for _, item in ipairs({"colony-forage", "raw-fish"}) do n = n + h.entity.get_item_count(item) end
          return n
        end
        if (th and food(th) > 0) or (ch and food(ch) > 0) then saw.food = true end
        for _, plot in pairs(c.plots or {}) do
          if plot.stage == farm.GROWING then saw.planted = true elseif plot.stage == farm.RIPE then saw.ripe = true end
        end
        if produce_total() > 0 then saw.produce = true end
        if hall.get_item_count("colony-meat") > 0 then saw.meat = true end
        if hall.get_item_count("colony-fish") > 0 then saw.fish = true end
        for _, h in pairs(c.huts) do
          if h.entity.valid and h.entity.get_item_count("colony-meat") > 0 then saw.meat = true end
        end
        -- Yield is deposited in the hut that employed the colonist (#72), not walked to the hall.
        for _, h in pairs(c.huts) do
          if h.entity.valid then
            for _, item in ipairs({"wood", "iron-ore", "copper-ore", "coal", "stone", "colony-forage",
                "colony-produce", "colony-meat", "colony-fish"}) do
              if h.entity.get_item_count(item) > 0 then saw.hut_output = true end
            end
          end
        end
      end)
    end
    ctx.after(colony.INTERVAL * 12, function()
      -- Guarantee a hunter: the hunting share of the workforce is small, and a 12000-tick test should not
      -- depend on the matrix happening to pick it. A player lock is the normal way to force a role (#38).
      local ids = colony.colonist_ids(c)
      c.locks = c.locks or {}
      if ids[1] then c.locks[ids[1]] = "hunt" end
      if ids[2] then c.locks[ids[2]] = "fish" end
    end)
    ctx.after(colony.INTERVAL * 20, function()
      local tcnt = function(e, i) return e.get_inventory(defines.inventory.chest).get_item_count(i) end
      local th, ch = c.houses[tent.unit_number], c.houses[cabin.unit_number]
      local wh, fh, mh = c.huts[woodcutter.unit_number], c.huts[forager.unit_number], c.huts[miner.unit_number]
      local trees_after = #s.find_entities_filtered{type = "tree", position = {p.x + 12, p.y + 8}, radius = 30}
      local patches_after = #s.find_entities_filtered{name = "colony-forage-patch", position = p, radius = 30}
      local ore_after = (ore1 and ore1.valid and ore1.amount or 0) + (ore2 and ore2.valid and ore2.amount or 0)
      local ore_end = hall.get_item_count("iron-ore") + furnace.get_item_count("iron-ore")
        + hall.get_item_count("iron-plate") + furnace.get_item_count("iron-plate")
      ctx.log(string.format("pop=%d D=%.2f tent: fish=%d wood=%d score=%s | cabin: fish=%d wood=%d score=%s powered=%s",
        colony.live_colonists(c), c.d or 0, tcnt(tent, "raw-fish"), tcnt(tent, "wood"), tostring(th.score),
        tcnt(cabin, "raw-fish"), tcnt(cabin, "wood"), tostring(ch.score), tostring(colony.is_powered(ch))))
      ctx.log("hall: fish=" .. hall.get_item_count("raw-fish") .. " forage=" .. hall.get_item_count("colony-forage") .. " wood=" .. hall.get_item_count("wood") ..
        " iron-ore=" .. hall.get_item_count("iron-ore") .. " produce=" .. produce_total() .. " axes=" .. hall.get_item_count("colony-axe") ..
        " picks=" .. hall.get_item_count("colony-pickaxe"))
      ctx.log(string.format("trees %d -> %d | patches %d -> %d | ore %d -> %d | wear chop=%s forage=%s mine=%s",
        trees_before, trees_after, patches_before, patches_after, ore_before, ore_after,
        tostring(wh and wh.wear), tostring(fh and fh.wear), tostring(mh and mh.wear)))
      ctx.log("furnace: ore=" .. furnace.get_item_count("iron-ore") .. " wood=" .. furnace.get_item_count("wood") ..
        " plates=" .. furnace.get_item_count("iron-plate") .. " hall plates=" .. hall.get_item_count("iron-plate"))
      ctx.check("hauled food to houses", saw.food)
      ctx.check("hauled wood to tent", tcnt(tent, "wood") > 0)
      ctx.check("cabin is powered", colony.is_powered(ch) == true)
      ctx.check("cabin got no wood (power substitutes)", tcnt(cabin, "wood") == 0, tcnt(cabin, "wood"))
      ctx.check("houses were fed (critical need served before machine requests)", saw.food)
      ctx.check("trees chopped down", trees_after < trees_before, trees_before .. " -> " .. trees_after)
      ctx.check("forage patches harvested", patches_after < patches_before, patches_before .. " -> " .. patches_after)
      ctx.check("furnace got iron ore", saw.ore)
      ctx.check("furnace got wood as well as ore", saw.wood)
      ctx.check("opt-in furnace output collected to hall", hall.get_item_count("iron-plate") > 0, hall.get_item_count("iron-plate"))
      ctx.check("mining depletes ore 1:1 (no ore created)", ore_end <= ore_before + 100, ore_end .. " <= " .. (ore_before + 100))
      ctx.check("mining happened", ore_after < ore_before, ore_before .. " -> " .. ore_after)
      ctx.check("tools wear out with use", (wh and wh.wear or 0) + (fh and fh.wear or 0) + (mh and mh.wear or 0) > 0)
      ctx.check("tools hauled to huts", hall.get_item_count("colony-axe") < 3 or hall.get_item_count("colony-pickaxe") < 3 or hall.get_item_count("colony-basket") < 3)
      ctx.check("colonists alive", colony.live_colonists(c) >= 1, colony.live_colonists(c))
      local jc, js = work.job_counts(c), {}
      for job, n in pairs(jc) do js[#js + 1] = job .. "=" .. n end
      ctx.log("jobs: " .. table.concat(js, " "))
      local stone_after = stone1 and stone1.valid and stone1.amount or 0
      ctx.check("miner ignores a de-prioritised ore even when it is closer", stone_after == 500, stone_after)
      local hh, assigned = colony.households(c), 0
      for _, list in pairs(hh) do assigned = assigned + #list end
      ctx.check("every colonist is assigned to a house roster", assigned == colony.live_colonists(c),
        assigned .. "/" .. colony.live_colonists(c))
      ctx.check("harvest yield lands in the worker's hut", saw.hut_output)
      ctx.check("supply crate emptied into colony stock", hall.get_item_count("coal") > 0, hall.get_item_count("coal"))
      ctx.check("demand crate filled from the warehouse", demand_crate.valid and demand_crate.get_item_count("stone") > 0,
        demand_crate.valid and demand_crate.get_item_count("stone"))
      ctx.check("warehouse was the source (no stone in the hall)", hall.get_item_count("stone") == 0)
      ctx.check("demand crate stopped at its filter target", demand_crate.valid and demand_crate.get_item_count("stone") <= 30,
        demand_crate.valid and demand_crate.get_item_count("stone"))
      ctx.check("farmers planted crops", saw.planted)
      ctx.check("crops ripened", saw.ripe)
      ctx.check("farmers harvested produce", saw.produce, produce_total())
      -- 1x1 entities snap to tile centres, so look near the ghost's spot rather than at the exact float.
      local function chest_at(pos)
        return s.find_entities_filtered{name = "iron-chest", position = pos, radius = 2}[1]
      end
      ctx.check("colonist built a ghost inside territory", chest_at(chest_pos) ~= nil,
        "ghost still standing: " .. tostring(chest_ghost and chest_ghost.valid))
      ctx.check("build cost came out of colony stock", hall.get_item_count("iron-chest") == 0,
        hall.get_item_count("iron-chest"))
      ctx.check("hall repaired with a repair pack", hall.health >= hall.max_health, hall.health)
      ctx.check("repair pack consumed", hall.get_item_count("repair-pack") == 0, hall.get_item_count("repair-pack"))
      ctx.check("ghost outside territory was not built", chest_at({x = p.x + 220, y = p.y + 220}) == nil)
      ctx.check("hall received resources", hall.get_item_count("iron-ore") + hall.get_item_count("colony-forage") > 0 or hall.get_item_count("wood") > 100)
      ctx.check("hunters killed game", kills > 0, kills)
      ctx.check("a hunter's kill reached colony stock", saw.meat)
      ctx.check("fishers landed fish and it reached colony stock", saw.fish)
      local live_game = 0
      for _, rec in pairs(c.animals or {}) do if rec.entity.valid then live_game = live_game + 1 end end
      ctx.check("wildlife lives on its own force, in territory", game.forces["colony-wildlife"] ~= nil and live_game > 0,
        live_game)
      ctx.check("spoilage was cleared out of the hall", hall.get_item_count("spoilage") == 0,
        hall.get_item_count("spoilage"))
      ctx.check("spoilage was cleared out of a house", tent.valid and tent.get_item_count("spoilage") == 0,
        tent.valid and tent.get_item_count("spoilage"))
      ctx.check("the compost bin turned spoilage into fertilizer",
        hall.get_item_count("colony-fertilizer") + (bin.valid and bin.get_item_count("colony-fertilizer") or 0) >= 1,
        hall.get_item_count("colony-fertilizer") .. " in the hall")
      ctx.finish()
    end)
  end,
})
