-- M1 commuter spike (#50): A is a residential town (12 beds, 8 colonists, no huts, so most are idle); B, 200 tiles
-- east on the same line, is an outpost (a Town Hall, a Forager's Hut, a stocked Canteen, no houses). B posts a
-- worker deficit, A's idle colonists ride out as commuters, work B's hut and eat at its Canteen while A holds their
-- beds, and when the shift ends they ride home. Nobody is lost on the way: A + B + riders stays 8 throughout.
-- Run: TICKS=12000 scripts/headless-spike.sh m1_commute
local core = require("scripts.spike.core")
local colony_mod = require("scripts.colony")
local commute = require("scripts.commute")
local transitm = require("scripts.model.transit")

local ROW, STOP_ROW = 19, 17
local FINISH = 10800
local SHIFT = 2400

local function colony_of(hall)
  for _, c in pairs(storage.colonies or {}) do
    if c.hall and c.hall.valid and hall and hall.valid and c.hall.unit_number == hall.unit_number then return c end
  end
end

core.register("m1_commute", {
  issue = 50, auto = true, desc = "commuters: A's idle ride to B's outpost, work, eat at the canteen, ride home", usage = "",
  run = function(ctx)
    local s = ctx.surface
    s.request_to_generate_chunks({x = 100, y = 0}, 8)
    s.force_generate_chunk_requests()
    for _, e in pairs(s.find_entities_filtered{area = {{-12, -10}, {232, 26}}}) do
      if e.type ~= "character" and e.valid then e.destroy() end
    end
    local tiles = {}
    for x = -12, 232 do
      for y = -10, 26 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
    end
    s.set_tiles(tiles, true)
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos, dir)
      return s.create_entity{name = name, position = pos, direction = dir, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    storage.shift_override = SHIFT

    local hallA = build("colony-town-hall", {0, 0})
    local hallB = build("colony-town-hall", {200, 0})
    local cA, cB = colony_of(hallA), colony_of(hallB)
    ctx.check("two colonies", cA ~= nil and cB ~= nil and cA ~= cB)
    if not (cA and cB) then return ctx.finish() end
    cA.accept_migrants, cB.accept_migrants = false, false
    hallA.insert{name = "raw-fish", count = 2000}   -- evaluations every 150 ticks eat fast
    for _, x in ipairs({-8, 8, -16}) do
      local t = build("colony-housing-tent", {x, 4})
      if t then t.insert{name = "raw-fish", count = 30} end
    end

    -- The outpost: a forager hut with patches, baskets in the hall, a canteen with food. No houses.
    local hut = build("colony-forager-hut", {206, -6})
    hallB.insert{name = "colony-basket", count = 6}
    for i = 0, 7 do s.create_entity{name = "colony-forage-patch", position = {212 + (i % 4) * 2, -12 + math.floor(i / 4) * 2}} end
    local canteen = build("colony-canteen", {194, -6})
    ctx.check("outpost built: hut and canteen registered", hut and hut.valid and canteen and canteen.valid
      and cB.canteens[canteen.unit_number] ~= nil)
    if not (canteen and canteen.valid) then return ctx.finish() end
    canteen.insert{name = "raw-fish", count = 20}

    for x = 15, 211, 2 do
      s.create_entity{name = "straight-rail", position = {x, ROW}, direction = defines.direction.east, force = "player"}
    end
    local stopA = build("train-stop", {15, STOP_ROW}, defines.direction.west)
    local stopB = build("train-stop", {211, ROW + 2}, defines.direction.east)
    stopA.backer_name, stopB.backer_name = "COMMUTE-A", "COMMUTE-B"
    local platA = build("colony-passenger-platform", {17, 14})
    local platB = build("colony-passenger-platform", {217, 16})
    ctx.check("line, stops and platforms", stopA.connected_rail ~= nil and stopB.connected_rail ~= nil
      and platA and platA.valid and platB and platB.valid)
    local loco1 = build("locomotive", {101, ROW}, defines.direction.east)
    local coach = build("colony-passenger-coach", {108, ROW}, defines.direction.east)
    local loco2 = build("locomotive", {115, ROW}, defines.direction.west)
    for _, l in ipairs({loco1, loco2}) do l.get_fuel_inventory().insert{name = "coal", count = 50} end
    local wait = {{type = "time", ticks = 300, compare_type = "and"}}
    loco1.train.schedule = {current = 1, records = {{station = "COMMUTE-A", wait_conditions = wait},
      {station = "COMMUTE-B", wait_conditions = wait}}}
    loco1.train.manual_mode = false

    for _ = 1, 8 do colony_mod.spawn_colonist(cA) end
    ctx.check("A starts with 8 colonists", colony_mod.live_colonists(cA) == 8)

    -- Once the canteen has run dry and the first shift has gone home, B's hall gets food: haulers restock the
    -- canteen and a second shift comes out.
    ctx.after(6000, function() hallB.insert{name = "raw-fish", count = 200} end)
    local t0 = game.tick
    local st = {deficit = 0, bound = 0, away = 0, at_b = 0, b_jobs = {}, meals0 = nil, meals_min = 1e9,
      total_min = 1e9, total_max = 0, migrant_groups = 0, labels = {}, home_seen = false, homeless_b = 0}
    local function riders()
      local n = 0
      for _, rec in pairs(storage.coaches or {}) do
        n = n + transitm.riders(rec.groups)
        for _, g in ipairs(rec.groups or {}) do if g.kind == nil then st.migrant_groups = st.migrant_groups + 1 end end
      end
      return n
    end
    local function sample()
      cA.pop_cache, cA.pop_tick, cB.pop_cache, cB.pop_tick = nil, nil, nil, nil
      local la, lb = colony_mod.live_colonists(cA), colony_mod.live_colonists(cB)
      local total = la + lb + riders() + (cA.fallen or 0) + (cB.fallen or 0)   -- the dead are accounted for, not lost
      st.total_min, st.total_max = math.min(st.total_min, total), math.max(st.total_max, total)
      st.deficit = math.max(st.deficit, cB.deficit or 0)
      if st.away > 0 and (cA.away or 0) == 0 and la == 8 then st.round_trip = true end
      st.away = math.max(st.away, cA.away or 0)
      for un in pairs(cA.colonists) do
        local u = storage.unit_state[un]
        if u and u.commute then st.bound = st.bound + 1; break end
      end
      local here = commute.here(cB)
      st.at_b = math.max(st.at_b, #here)
      if game.tick - t0 > 6200 then st.second = math.max(st.second or 0, #here) end
      for _, un in ipairs(here) do
        local u = storage.unit_state[un]
        if u and u.job then st.b_jobs[u.job] = true end
        if u and u.home then st.home_seen = true end
      end
      local meals = commute.meals(cB)
      st.meals0 = st.meals0 or meals
      st.meals_min = math.min(st.meals_min, meals)
      local cs = canteen.valid and canteen.custom_status
      local lab = cs and cs.label and cs.label[1]
      if lab then st.labels[lab] = true end
      ctx.log(string.format("[poll] t=%d A=%d (away %d, D=%.2f, dead %d) B=%d (commuters %d, deficit %d) riders=%d meals=%d",
        game.tick - t0, la, cA.away or 0, cA.d or 0, cA.fallen or 0, lb, #here, cB.deficit or 0, total - la - lb, meals))
    end
    local function every()
      ctx.after(60, function()
        sample()
        if game.tick - t0 < FINISH then every() end
      end)
    end
    every()

    ctx.after(FINISH + 30, function()
      cA.pop_cache, cA.pop_tick, cB.pop_cache, cB.pop_tick = nil, nil, nil, nil
      ctx.check("1 the outpost posts a worker deficit", st.deficit > 0, "max deficit " .. st.deficit)
      ctx.check("2 A's idle colonists head off to commute", st.bound > 0)
      ctx.check("3 A holds beds for commuters away", st.away > 0, "max away " .. st.away)
      ctx.check("4 commuters arrive at B and work there", st.at_b > 0 and (st.b_jobs.forage or st.b_jobs.haul),
        "max at B " .. st.at_b)
      ctx.check("5 the canteen feeds them", st.meals_min < st.meals0, st.meals0 .. " -> min " .. st.meals_min)
      ctx.check("6 the canteen tooltip showed commuters being fed", st.labels["colony-status.canteen-serving"] == true)
      ctx.check("7 shifts end and commuters head home", st.home_seen)
      ctx.check("8 nobody is lost: A + B + riders (+ dead) stays 8", st.total_min == 8 and st.total_max == 8,
        st.total_min .. ".." .. st.total_max)
      ctx.check("9 no commuter was ever sent off as a migrant", st.migrant_groups == 0, st.migrant_groups .. " migrant groups")
      ctx.check("10 a round trip completed: all 8 back in A, no beds held", st.round_trip == true)
      ctx.check("11 restocked from the outpost's hall, a second shift comes out", (st.second or 0) > 0,
        "max commuters at B after the restock " .. tostring(st.second))
      ctx.finish()
    end)
  end,
})
