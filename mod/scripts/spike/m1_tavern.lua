-- M1 tavern spike (#48): haulers stock a Tavern with ale, the houses within 24 tiles are served and Inspired, a house
-- 36 tiles away is not, the ale is used up, and the buff drops once the ale is gone. Daytime is frozen.
-- Run: TICKS=5000 scripts/headless-spike.sh m1_tavern
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local recreation = require("scripts.model.recreation")
local territory = require("scripts.territory")

local SERVING = "colony-status.tavern-serving"

core.register("m1_tavern", {
  issue = 48, auto = true, desc = "tavern: ale hauled in, near house inspired, far house not, ale used, buff drops", usage = "",
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
    storage.interval_override = 150          -- fast colony evaluations
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not (c and hall and hall.valid) then return ctx.finish() end

    -- Watchtower far out so the territory reaches the far house (same as m1_colony).
    local tower = build("colony-watchtower", {p.x + 40, p.y})
    ctx.check("watchtower built inside territory", tower and tower.valid)

    local tavern = build("colony-tavern", {p.x, p.y + 6})
    ctx.check("tavern built inside territory", tavern and tavern.valid)
    if not (tavern and tavern.valid) then return ctx.finish() end
    ctx.check("tavern registered in c.taverns", c.taverns ~= nil and c.taverns[tavern.unit_number] ~= nil)
    ctx.check("tavern starts empty", tavern.get_item_count(recreation.ITEM) == 0)

    local tent_a = build("colony-housing-tent", {p.x - 7, p.y - 7})          -- ~15 tiles from the tavern
    local tent_b = build("colony-housing-tent", {p.x + 36, p.y + 6})         -- 36 tiles from the tavern
    ctx.check("tent A built", tent_a and tent_a.valid)
    ctx.check("tent B built inside territory", tent_b and tent_b.valid, tent_b and tent_b.valid and "" or "no territory?")
    if not (tent_a and tent_a.valid and tent_b and tent_b.valid) then return ctx.finish() end
    ctx.check("tent B is more than 30 tiles from the tavern",
      math.sqrt((tent_b.position.x - tavern.position.x) ^ 2 + (tent_b.position.y - tavern.position.y) ^ 2) > 30)

    local forager = build("colony-forager-hut", {p.x - 7, p.y + 7})
    ctx.check("forager hut built", forager and forager.valid)
    for i = 0, 3 do s.create_entity{name = "colony-forage-patch", position = {p.x - 12 + i, p.y + 10}} end

    hall.insert{name = "raw-fish", count = 200}
    hall.insert{name = recreation.ITEM, count = 40}
    hall.insert{name = "colony-basket", count = 3}
    ctx.check("hall holds 40 ale and food", hall.get_item_count(recreation.ITEM) == 40
      and hall.get_item_count("raw-fish") >= 200)

    local t0 = game.tick
    local st = {tav_max = 0, a_inspired = false, b_inspired = false, b_has = false, a_has = false,
      a_res_ok = false, b_res_ok = false, partial = nil, partial_d = nil, labels = {}, samples = 0,
      total_before = nil, strip_tav = nil, strip_inflight = nil, inspired_after_strip = nil,
      recreation_after_strip = nil, ihl_after = nil}

    -- Ale carried by haulers right now (the third bucket of the ale total).
    local function ale_inflight()
      local n = 0
      for _, ust in pairs(storage.unit_state or {}) do
        for _, it in ipairs(ust.carry or {}) do
          if it.item == recreation.ITEM then n = n + it.count end
        end
      end
      return n
    end
    local function ale_total()
      local h = hall.valid and hall.get_item_count(recreation.ITEM) or 0
      local t = tavern.valid and tavern.get_item_count(recreation.ITEM) or 0
      return h + t + ale_inflight()
    end

    -- Poll every 30 ticks: tavern stock, which houses are served, whether residents are Inspired, and the tooltip.
    local function sample()
      local now = game.tick - t0
      st.samples = st.samples + 1
      local ale = tavern.valid and tavern.get_item_count(recreation.ITEM) or 0
      if ale > st.tav_max then st.tav_max = ale end
      local ra = c.houses[tent_a.unit_number]
      local rb = c.houses[tent_b.unit_number]
      if ra and ra.inspired then st.a_inspired = true end
      if rb and rb.inspired then st.b_inspired = true end
      local hh = colony.households(c)
      local la, lb = hh[tent_a.unit_number] or {}, hh[tent_b.unit_number] or {}
      if #la > 0 then
        st.a_has = true
        if colony.is_inspired(c, la[1]) then st.a_res_ok = true end
      end
      if #lb > 0 then
        st.b_has = true
        if not colony.is_inspired(c, lb[1]) then st.b_res_ok = true end
      end
      local r = c.recreation or 0
      if r > 0 and r < 1 then
        st.partial = r
        st.partial_d = c.d_parts and c.d_parts.recreation
      end
      local cs = tavern.valid and tavern.custom_status
      local lab = cs and cs.label and cs.label[1]
      if lab then st.labels[lab] = (st.labels[lab] or 0) + 1 end
      ctx.log(string.format("[poll] t=%d tavern=%d hall=%d inflight=%d rec=%.3f A(res=%d insp=%s) B(res=%d insp=%s) label=%s",
        now, ale, hall.valid and hall.get_item_count(recreation.ITEM) or -1, ale_inflight(), r, #la,
        tostring(ra and ra.inspired), #lb, tostring(rb and rb.inspired), tostring(lab)))
    end
    local function every(last)
      ctx.after(30, function()
        sample()
        if game.tick - t0 < last then every(last) end
      end)
    end
    every(4600)

    -- Phase 1 (t=3000): record the total, then take ALL ale out. Haulers carrying ale must have delivered it first,
    -- or that ale would refill the tavern after the strip, so wait (up to 900 ticks) until nothing is in flight.
    local strip_tick, waited, final = nil, 0, nil
    local function strip()
      if ale_inflight() > 0 and waited < 900 then
        waited = waited + 30
        ctx.after(30, strip)
        return
      end
      st.total_before = ale_total()
      st.strip_inflight = ale_inflight()
      st.strip_tav = tavern.valid and tavern.get_item_count(recreation.ITEM) or 0
      if hall.valid and hall.get_item_count(recreation.ITEM) > 0 then
        hall.remove_item{name = recreation.ITEM, count = hall.get_item_count(recreation.ITEM)}
      end
      if tavern.valid and tavern.get_item_count(recreation.ITEM) > 0 then
        tavern.remove_item{name = recreation.ITEM, count = tavern.get_item_count(recreation.ITEM)}
      end
      strip_tick = game.tick - t0
      ctx.log(string.format("[strip] t=%d total before=%d tavern=%d inflight=%d waited=%d",
        strip_tick, st.total_before, st.strip_tav, st.strip_inflight, waited))
      ctx.after(330, final)               -- two evaluations at 150 ticks after the strip
    end
    ctx.after(3000, strip)

    -- Phase 2 (strip + 330 ticks): the final checks.
    final = function()
      local ra = c.houses[tent_a.unit_number]
      st.inspired_after_strip = (ra and ra.inspired) or false
      st.recreation_after_strip = c.recreation
      st.any_inspired = false
      for _, h in pairs(c.houses) do if h.inspired then st.any_inspired = true end end
      st.ihl_after = ale_total()

      ctx.check("haulers delivered ale to the tavern", st.tav_max > 0, "max in tavern " .. st.tav_max)
      ctx.check("tent A (near tavern) house is inspired", st.a_inspired,
        "tent A has residents: " .. tostring(st.a_has))
      ctx.check("tent B (36 tiles away) house is never inspired", not st.b_inspired,
        "tent B has residents: " .. tostring(st.b_has) .. ", B resident seen uninspired: " .. tostring(st.b_res_ok))
      ctx.check("recreation strictly between 0 and 1 with d_parts.recreation > 0",
        st.partial ~= nil and st.partial_d ~= nil and st.partial_d > 0,
        st.partial and string.format("recreation %.3f, d_parts.recreation %s", st.partial, tostring(st.partial_d))
          or "never observed in (0,1)")
      ctx.check("ale consumed (hall + tavern + in flight went down from 40)",
        st.total_before ~= nil and st.total_before < 40,
        st.total_before and string.format("40 -> %d", st.total_before) or "no strip sample")
      ctx.check("is_inspired true for a resident of tent A", st.a_res_ok,
        "tent A has residents: " .. tostring(st.a_has))
      local n_serving = st.labels[SERVING] or 0
      local seen = {}
      for k, v in pairs(st.labels) do seen[#seen + 1] = k .. "x" .. v end
      ctx.check("tavern custom_status is colony-status.tavern-serving", n_serving > 0,
        n_serving .. " polls; labels seen: " .. table.concat(seen, ", "))
      ctx.check("after taking all ale out: no house inspired and recreation == 0 within two evaluations",
        not st.any_inspired and st.recreation_after_strip == 0,
        string.format("any inspired=%s recreation=%s ale left=%d in flight at strip=%d",
          tostring(st.any_inspired), tostring(st.recreation_after_strip), st.ihl_after, st.strip_inflight or -1))
      ctx.finish()
    end
  end,
})
