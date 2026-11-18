-- M2 tourism spike (#51): a full Cultural Insight round trip over the landed passenger-coach machinery, plus
-- the anti-exploit cases from PLAN.md §2. A at (0,0) is the home (3 colonists, one cabin, platform); B at
-- (120,0) is a Spa host with no residents and a platform. A frozen day keeps the visit from ending at night.
-- The outbound group boards at A, alights at B (NO payout), visits 6000 ticks, boards home as a visited
-- return group and pays exactly once at A. Then injected self-host/diverted groups and a destroyed coach
-- prove that no other path can pay or leak beds.
-- Run: TICKS=17500 scripts/headless-spike.sh m2_tourism
local core = require("scripts.spike.core")
local colony_mod = require("scripts.colony")
local transit = require("scripts.transit")
local transitm = require("scripts.model.transit")
local tourism = require("scripts.model.tourism")
local adapter = require("scripts.tourism")

local ROW, STOP_A, STOP_B = 19, 17, 21
local HALL_A, HALL_B = {x = 0, y = 0}, {x = 120, y = 0}
local MAIN_END = 13000          -- enough for a 6000-tick visit plus two 120-tile train rides
local INJECT_AT = MAIN_END + 500
local REDIRECT_AT = INJECT_AT + 1500
local CHECK_INJECT_AT = REDIRECT_AT + 1600
local LOSS_AT = CHECK_INJECT_AT + 200
local FINISH_AT = LOSS_AT + 400

local function colony_of(hall)
  for _, c in pairs(storage.colonies or {}) do
    if c.hall and c.hall.valid and hall and hall.valid and c.hall.unit_number == hall.unit_number then return c end
  end
end

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

core.register("m2_tourism", {
  issue = 51, auto = true, desc = "tourism: full coach round trip earns insights only at home; anti-exploit guards",
  usage = "",
  run = function(ctx)
    local s = ctx.surface
    s.request_to_generate_chunks({x = 100, y = 0}, 8)
    s.force_generate_chunk_requests()
    for _, e in pairs(s.find_entities_filtered{area = {{-12, -10}, {230, 26}}}) do
      if e.type ~= "character" and e.valid then e.destroy() end
    end
    local tiles = {}
    for x = -12, 230 do
      for y = -10, 26 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
    end
    s.set_tiles(tiles, true)
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos, dir)
      return s.create_entity{name = name, position = pos, direction = dir, force = "player", raise_built = true}
    end
    storage.interval_override = 150

    local hallA = build("colony-town-hall", HALL_A)
    local hallB = build("colony-town-hall", HALL_B)
    local cA, cB = colony_of(hallA), colony_of(hallB)
    ctx.check("1 two separate colonies", cA ~= nil and cB ~= nil and cA ~= cB)
    if not (cA and cB) then return ctx.finish() end
    cA.accept_migrants, cB.accept_migrants = false, false
    hallA.insert{name = "raw-fish", count = 600}
    hallB.insert{name = "raw-fish", count = 600}
    local cabin = build("colony-housing-cabin", {8, 4})
    if cabin then cabin.insert{name = "raw-fish", count = 60} end
    for _, h in pairs(cA.houses) do h.breed_ready = 2 ^ 31 end

    -- The Spa (host demand) and both Passenger Platforms. The Spa sits inside B's territory.
    local spa = build("colony-spa", {114, -6})
    ctx.check("2 Spa registered in B inside territory", spa and spa.valid and cB.spas[spa.unit_number] ~= nil)
    if not (spa and spa.valid) then return ctx.finish() end

    for x = 15, 131, 2 do
      s.create_entity{name = "straight-rail", position = {x, ROW}, direction = defines.direction.east, force = "player"}
    end
    local stopA = build("train-stop", {15, STOP_A}, defines.direction.west)
    local stopB = build("train-stop", {131, STOP_B}, defines.direction.east)
    if stopA then stopA.backer_name = "TOUR-A" end
    if stopB then stopB.backer_name = "TOUR-B" end
    ctx.check("3 stops connected", stopA and stopA.valid and stopA.connected_rail ~= nil
      and stopB and stopB.valid and stopB.connected_rail ~= nil)
    if not (stopA and stopA.valid and stopB and stopB.valid) then return ctx.finish() end
    local platA = build("colony-passenger-platform", {17, 14})
    local platB = build("colony-passenger-platform", {137, 16})
    ctx.check("4 platforms built and serve their stops",
      cA.platforms[platA.unit_number] ~= nil and cB.platforms[platB.unit_number] ~= nil
        and transit.stop_of(cA.platforms[platA.unit_number]) == stopA
        and transit.stop_of(cB.platforms[platB.unit_number]) == stopB,
      string.format("A %.1f B %.1f tiles", dist(platA.position, stopA.position), dist(platB.position, stopB.position)))

    local loco1 = build("locomotive", {60, ROW}, defines.direction.east)
    local coach = build("colony-passenger-coach", {67, ROW}, defines.direction.east)
    local loco2 = build("locomotive", {74, ROW}, defines.direction.west)
    for _, l in ipairs({loco1, loco2}) do l.get_fuel_inventory().insert{name = "coal", count = 50} end
    local train = loco1.train
    local wait = {{type = "time", ticks = 240, compare_type = "and"}}
    train.schedule = {current = 1, records = {{station = "TOUR-A", wait_conditions = wait},
      {station = "TOUR-B", wait_conditions = wait}}}
    train.manual_mode = false
    ctx.check("5 train assembled", train.valid and #train.cargo_wagons == 1 and train.cargo_wagons[1] == coach)

    for _ = 1, 3 do colony_mod.spawn_colonist(cA) end
    ctx.check("6 home starts with 3 idle colonists, host with none",
      colony_mod.live_colonists(cA) == 3 and colony_mod.live_colonists(cB) == 0)

    -- Regression for the review's MAJOR finding: C is a host with 7 residents but only 6 beds (one truly
    -- homeless) AND two registered visitors. live_colonists excludes the visitors, so the homeless math
    -- must not subtract them a second time or the homeless resident would never be sent by rail.
    local hallC = build("colony-town-hall", {200, 0})
    local cC = colony_of(hallC)
    if not cC then return ctx.finish() end
    cC.accept_migrants = false
    hallC.insert{name = "raw-fish", count = 600}
    local c_cabin = build("colony-housing-cabin", {208, 4})
    if c_cabin then c_cabin.insert{name = "raw-fish", count = 60} end
    for _, h in pairs(cC.houses) do h.breed_ready = 2 ^ 31 end
    local stopC = build("train-stop", {206, 6})
    if stopC then stopC.backer_name = "TOUR-C" end
    local platC = build("colony-passenger-platform", {210, 10})
    for _ = 1, 7 do colony_mod.spawn_colonist(cC) end
    for _ = 1, 2 do
      local e = colony_mod.spawn_colonist(cC)
      if e then
        storage.tourists[e.unit_number] = {home = cC.id, host = cC.id, ["until"] = game.tick + 100000}
        storage.unit_state[e.unit_number] = {colony_id = cC.id, job = "travel", state = "visiting"}
      end
    end
    cC.pop_cache, cC.pop_tick = nil, nil   -- spawn_colonist cached the count before the visitor records landed
    ctx.check("6b host C has 7 residents, 6 beds, 2 visitors and a served platform",
      colony_mod.live_colonists(cC) == 7 and #adapter.here(cC) == 2
        and platC and platC.valid and transit.stop_of(cC.platforms[platC.unit_number]) == stopC,
      "live " .. colony_mod.live_colonists(cC) .. ", visitors " .. #adapter.here(cC))

    local t0 = game.tick
    local st = {
      outbound_max = 0, away_max = 0, visitors_max = 0, host_stops_with_visitors = 0,
      insights_at_first_visit = nil, insights_during_visit_max = 0, return_max = 0, visited_seen = false,
      host_pop_max = 0, bad_jobs = 0, no_bed_host = true, first_insight_tick = nil,
      first_insight = 0, away_at_insight = nil, plain_data = true, plain_checked = false,
      c_homeless_sent = 0,
    }
    local function groups_of(kind, fn)
      local n = 0
      for _, rec in pairs(storage.coaches or {}) do
        for _, g in ipairs(rec.groups or {}) do
          if g.kind == kind then n = n + (fn and fn(g) or g.n) end
        end
      end
      return n
    end
    local function sample()
      local now = game.tick - t0
      local visitors = adapter.here(cB)
      cA.pop_cache, cA.pop_tick, cB.pop_cache, cB.pop_tick = nil, nil, nil, nil
      local _, pb = colony_mod.live_colonists(cA), colony_mod.live_colonists(cB)
      st.outbound_max = math.max(st.outbound_max, groups_of("tourist"))
      st.return_max = math.max(st.return_max, groups_of("tourist_return"))
      groups_of("tourist_return", function(g)
        if g.visited then st.visited_seen = true end
        return 0
      end)
      st.away_max = math.max(st.away_max, cA.away or 0)
      st.visitors_max = math.max(st.visitors_max, #visitors)
      st.host_pop_max = math.max(st.host_pop_max, pb)
      -- A resident of C walking to its platform for the #49 homeless departure (NOT a tourist/commuter).
      for un, e in pairs(cC.colonists) do
        local us = storage.unit_state[un]
        if e.valid and not storage.tourists[un] and us
            and (us.state == "to_platform" or us.state == "waiting_train")
            and not us.tourist and not us.tourist_return and not us.commute then
          st.c_homeless_sent = st.c_homeless_sent + 1
        end
      end
      if st.inject_away_before and now > INJECT_AT then
        st.away_min_after_inject = math.min(st.away_min_after_inject or (cA.away or 0), cA.away or 0)
      end
      if st.loss_away_before and now > LOSS_AT then
        st.away_min_after_loss = math.min(st.away_min_after_loss or (cA.away or 0), cA.away or 0)
      end
      if #visitors > 0 then
        if st.insights_at_first_visit == nil then st.insights_at_first_visit = cA.insights or 0 end
        if st.first_insight_tick == nil and (cA.insights or 0) == 0 then
          -- Only the FIRST visit is the "no payout at host" window: later overlapping trips may legitimately
          -- pay while another tourist is visiting. Check before recording the first payout tick.
          st.insights_during_visit_max = math.max(st.insights_during_visit_max, cA.insights or 0)
        end
        for _, un in ipairs(visitors) do
          local us = storage.unit_state[un]
          if not (us and us.job == "travel"
              and (us.state == "visiting" or us.state == "to_platform" or us.state == "waiting_train")) then
            st.bad_jobs = st.bad_jobs + 1
          end
          local h = colony_mod.house_of_colonist(cB, un)
          if h and h.valid and h ~= cB.hall then st.no_bed_host = false end
        end
      end
      if train.valid and train.station == stopB and #visitors > 0 then
        st.host_stops_with_visitors = st.host_stops_with_visitors + 1
      end
      if st.first_insight_tick == nil then
        st.away_pre_pay_max = math.max(st.away_pre_pay_max or 0, cA.away or 0)
        if (cA.insights or 0) > 0 then
          st.first_insight_tick = now
          st.first_insight = cA.insights
          st.away_at_insight = cA.away or 0
        end
      end
      if not st.plain_checked then
        st.plain_checked = true
        local function plain(v, depth)
          if depth > 6 then return true end
          if type(v) == "function" then return false end
          if type(v) == "table" then
            for _, x in pairs(v) do if not plain(x, depth + 1) then return false end end
          end
          return true
        end
        st.plain_data = plain(storage.tourists, 0) and plain(storage.coaches, 0)
      end
      ctx.log(string.format("[poll] t=%d A=%d away=%d visitors=%d trains=%d/%d insights=%s/%s",
        now, colony_mod.live_colonists(cA), cA.away or 0, #visitors,
        groups_of("tourist"), groups_of("tourist_return"), tostring(cA.insights), tostring(cA.insights_total)))
    end
    local function poll()
      sample()
      if game.tick - t0 < FINISH_AT then ctx.after(60, poll) end
    end
    ctx.after(60, poll)

    -- Freeze new home departures before the injection window; otherwise a fresh trip can change `away`
    -- between injection and its check and make the bed-release assertion ambiguous.
    ctx.after(MAIN_END, function()
      for un in pairs(cA.colonists) do cA.locks[un] = "haul" end
    end)

    -- Anti-exploit: inject a self-host return group and a diverted outbound group into the real coach. If
    -- either could pay, the insights stat would move on the next stop at A. Beds are held to check release.
    ctx.after(INJECT_AT, function()
      local rec = storage.coaches[coach.unit_number]
      if not rec then
        rec = {groups = {}}
        storage.coaches[coach.unit_number] = rec
        script.register_on_object_destroyed(coach)
      end
      rec.groups[#rec.groups + 1] = {kind = "tourist_return", from = cA.id, home = cA.id, host = cA.id,
        n = 1, stops = 0, visited = true}      -- self-host: must pay nothing
      rec.groups[#rec.groups + 1] = {kind = "tourist", from = cA.id, home = cA.id, host = 9999,
        n = 1, stops = transitm.RETURN_AFTER, visited = nil}   -- diverted: must pay nothing
      rec.groups[#rec.groups + 1] = {kind = "tourist_return", from = cB.id, home = cA.id, host = cB.id,
        n = 2, stops = 0, visited = true}      -- genuine 2-rider return: must pay exactly 2
      st.inject_inflight = groups_of("tourist")   -- a real rider already outbound may re-hold its bed later
      cA.away = (cA.away or 0) + 4
      st.inject_baseline = cA.insights or 0
      st.inject_total_before = cA.insights_total or 0
      st.total_before_inject = cA.insights_total or 0
      st.inject_away_before = cA.away
      if train.valid then
        if train.station == stopA then train.go_to_station(2) else train.go_to_station(1) end
      end
      ctx.log(string.format("[inject] t=%d self+diverted groups, away=%d, insights=%.3f",
        game.tick - t0, cA.away, st.inject_baseline))
    end)
    ctx.after(REDIRECT_AT, function()
      if train.valid and train.station ~= stopA then train.go_to_station(1) end
    end)

    ctx.after(CHECK_INJECT_AT, function()
      ctx.check("7 self-host and diverted groups pay nothing; a genuine 2-rider return pays exactly 2",
        (cA.insights_total or 0) == st.inject_total_before + 2
          and (cA.last_insight_tick or 0) > 0,
        string.format("lifetime total %d -> %d (expected +2)", st.inject_total_before, cA.insights_total or 0))
      ctx.check("8 all injected held beds are released", st.away_min_after_inject ~= nil
        and st.away_min_after_inject <= st.inject_away_before - 4 + (st.inject_inflight or 0),
        st.inject_away_before .. " -> min " .. tostring(st.away_min_after_inject)
          .. " (inflight " .. tostring(st.inject_inflight) .. ")")

      -- One colonist cannot be sent while a child, job-locked, or at night. Same engine evaluation as normal.
      local idle
      for un, e in pairs(cA.colonists) do
        local us = storage.unit_state[un]
        if e.valid and us and us.state == "idle" then idle = un; break end
      end
      if idle then
        storage.age = storage.age or {}
        local saved = storage.age[idle]
        storage.age[idle] = {stage = "child", born = game.tick}
        adapter.evaluate(cA)
        local us = storage.unit_state[idle]
        ctx.check("9 a child is never sent", not (us and us.tourist))
        if saved then storage.age[idle] = saved else storage.age[idle] = nil end
        cA.locks[idle] = "haul"
        adapter.evaluate(cA)
        us = storage.unit_state[idle]
        ctx.check("10 a job-locked colonist is never sent", not (us and us.tourist))
        cA.locks[idle] = nil
        s.freeze_daytime, s.daytime = false, 0.5
        adapter.evaluate(cA)
        us = storage.unit_state[idle]
        ctx.check("11 no departures at night", not (us and us.tourist))
        s.daytime, s.freeze_daytime, s.always_day = 0, true, true
      else
        ctx.check("9 a child is never sent", false, "no idle colonist left to test")
        ctx.check("10 a job-locked colonist is never sent", false)
        ctx.check("11 no departures at night", false)
      end

      -- Coach loss: a tourist group disappears with the coach and its held beds come back with no payout.
      local rec = storage.coaches[coach.unit_number]
      if not rec then
        rec = {groups = {}}
        storage.coaches[coach.unit_number] = rec
      end
      rec.groups[#rec.groups + 1] = {kind = "tourist", from = cA.id, home = cA.id, host = cB.id,
        n = 2, stops = 0, visited = nil}
      cA.away = (cA.away or 0) + 2
      st.loss_baseline, st.loss_away_before = cA.insights_total or 0, cA.away
      coach.die()
      ctx.log(string.format("[loss] t=%d coach died with 2 tourists, away=%d", game.tick - t0, cA.away))
    end)

    ctx.after(FINISH_AT, function()
      local total = cA.insights_total or 0
      ctx.check("12 tourists boarded at home and beds were held", st.outbound_max >= 1 and st.away_max >= 2
        and st.visitors_max >= 2,
        "max outbound " .. st.outbound_max .. ", max away " .. st.away_max .. ", max visitors " .. st.visitors_max)
      ctx.check("13 arrival at the Spa pays nothing", st.visitors_max >= 2
        and st.insights_at_first_visit ~= nil and st.insights_at_first_visit == 0,
        "max visitors " .. st.visitors_max .. ", insights at arrival " .. tostring(st.insights_at_first_visit))
      ctx.check("14 a repeated stop at the host pays nothing",
        st.host_stops_with_visitors > 0 and st.insights_during_visit_max == 0,
        st.host_stops_with_visitors .. " host stops, max insights during visits " .. st.insights_during_visit_max)
      ctx.check("15 the return group was visited and boarded home", st.return_max >= 1 and st.visited_seen,
        "max return riders " .. st.return_max)
      ctx.check("16 the first insight was paid on the home alight",
        st.first_insight_tick ~= nil and st.first_insight > 0 and st.total_before_inject >= 1,
        "first insight " .. st.first_insight .. " at t=" .. tostring(st.first_insight_tick)
          .. ", lifetime " .. tostring(st.total_before_inject))
      ctx.check("17 held beds were released at home",
        st.away_at_insight ~= nil and st.away_at_insight < (st.away_pre_pay_max or 0),
        "away " .. tostring(st.away_pre_pay_max) .. " -> " .. tostring(st.away_at_insight))
      ctx.check("18 stat and panel agree", colony_mod.stats(cA).insights_total == total
        and colony_mod.stats(cA).visitors == 0,
        "panel total " .. tostring(colony_mod.stats(cA).insights_total))
      ctx.check("19 visitors never became host residents", st.host_pop_max == 0 and st.no_bed_host,
        "max host pop " .. st.host_pop_max)
      ctx.check("20 visitors never took host jobs", st.bad_jobs == 0, st.bad_jobs .. " bad states")
      ctx.check("21 group/visit/stat data is plain (save/load safe)", st.plain_data)
      ctx.check("22 coach loss pays nothing and releases beds",
        (cA.insights_total or 0) == st.loss_baseline and st.away_min_after_loss ~= nil
          and st.away_min_after_loss <= st.loss_away_before - 2,
        string.format("lifetime total %d -> %d, away %d -> min %s", st.loss_baseline,
          cA.insights_total or 0, st.loss_away_before, tostring(st.away_min_after_loss)))
      ctx.check("23 pure payout predicate rejects self-host and unvisited groups",
        tourism.earns_insight({kind = "tourist_return", home = cA.id, host = cA.id, visited = true, n = 1}, cA.id) == false
          and tourism.earns_insight({kind = "tourist_return", home = cA.id, host = cB.id, visited = false, n = 1}, cA.id) == false
          and tourism.earns_insight({kind = "tourist_return", home = cA.id, host = cB.id, visited = true, n = 1}, cA.id) == true)
      ctx.check("24 visit, cap and bonus constants match the documented values",
        tourism.INSIGHT_HALF_LIFE == 12 and tourism.VISIT_TICKS == 6000
          and tourism.HOME_TOURIST_CAP == 2 and tourism.W_TOURISM == 0.10
          and tourism.W_HOSPITALITY == 0.05)
      ctx.check("25 a host with visitors still sends its homeless resident by rail",
        st.c_homeless_sent >= 1, "homeless departures seen: " .. st.c_homeless_sent)
      ctx.finish()
    end)
  end,
})

-- Save/load anti-exploit path (REVIEW.md MINOR 4): build the same rail pair, let a real tourist board and
-- alight at the Spa, then save *mid-visit*. The load spec runs in a new process and must see exactly one
-- payout per visitor when the resumed trip reaches home - no event re-fires on load and no double credit.
local function build_persist_pair(ctx)
  local s = ctx.surface
  s.request_to_generate_chunks({x = 70, y = 0}, 6)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-12, -10}, {152, 26}}}) do
    if e.type ~= "character" and e.valid then e.destroy() end
  end
  local tiles = {}
  for x = -12, 152 do
    for y = -10, 26 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  s.set_tiles(tiles, true)
  s.always_day, s.freeze_daytime = true, true
  local function build(name, pos, dir)
    return s.create_entity{name = name, position = pos, direction = dir, force = "player", raise_built = true}
  end
  storage.interval_override = 150
  local hallA, hallB = build("colony-town-hall", HALL_A), build("colony-town-hall", HALL_B)
  local cA, cB = colony_of(hallA), colony_of(hallB)
  cA.accept_migrants, cB.accept_migrants = false, false
  hallA.insert{name = "raw-fish", count = 600}
  hallB.insert{name = "raw-fish", count = 600}
  local cabin = build("colony-housing-cabin", {8, 4})
  if cabin then cabin.insert{name = "raw-fish", count = 60} end
  for _, h in pairs(cA.houses) do h.breed_ready = 2 ^ 31 end
  build("colony-spa", {114, -6})
  for x = 15, 131, 2 do
    s.create_entity{name = "straight-rail", position = {x, ROW}, direction = defines.direction.east, force = "player"}
  end
  local stopA = build("train-stop", {15, STOP_A}, defines.direction.west)
  local stopB = build("train-stop", {131, STOP_B}, defines.direction.east)
  stopA.backer_name, stopB.backer_name = "SAVE-A", "SAVE-B"
  build("colony-passenger-platform", {17, 14})
  build("colony-passenger-platform", {137, 16})
  local loco1 = build("locomotive", {60, ROW}, defines.direction.east)
  local coach = build("colony-passenger-coach", {67, ROW}, defines.direction.east)
  local loco2 = build("locomotive", {74, ROW}, defines.direction.west)
  for _, l in ipairs({loco1, loco2}) do l.get_fuel_inventory().insert{name = "coal", count = 50} end
  local wait = {{type = "time", ticks = 240, compare_type = "and"}}
  loco1.train.schedule = {current = 1, records = {{station = "SAVE-A", wait_conditions = wait},
    {station = "SAVE-B", wait_conditions = wait}}}
  loco1.train.manual_mode = false
  for _ = 1, 2 do colony_mod.spawn_colonist(cA) end
  return cA, cB, coach
end

core.register("m2_tourism_save", {
  issue = 51, auto = false, desc = "save a real tourist mid-visit (scripts/tourism-save-load.sh phase 1)", usage = "",
  run = function(ctx)
    local cA, cB, coach = build_persist_pair(ctx)
    storage.tourism_save_expected = nil
    local function monitor()
      local visitors = adapter.here(cB)
      if #visitors >= 1 and (cA.away or 0) >= 1 then
        local exp = {home = cA.id, host = cB.id, visitors = #visitors, away = cA.away,
          total = cA.insights_total or 0, schema = storage.schema,
          coach = coach and coach.valid and coach.unit_number or nil}
        storage.tourism_save_expected = exp
        ctx.check("mid-trip visit and held bed registered before save",
          exp.visitors >= 1 and exp.away >= 1 and exp.total == 0,
          string.format("visitors=%d away=%d total=%d", exp.visitors, exp.away, exp.total))
        game.server_save("colony-tourism")
        ctx.check("save requested mid-visit", true)
        return
      end
      ctx.after(60, monitor)
    end
    ctx.after(60, monitor)
  end,
})

core.register("m2_tourism_load", {
  issue = 51, auto = false, desc = "post-load: one insight per visitor, no duplicate payout on load", usage = "",
  run = function(ctx)
    local exp = storage.tourism_save_expected
    ctx.check("mid-trip state survived the save", exp ~= nil and exp.visitors >= 1 and exp.away >= 1)
    if not exp then return ctx.finish() end
    local cA = storage.colonies[exp.home]
    local cB = storage.colonies[exp.host]
    ctx.check("both colonies survived with schema 42", cA ~= nil and cB ~= nil and storage.schema == 42,
      "schema " .. tostring(storage.schema))
    if not (cA and cB) then return ctx.finish() end
    ctx.check("visitors and held beds survived with no payout on load",
      #adapter.here(cB) == exp.visitors and (cA.away or 0) == exp.away
        and (cA.insights_total or 0) == exp.total,
      string.format("visitors %d/%d, away %d/%d, total %d/%d", #adapter.here(cB), exp.visitors,
        cA.away or 0, exp.away, cA.insights_total or 0, exp.total))
    -- Stop *new* departures so only the pending return can pay; a fresh trip takes >6000 ticks anyway.
    for un in pairs(cA.colonists) do cA.locks[un] = "haul" end

    local target, paid_at, load_t0 = exp.total + exp.visitors, nil, game.tick
    local function poll()
      local total = cA.insights_total or 0
      if not paid_at and total >= target then
        paid_at = game.tick
        ctx.check("post-load alight pays exactly one insight per visitor", total == target,
          total .. "/" .. target)
        ctx.check("held beds released at the post-load payout",
          (cA.away or 0) <= exp.away - exp.visitors + 1,
          "away " .. tostring(cA.away))
        ctx.after(600, function()
          ctx.check("no duplicate payout on later stops", (cA.insights_total or 0) == target,
            tostring(cA.insights_total))
          ctx.finish()
        end)
        return
      end
      if game.tick - load_t0 < 16000 then ctx.after(60, poll)
      else
        ctx.check("post-load alight pays exactly one insight per visitor", false,
          "no payout within 16000 ticks (total " .. total .. "/" .. target .. ")")
        ctx.finish()
      end
    end
    ctx.after(60, poll)
  end,
})
