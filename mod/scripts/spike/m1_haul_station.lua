-- M1 haul station spike (#94): a Haul Station is distributed colony storage, and a hauler checks a Wooden
-- Trailer out of the nearest station in reach for one 3x hand-load on foot, cheap bulk hauling before the
-- Motor Pool (#60). The load is claimed at checkout, the trailer is returned at delivery (worn like a tool),
-- and the station sources/deposits like a Warehouse. Daytime is frozen so night cannot interfere.
-- Run: TICKS=9000 scripts/headless-spike.sh m1_haul_station
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local feedback = require("scripts.feedback")
local work = require("scripts.work")
local trailer = require("scripts.model.trailer")

core.register("m1_haul_station", {
  issue = 94, auto = true, desc = "haul station: distributed storage, trailer checkout for 60, return and wear", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(80, "grass-1")
    ctx.probe("freeze daytime", function()
      s.always_day = true
      s.freeze_daytime = true
      return s.daytime
    end)
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not c then return ctx.finish() end

    local tent_a = build("colony-housing-tent", {p.x - 7, p.y - 7})
    local tent_b = build("colony-housing-tent", {p.x - 7, p.y + 7})
    ctx.check("houses built", tent_a and tent_a.valid and tent_b and tent_b.valid)
    hall.insert{name = "raw-fish", count = 200}
    ctx.check("food stocked", hall.get_item_count("raw-fish") >= 200)

    local station = build("colony-haul-station", {p.x - 15, p.y})
    ctx.check("haul station built inside territory", station and station.valid)
    if not (station and station.valid) then return ctx.finish() end
    ctx.check("haul station registered", c.crates[station.unit_number] ~= nil)
    ctx.check("station is kind station", c.crates[station.unit_number].kind == "station")
    station.insert{name = trailer.TRAILER_ITEM, count = 1}
    ctx.check("station holds a trailer", station.get_item_count(trailer.TRAILER_ITEM) == 1)

    local crate = build("colony-supply-crate", {p.x + 30, p.y + 4})
    ctx.check("supply crate built 30 tiles out", crate and crate.valid and c.crates[crate.unit_number] ~= nil)
    if not (crate and crate.valid) then return ctx.finish() end
    crate.insert{name = "iron-ore", count = 100}
    ctx.check("crate holds 100 iron ore", crate.get_item_count("iron-ore") == 100)

    ctx.probe("trailer numbers", function()
      return string.format("cap %d speed %.1f uses %d reach %d", trailer.CAPACITY, trailer.SPEED, trailer.USES, trailer.REACH)
    end)

    local t0 = game.tick
    local st = {trailer_out_at = nil, max_carry = 0, hall_max = 0, seen_trailer = false, speed_seen = false,
      speed_penalty = false, wear_seen = false}

    local function sample()
      local now = game.tick - t0
      if station.valid and st.trailer_out_at == nil and station.get_item_count(trailer.TRAILER_ITEM) == 0 then
        st.trailer_out_at = now
      end
      for un, ust in pairs(storage.unit_state or {}) do
        if ust and ust.trailer then
          st.seen_trailer = true
          local carried = 0
          for _, it in ipairs(ust.carry or {}) do carried = carried + it.count end
          if carried > st.max_carry then st.max_carry = carried end
          local e = c.colonists[un]
          if e and e.valid and ust.trailer_speed then
            st.speed_seen = true
            local ok, cur = pcall(function() return e.speed end)
            if ok and cur and cur < ust.trailer_speed then st.speed_penalty = true end
          end
        end
      end
      local hall_ore = hall.valid and hall.get_item_count("iron-ore") or 0
      if hall_ore > st.hall_max then st.hall_max = hall_ore end
      if station.valid and st.trailer_out_at then
        local rec = c.crates[station.unit_number]
        if rec and (rec.trailer_wear or 0) > 0 then st.wear_seen = true end
      end
    end
    local function every(last)
      ctx.after(30, function()
        sample()
        if game.tick - t0 < last then every(last) end
      end)
    end
    every(8500)

    ctx.after(1500, function()
      local pop = colony.live_colonists(c)
      ctx.check("colonists arrived to haul", pop >= 2, pop)
    end)

    ctx.after(8500, function()
      sample()
      ctx.check("a trailer was checked out", st.seen_trailer or st.trailer_out_at ~= nil)
      ctx.check("trailer carried more than 20 items at once", st.max_carry > 20, st.max_carry .. " max carried")
      ctx.check("trailer carried the full 60 at once", st.max_carry >= trailer.CAPACITY, st.max_carry)
      ctx.check("trailer returned to the station", station.valid and station.get_item_count(trailer.TRAILER_ITEM) >= 1,
        station.valid and (station.get_item_count(trailer.TRAILER_ITEM) .. " trailers") or "gone")
      ctx.check("hall gained >= 60 iron ore", hall.valid and hall.get_item_count("iron-ore") >= 60,
        hall.valid and (hall.get_item_count("iron-ore") .. " (max seen " .. st.hall_max .. ")") or "gone")
      ctx.check("crate emptied", crate.valid and crate.get_item_count("iron-ore") == 0,
        crate.valid and (crate.get_item_count("iron-ore") .. " left") or "gone")
      local rec = station.valid and c.crates[station.unit_number]
      ctx.check("station wear advanced", st.wear_seen or (rec and (rec.trailer_wear or 0) > 0),
        rec and ("wear " .. (rec.trailer_wear or 0) .. " out " .. (rec.trailers_out or 0)) or "gone")
      ctx.check("no trailers leaked out", rec and (rec.trailers_out or 0) == 0, rec and ("out " .. (rec.trailers_out or 0)) or "gone")
      -- Feedback (#94): the station reports its trailer state on hover, the way a Motor Pool reports its cars.
      feedback.update(c)
      local cs = station.valid and station.custom_status
      local key = cs and type(cs.label) == "table" and tostring(cs.label[1]) or nil
      ctx.check("the station reports its trailers on hover", key ~= nil and key:find("^colony%-status%.station%-") ~= nil,
        key or "none")
      -- An aborted trip must lift the trailer's speed penalty. The restore lives in return_trailer, because that is
      -- the one place every trip ends: delivery, a path the engine gave up on, nightfall, a hut that vanished. When
      -- it lived only on the delivery paths, a colonist that gave up mid-trip walked at trailer speed for good.
      local driver
      for un in pairs(c.colonists) do
        local e = c.colonists[un]
        if e and e.valid then driver = e; break end
      end
      local base
      local ok_speed = driver and pcall(function() base = driver.speed end)
      if ok_speed and base and base > 0 then
        local rec2 = c.crates[station.unit_number]
        rec2.trailers_out = (rec2.trailers_out or 0) + 1
        local trip = {colony_id = c.id, job = "haul", state = "to_house", un = driver.unit_number,
          trailer = true, trailer_station = rec2, trailer_speed = base, carry = {{item = "iron-ore", count = 1}}}
        pcall(function() driver.speed = base * trailer.SPEED end)
        work.release(trip)
        local after
        pcall(function() after = driver.speed end)
        ctx.check("aborting a trailer trip restores walking speed",
          after ~= nil and math.abs(after - base) <= base * 0.01,
          string.format("slowed %.3f, after release %s (base %.3f)", base * trailer.SPEED, tostring(after), base))
        ctx.check("the aborted trip's trailer went back to the station",
          rec2.trailers_out == 0 and station.get_item_count(trailer.TRAILER_ITEM) >= 1,
          (rec2.trailers_out or 0) .. " out")
      else
        ctx.check("aborting a trailer trip restores walking speed", false, "unit speed not readable")
      end
      ctx.probe("trailer speed penalty applied", function()
        return st.speed_penalty and "unit speed lowered while hauling with trailer"
          or (st.speed_seen and "speed readable, penalty not confirmed" or "no trailer-speed sample (trip may have finished before poll)")
      end)
      ctx.finish()
    end)
  end,
})
