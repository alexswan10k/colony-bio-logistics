-- M1 passenger rail spike (#49): colony A (one tent, four colonists) loses its house, so its colonists walk to a
-- Passenger Platform and wait. A train with a Passenger Coach stops there, they board, ride to colony B (200 tiles
-- east, three tents, free beds), and step off as B's colonists. Daytime is frozen; migration is off in both towns
-- so the head counts only move through the train.
-- Rail geometry (probed in this spike, Factorio 2.1): rails sit on odd coordinates, and a train stop only reports a
-- connected rail when it touches the end of the run from the side: stop A at (15, ROW-2) facing west, stop B at
-- (211, ROW+2) facing east (brute force at both ends). Stops on the rail row, or in the middle of the run, never
-- connected. The line is a dead end at each stop, so trains reverse there.
-- Run: TICKS=8000 scripts/headless-spike.sh m1_rail
local core = require("scripts.spike.core")
local colony_mod = require("scripts.colony")
local transit = require("scripts.transit")
local transitm = require("scripts.model.transit")

local ROW = 19                      -- rail row, well south of town (rails snap to odd coordinates)
local STOP_ROW = ROW - 2            -- stop A hangs two rows north of the rail row, facing west
local HALL_A, HALL_B = {x = 0, y = 0}, {x = 200, y = 0}
local FINISH = 6500                 -- ticks after setup when the checks run
local PLAT_PREFIX = "colony-status.platform-"

local function colony_of(hall)
  for _, c in pairs(storage.colonies or {}) do
    if c.hall and c.hall.valid and hall and hall.valid and c.hall.unit_number == hall.unit_number then return c end
  end
end

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

core.register("m1_rail", {
  issue = 49, auto = true, desc = "passenger rail: A's homeless ride a coach to B, arrive and get jobs", usage = "",
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
    ctx.probe("freeze daytime", function() s.always_day = true; s.freeze_daytime = true; return s.daytime end)

    local function build(name, pos, dir)
      return s.create_entity{name = name, position = pos, direction = dir, force = "player", raise_built = true}
    end
    storage.interval_override = 150

    -- Two towns: A at the origin, B 200 tiles east (its own chunk, so its own colony).
    local hallA = build("colony-town-hall", HALL_A)
    local hallB = build("colony-town-hall", HALL_B)
    ctx.check("both town halls built", hallA and hallA.valid and hallB and hallB.valid)
    if not (hallA and hallA.valid and hallB and hallB.valid) then return ctx.finish() end
    local cA, cB = colony_of(hallA), colony_of(hallB)
    local ncol = 0
    for _ in pairs(storage.colonies) do ncol = ncol + 1 end
    ctx.check("two colonies exist (A and B are separate)", cA ~= nil and cB ~= nil and cA ~= cB and ncol >= 2,
      "colonies: " .. ncol)
    if not (cA and cB) then return ctx.finish() end
    cA.accept_migrants, cB.accept_migrants = false, false
    hallA.insert{name = "raw-fish", count = 200}
    hallB.insert{name = "raw-fish", count = 200}
    -- B's houses hold their own food (its colonists would otherwise wait on haulers to starve-proof the test).

    -- Housing: A gets ONE tent (4 beds); B gets three (12 free beds).
    -- Town (hall, houses) sits north at y <= 2 and the rail row is 17 tiles south: a passing train runs over anyone
    -- on the track, and idle colonists wander onto it when it runs through town (colonist 174 at y=6 was killed).
    local tentA = build("colony-housing-tent", {8, 2})
    local tentsB = {build("colony-housing-tent", {194, 2}), build("colony-housing-tent", {206, 2}),
      build("colony-housing-tent", {212, 2})}
    local tentsOk = tentA and tentA.valid
    for _, t in ipairs(tentsB) do tentsOk = tentsOk and t and t.valid end
    ctx.check("A has one tent and B has three tents built", tentsOk)
    if tentsOk then for _, t in ipairs(tentsB) do t.insert{name = "raw-fish", count = 40} end end
    if not tentsOk then return ctx.finish() end

    -- Dead-end line: rails from x=15 to x=211 on ROW, one west-facing stop at each end.
    local rails = 0
    for x = 15, 211, 2 do
      if s.create_entity{name = "straight-rail", position = {x, ROW}, direction = defines.direction.east, force = "player"} then
        rails = rails + 1
      end
    end
    ctx.check("laid the rail line", rails >= 95, rails .. " rails")
    local stopA = build("train-stop", {15, STOP_ROW}, defines.direction.west)
    local stopB = build("train-stop", {211, ROW + 2}, defines.direction.east)   -- stop B hangs south, facing east
    if stopA then stopA.backer_name = "RAIL-A" end
    if stopB then stopB.backer_name = "RAIL-B" end
    local connA = stopA ~= nil and stopA.valid and stopA.connected_rail ~= nil
    local connB = stopB ~= nil and stopB.valid and stopB.connected_rail ~= nil
    ctx.check("train stops placed and connected to the rail line", connA and connB,
      "A connected=" .. tostring(connA) .. " B connected=" .. tostring(connB))
    if not (connA and connB) then return ctx.finish() end

    -- Passenger Platforms within 10 tiles of their stop and inside each colony's territory (the hall's chunk).
    local platA = build("colony-passenger-platform", {17, 14})
    local platB = build("colony-passenger-platform", {217, 16})
    ctx.check("both platforms built inside territory", platA and platA.valid and platB and platB.valid)
    if not (platA and platA.valid and platB and platB.valid) then return ctx.finish() end
    ctx.check("platforms are within 10 tiles of their stop",
      dist(platA.position, stopA.position) <= 10 and dist(platB.position, stopB.position) <= 10,
      string.format("A %.1f B %.1f", dist(platA.position, stopA.position), dist(platB.position, stopB.position)))

    -- Train: loco - coach - loco, both locomotives fuelled, schedule A stop <-> B stop, 5 s wait at each.
    local loco1 = build("locomotive", {101, ROW}, defines.direction.east)
    local coach = build("colony-passenger-coach", {108, ROW}, defines.direction.east)
    local loco2 = build("locomotive", {115, ROW}, defines.direction.west)
    ctx.check("train assembled (2 locomotives + colony-passenger-coach)", loco1 and coach and loco2 and loco1.train
      and loco1.train.valid and loco1.train.id == coach.train.id)
    if not (loco1 and coach and loco2) then return ctx.finish() end
    for _, l in ipairs({loco1, loco2}) do l.get_fuel_inventory().insert{name = "coal", count = 40} end
    local train = loco1.train
    local wait = {{type = "time", ticks = 300, compare_type = "and"}}
    ctx.probe("set schedule via train.schedule (RW)", function()
      train.schedule = {current = 1, records = {
        {station = "RAIL-A", wait_conditions = wait},
        {station = "RAIL-B", wait_conditions = wait},
      }}
      local sc = train.schedule
      return sc and (#sc.records .. " records, current " .. sc.current) or "nil"
    end)
    train.manual_mode = false

    -- Make A homeless: four colonists in A's only tent, then the tent is destroyed once they are all in.
    local spawned = 0
    for _ = 1, 4 do if colony_mod.spawn_colonist(cA) then spawned = spawned + 1 end end
    ctx.check("spawned 4 colonists in A", spawned == 4, spawned)

    local t0 = game.tick
    local st = {waiting_max = 0, riders_max = 0, a_min = nil, b_max = 0, rec_seen = false, labels = {},
      text_ok = false, text_detail = nil, riders_at_b = {}, a_before = nil, total_before = nil,
      destroyed_at = nil}

    local function live(c) return colony_mod.live_colonists(c) end

    local function sample()
      local now = game.tick - t0
      local a, b = live(cA), live(cB)
      if st.destroyed_at == nil and a >= 3 and tentA.valid then
        st.a_before = a
        st.total_before = a + live(cB)
        tentA.destroy{raise_destroy = true}
        st.destroyed_at = now
        ctx.log(string.format("[tent] t=%d A destroyed its tent with %d colonists", now, a))
      end
      local waiting = 0
      for un in pairs(cA.colonists) do
        local us = storage.unit_state[un]
        if us and us.state == "waiting_train" then waiting = waiting + 1 end
      end
      if waiting > st.waiting_max then st.waiting_max = waiting end
      if st.a_before and (st.a_min == nil or a < st.a_min) then st.a_min = a end
      if b > st.b_max then st.b_max = b end
      st.last_pos = st.last_pos or {}
      for un, c in pairs(cB.colonists) do
        if c.valid then st.last_pos[un] = string.format("%d(%.0f,%.0f)", un, c.position.x, c.position.y) end
      end
      if st.b_prev and b < st.b_prev then
        local gone = {}
        for un, lp in pairs(st.last_pos) do if not (cB.colonists[un] and cB.colonists[un].valid) then gone[#gone + 1] = lp end end
        ctx.log("[drop-B] vanished (last seen): " .. table.concat(gone, " "))
        local parts = {}
        for un, c in pairs(cB.colonists) do
          local us = storage.unit_state[un]
          parts[#parts + 1] = string.format("%d[%s|%s|%s]", un, tostring(c.valid), us and tostring(us.state) or "nostate",
            c.valid and string.format("%.0f,%.0f", c.position.x, c.position.y) or "-")
        end
        ctx.log(string.format("[drop-B] t=%d B %d -> %d; B colonists: %s", now, st.b_prev, b, table.concat(parts, " ")))
      end
      if b > (st.b_prev or 0) and not st.arrival_snap then
        -- Snapshot the new arrivals right after they stepped off (job state at that moment).
        local near, jobs = 0, {}
        for un, c in pairs(cB.colonists) do
          if c.valid and dist(c.position, platB.position) <= 12 then
            near = near + 1
            local us = storage.unit_state[un]
            local key = us and (tostring(us.job) .. "/" .. tostring(us.state)) or "no state"
            jobs[key] = (jobs[key] or 0) + 1
          end
        end
        local jl = {}
        for k, v in pairs(jobs) do jl[#jl + 1] = k .. " x" .. v end
        st.arrival_snap = {near = near, jobs = jobs, text = near .. " near; " .. table.concat(jl, ", "), t = now}
      end
      st.b_prev = b
      local rec = coach.valid and storage.coaches and storage.coaches[coach.unit_number]
      local riders = rec and transitm.riders(rec.groups) or 0
      if riders > st.riders_max then st.riders_max = riders end
      if rec and rec.text and rec.text.valid and riders > 0 then
        st.text_ok = true
        st.text_detail = tostring(rec.text.text)
      end
      if riders > 0 then st.rec_seen = true end
      if train.valid and train.station and train.station == stopB then
        st.riders_at_b[#st.riders_at_b + 1] = riders
      end
      local ps = platA.valid and platA.custom_status
      local lab = ps and ps.label and ps.label[1]
      if lab then st.labels[tostring(lab)] = (st.labels[tostring(lab)] or 0) + 1 end
      ctx.log(string.format("[poll] t=%d A=%d B=%d waiting=%d riders=%d station=%s label=%s train_state=%s D_A=%.2f D_B=%.2f deathsB=%d fishB=%d",
        now, a, b, waiting, riders, train.valid and train.station and train.station.backer_name or "-", tostring(lab),
        train.valid and tostring(train.state) or "-", cA.d or -1, cB.d or -1, #cB.deaths, hallB.get_item_count("raw-fish")))
    end
    local function every()
      ctx.after(30, function()
        sample()
        if game.tick - t0 < FINISH then every() else st.finish() end
      end)
    end
    every()

    -- Final checks, once the trains have had several rounds.
    st.finish = function()
      local rec_riders_end = 0
      if coach.valid and storage.coaches and storage.coaches[coach.unit_number] then
        rec_riders_end = transitm.riders(storage.coaches[coach.unit_number].groups)
      end
      ctx.check("1 both platforms registered and transit.stop_of finds each stop",
        cA.platforms and cA.platforms[platA.unit_number] and cB.platforms and cB.platforms[platB.unit_number]
          and transit.stop_of(cA.platforms[platA.unit_number]) == stopA and transit.stop_of(cB.platforms[platB.unit_number]) == stopB,
        "A platforms " .. #colony_mod.platform_list(cA) .. ", B platforms " .. #colony_mod.platform_list(cB))
      ctx.check("2 A colonists reached waiting_train", st.waiting_max > 0, "max waiting " .. st.waiting_max)
      ctx.check("3 coach carried riders and A's population dropped",
        st.riders_max > 0 and st.a_min ~= nil and st.a_before ~= nil and st.a_min < st.a_before,
        string.format("max riders %d, A before %s, A min %s", st.riders_max, tostring(st.a_before), tostring(st.a_min)))
      local zero_at_b = false
      for _, r in ipairs(st.riders_at_b) do if r == 0 then zero_at_b = true end end
      ctx.check("4 B's population rose by the riders and the coach was empty at B",
        st.b_max > 0 and zero_at_b,
        string.format("B max %d, samples at B stop %d (riders there: %s)", st.b_max, #st.riders_at_b,
          table.concat(st.riders_at_b, ",")))

      -- Arrivals: standing near B's platform right after they stepped off, each with a unit_state (job or state).
      local snap = st.arrival_snap or {near = 0, jobs = {}, text = "no arrival seen"}
      ctx.check("5 arrivals stand near B's platform and have a job state",
        snap.near > 0 and (snap.jobs["no state"] or 0) == 0, "at t=" .. tostring(snap.t) .. ": " .. snap.text)

      local seen = {}
      for k, v in pairs(st.labels) do seen[#seen + 1] = k .. " x" .. v end
      local plat_ok = false
      for k in pairs(st.labels) do if k:sub(1, #PLAT_PREFIX) == PLAT_PREFIX then plat_ok = true end end
      ctx.check("6 platform tooltip custom_status.label[1] reads colony-status.platform-*", plat_ok,
        table.concat(seen, ", "))

      local total_after = live(cA) + live(cB) + rec_riders_end
      ctx.check("7 no colonists lost (A before = A after + B after + riders)",
        st.total_before ~= nil and total_after == st.total_before,
        string.format("before %s, after A=%d B=%d riders=%d (sum %d)", tostring(st.total_before), live(cA), live(cB),
          rec_riders_end, total_after))

      ctx.check("8 rider text rendering exists on the coach while riders > 0", st.text_ok,
        st.text_detail and ("text: " .. st.text_detail) or ("riders seen: " .. tostring(st.rec_seen)))
      ctx.finish()
    end
  end,
})
