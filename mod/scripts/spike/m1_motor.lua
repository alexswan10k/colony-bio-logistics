-- M1 motor pool spike (#60): a Motor Pool checks a car out for a big haul, a colony truck carries it, the truck
-- parks again, and the driver is released. Daytime is frozen so night cannot park the truck mid-test.
-- Run: TICKS=6000 scripts/headless-spike.sh m1_motor
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local motor = require("scripts.model.motor")

core.register("m1_motor", {
  issue = 60, auto = true, desc = "motor pool: car out, truck hauls 100, parks, driver released", usage = "",
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
    storage.interval_override = 150          -- fast colony evaluations so migrants arrive well inside the window
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

    local pool = build("colony-motor-pool", {p.x - 15, p.y})
    ctx.check("motor pool built inside territory", pool and pool.valid)
    if not (pool and pool.valid) then return ctx.finish() end
    ctx.check("motor pool registered with the colony", c.pools[pool.unit_number] ~= nil)
    pool.insert{name = "car", count = 1}
    pool.insert{name = "coal", count = 10}
    ctx.check("pool holds a car and 10 coal", pool.get_item_count("car") == 1 and pool.get_item_count("coal") == 10)

    local crate = build("colony-supply-crate", {p.x + 30, p.y + 4})
    ctx.check("supply crate built 30 tiles out", crate and crate.valid and c.crates[crate.unit_number] ~= nil)
    if not (crate and crate.valid) then return ctx.finish() end
    crate.insert{name = "iron-ore", count = 100}
    ctx.check("crate holds 100 iron ore", crate.get_item_count("iron-ore") == 100)

    -- Prototype speeds: the truck is meant to walk 2.5x a colonist.
    ctx.probe("prototype movement_speed truck vs colonist", function()
      local tr = prototypes.entity["colony-truck"].speed
      local co = prototypes.entity["colony-colonist"].speed
      return string.format("truck %.3f colonist %.3f (x%.2f) [prototype.speed]", tr, co, tr / co)
    end)

    local t0 = game.tick
    local st = {seen = false, car_out_at = nil, parked_at = nil, max_carry = 0, carry_max_at = nil,
      samples = 0, last_pos = nil, max_step = 0, path = 0, first_pos = nil, max_disp = 0,
      hall_max = 0, driver = nil, pool_coal_min = 99, car_back_seen = false}

    -- Poll every 30 ticks: track the truck, its carried load, its path and the stock it brings home.
    local function sample()
      local now = game.tick - t0
      local tr = storage.trucks or {}
      local live_un, live_t
      for tun, t in pairs(tr) do
        if t.entity and t.entity.valid then live_un, live_t = tun, t end
      end
      if not st.car_out_at and pool.valid and pool.get_item_count("car") == 0 then st.car_out_at = now end
      if pool.valid then st.pool_coal_min = math.min(st.pool_coal_min, pool.get_item_count("coal")) end
      if pool.valid and st.car_out_at and not st.parked_at and pool.get_item_count("car") == 1 and not live_un then
        st.car_back_seen = true
      end
      local hall_ore = hall.valid and hall.get_item_count("iron-ore") or 0
      if hall_ore > st.hall_max then st.hall_max = hall_ore end
      if live_un then
        local e = live_t.entity
        if not st.seen then
          st.seen, st.seen_at, st.driver, st.truck_un = true, now, live_t.driver, live_un
          st.first_pos = {x = e.position.x, y = e.position.y}
          st.last_pos = st.first_pos
          local d = c.colonists[st.driver]
          ctx.check("a truck is checked out within 4000 ticks", now <= 4000, now .. " ticks")
          ctx.check("car left the pool for the truck", st.car_out_at ~= nil and pool.get_item_count("car") == 0)
          ctx.check("driver is in state driving", (storage.unit_state[st.driver] or {}).state == "driving",
            tostring((storage.unit_state[st.driver] or {}).state))
          local dd = d and d.valid and math.sqrt((d.position.x - pool.position.x) ^ 2 + (d.position.y - pool.position.y) ^ 2)
          ctx.check("driver waits on the pool", dd and dd < 1.5, dd and string.format("%.2f tiles from pool", dd) or "no driver")
        end
        local ust = storage.unit_state[live_un] or {}
        local carried = 0
        for _, it in ipairs(ust.carry or {}) do carried = carried + it.count end
        if carried > st.max_carry then st.max_carry, st.carry_max_at = carried, now end
        -- Path: the truck is a moving unit, so its position must change with each poll.
        local pos = e.position
        st.samples = st.samples + 1
        local dx, dy = pos.x - st.last_pos.x, pos.y - st.last_pos.y
        local step = math.sqrt(dx * dx + dy * dy)
        st.path = st.path + step
        if step > st.max_step then st.max_step = step end
        st.last_pos = {x = pos.x, y = pos.y}
        local ex, ey = pos.x - st.first_pos.x, pos.y - st.first_pos.y
        local disp = math.sqrt(ex * ex + ey * ey)
        if disp > st.max_disp then st.max_disp = disp end
        ctx.log(string.format("[truck] t=%d state=%s carry=%d pos=(%.1f,%.1f) step=%.2f",
          now, tostring(ust.state), carried, pos.x, pos.y, step))
      elseif st.seen and not st.parked_at then
        st.parked_at = now
        ctx.log("[truck] parked at t=" .. now)
      end
    end
    local function every(last)
      ctx.after(30, function()
        sample()
        if game.tick - t0 < last then every(last) end
      end)
    end
    every(4900)

    ctx.after(1500, function()
      local pop = colony.live_colonists(c)
      ctx.check("colonists arrived to haul", pop >= 2, pop)
    end)

    ctx.after(5000, function()
      ctx.check("a truck was checked out at all", st.seen)
      ctx.check("truck carried more than 20 items at once", st.max_carry > 20, st.max_carry .. " max carried")
      ctx.check("truck carried the full 100 at once", st.max_carry >= motor.CAPACITY, st.max_carry)
      ctx.check("truck moved along a path", st.max_disp > 5,
        string.format("disp %.1f, path %.1f over %d polls, max step %.2f", st.max_disp, st.path, st.samples, st.max_step))
      ctx.check("crate emptied", crate.valid and crate.get_item_count("iron-ore") == 0,
        crate.valid and crate.get_item_count("iron-ore") or "gone")
      ctx.check("hall gained >= 100 iron ore", hall.get_item_count("iron-ore") >= 100,
        hall.get_item_count("iron-ore") .. " (max seen " .. st.hall_max .. ")")
      ctx.check("truck parked: storage.trucks empty", next(storage.trucks or {}) == nil,
        st.parked_at and ("parked at t=" .. st.parked_at) or "still out")
      ctx.check("pool has its car back", pool.valid and pool.get_item_count("car") == 1,
        pool.valid and pool.get_item_count("car") or "gone")
      ctx.check("coal burnt from the pool", pool.valid and pool.get_item_count("coal") <= 9,
        pool.valid and (pool.get_item_count("coal") .. " coal left") or "gone")
      local d = st.driver and c.colonists[st.driver]
      local dst = st.driver and (storage.unit_state[st.driver] or {}).state
      ctx.check("driver still alive", d and d.valid, "")
      ctx.check("driver no longer driving", dst ~= "driving", tostring(dst))
      if d and d.valid then
        ctx.check("driver is outside the pool", math.abs(d.position.x - pool.position.x) > 0.5
          or math.abs(d.position.y - pool.position.y) > 0.5, string.format("(%.1f,%.1f)", d.position.x, d.position.y))
      end
      ctx.log(string.format("speed: max step %.2f tiles per 30 ticks (~%.3f tiles/tick)", st.max_step, st.max_step / 30))
      ctx.finish()
    end)
  end,
})
