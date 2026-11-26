-- M2 recreation amenities (#48 slice B): a Theatre (no workers, no ale, 16-tile ring) Inspires the houses near
-- it at quality 1.5 - a house 36 tiles away stays uninspired, scholars beat the Tavern's research rate for the
-- same inspired share, and Theatre work trips are 480 -> 320 ticks. Scenic Plazas add a capped term to the
-- hall's four-evaluation scenic sample; removing the buildings removes both effects. Daytime is frozen.
-- Run: TICKS=4800 scripts/headless-spike.sh m2_recreation
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local work = require("scripts.work")
local inspiration = require("scripts.model.inspiration")
local theatre = require("scripts.model.theatre")
local plaza = require("scripts.model.plaza")

core.register("m2_recreation", {
  issue = 48, auto = true,
  desc = "theatre: near house inspired at 1.5, far house not, research beats tavern rate, work 480->320; plazas: capped scenic bonus, both removed on demolition",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(80, "grass-1")
    ctx.probe("freeze daytime", function()
      s.always_day = true
      s.freeze_daytime = true
      return s.daytime
    end)
    local force = game.forces["player"]
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = force, raise_built = true}
    end

    storage.interval_override = 150          -- fast colony evaluations; scenic samples every 4 of them
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not (c and hall and hall.valid) then return ctx.finish() end

    -- Territory and the two amenities. The watchtower is only there to match the other colony spikes.
    build("colony-watchtower", {p.x + 40, p.y})
    local theatre_e = build("colony-theatre", {p.x, p.y + 6})
    ctx.check("theatre built inside territory", theatre_e and theatre_e.valid)
    if not (theatre_e and theatre_e.valid) then return ctx.finish() end
    ctx.check("theatre registered in c.theatres", c.theatres ~= nil and c.theatres[theatre_e.unit_number] ~= nil)

    local near = build("colony-housing-tent", {p.x - 7, p.y - 7})    -- ~15 tiles from the theatre
    local far = build("colony-housing-tent", {p.x + 36, p.y + 6})    -- 36 tiles from the theatre
    ctx.check("near tent built", near and near.valid)
    ctx.check("far tent built inside territory", far and far.valid)
    if not (near and near.valid and far and far.valid) then return ctx.finish() end
    local dx, dy = far.position.x - theatre_e.position.x, far.position.y - theatre_e.position.y
    ctx.check("far tent is beyond the theatre's 16-tile radius", math.sqrt(dx * dx + dy * dy) > theatre.RADIUS,
      string.format("distance %.2f", math.sqrt(dx * dx + dy * dy)))

    -- A powered Town Archive with a deterministic scholar cohort (lowest unit numbers live in the first tent).
    local ap = {x = p.x - 10, y = p.y}
    ctx.power_at(ap)
    local archive = build("colony-town-archive", ap)
    if archive and archive.valid then archive.insert{name = "colony-frontier-pack", count = 20} end
    force.technologies["colony-settlement"].researched = true
    force.research_queue = {"colony-frontier-charter"}

    hall.insert{name = "raw-fish", count = 300}
    hall.insert{name = "colony-ale", count = 20}    -- no Tavern: the Theatre must stand on its own
    hall.insert{name = "colony-basket", count = 3}
    for _ = 1, 6 do colony.spawn_colonist(c) end
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    for i = 1, math.min(2, #ids) do
      c.locks[ids[i]] = "research"
      work.assign(c, ids[i])
    end
    ctx.log("scholars locked: " .. table.concat(ids, ","))

    -- Pure rule, checked before the async phases so it cannot be skipped by a timeout.
    ctx.check("theatre work ticks: inspiration.work_ticks(480, 1.5) == 320",
      inspiration.work_ticks(480, theatre.QUALITY) == 320,
      "got " .. tostring(inspiration.work_ticks(480, theatre.QUALITY)))

    local t0 = game.tick
    local st = {baseline = nil, plazas = {}, t_ready = nil}
    local ready, with_plazas, no_theatre, no_plazas

    -- Phase 1: wait for the near house and the scholars to be Inspired by the Theatre.
    ready = function(waited)
      local hn, hf = c.houses[near.unit_number], c.houses[far.unit_number]
      local ins = c.inspiration
      if (not (hn and hn.inspired)) or (hf and hf.inspired) or not ins or ins.share <= 0
          or ins.quality ~= theatre.QUALITY then
        if waited >= 1800 then
          ctx.check("theatre inspired the near house and scholars in time", false,
            string.format("near=%s far=%s share=%s quality=%s", tostring(hn and hn.inspired),
              tostring(hf and hf.inspired), tostring(ins and ins.share), tostring(ins and ins.quality)))
          return ctx.finish()
        end
        ctx.after(60, function() ready(waited + 60) end)
        return
      end
      st.t_ready, st.baseline = game.tick - t0, c.scenic or 0

      local rec = c.theatres[theatre_e.unit_number]
      ctx.check("theatre still registered after several evaluations",
        rec ~= nil and rec.entity.valid and #colony.theatre_list(c) == 1)
      ctx.check("near house inspired at theatre quality", hn.inspiration_quality == theatre.QUALITY,
        "quality=" .. tostring(hn.inspiration_quality))
      ctx.check("far house is not inspired", not (hf and hf.inspired))

      local hh = colony.households(c)
      local residents = hh[near.unit_number] or {}
      table.sort(residents)
      local resident = residents[1]
      local quality = resident and colony.inspiration_quality(c, resident) or 0
      ctx.check("adapter inspiration_quality of a near resident is 1.5", quality == theatre.QUALITY,
        string.format("resident=%s quality=%s", tostring(resident), tostring(quality)))
      ctx.check("colony.inspiration.quality is theatre quality", ins.quality == theatre.QUALITY,
        "quality=" .. tostring(ins.quality))

      local expected = inspiration.research_bonus(ins.share, ins.quality)
      local mod = force.laboratory_speed_modifier
      -- Only one of the two scholars happens to live in the near tent here (share = 0.5), so the absolute
      -- modifier is 0.25 - what a FULLY staffed Tavern would give. The Theatre's edge is per-inspired-scholar:
      -- (1.5-1)*share beats (1.25-1)*share for the same cohort. The exact research_bonus is pinned too.
      ctx.check("theatre scholars beat the tavern rate for the same inspired share",
        mod > (inspiration.TAVERN - 1) * ins.share + 1e-9 and math.abs(mod - expected) < 1e-9,
        string.format("share=%.3f quality=%s modifier=%.6f tavern-rate=%.6f expected=%.6f",
          ins.share, tostring(ins.quality), mod, (inspiration.TAVERN - 1) * ins.share, expected))
      ctx.check("recreation is positive with d_parts.recreation > 0",
        (c.recreation or 0) > 0 and (c.d_parts and c.d_parts.recreation or 0) > 0,
        string.format("recreation=%s d_part=%s", tostring(c.recreation), tostring(c.d_parts and c.d_parts.recreation)))
      ctx.check("theatre tooltip counts occupied houses and inspired residents",
        rec ~= nil and (rec.houses or 0) > 0 and (rec.inspired or 0) > 0,
        rec and string.format("houses=%d inspired=%d", rec.houses, rec.inspired) or "no record")
      -- The real feedback tooltips, not just the registry counters: advice.theatre takes flat facts, so a
      -- wrapper here would silently leave every field nil and show the "idle" line on a working Theatre.
      local tcs = theatre_e.valid and theatre_e.custom_status
      local tlabel = tcs and tcs.label and tcs.label[1]
      ctx.check("theatre feedback tooltip reports serving, not idle", tlabel == "colony-status.theatre-serving",
        "label=" .. tostring(tlabel))

      ctx.after(60, with_plazas)
    end
    ctx.after(450, function() ready(450) end)

    -- Phase 2: four Plazas, all inside the hall's 40-tile scenic radius (19.8 tiles each).
    with_plazas = function()
      for _, pos in ipairs({{p.x + 14, p.y + 14}, {p.x - 14, p.y + 14},
          {p.x + 14, p.y - 14}, {p.x - 14, p.y - 14}}) do
        local e = build("colony-scenic-plaza", pos)
        if e and e.valid then st.plazas[#st.plazas + 1] = e end
      end
      local registered = 0
      for _, e in ipairs(st.plazas) do if c.plazas and c.plazas[e.unit_number] then registered = registered + 1 end end
      ctx.check("four plazas registered in c.plazas", #st.plazas == 4 and registered == 4,
        string.format("built=%d registered=%d", #st.plazas, registered))
      ctx.after(700, no_theatre)   -- >= 4 evaluations: at least one full scenic cadence after the build
    end

    -- Phase 3: the capped scenic bonus is live; then demolish the Theatre.
    no_theatre = function()
      ctx.check("scenic score rises after building plazas", (c.scenic or 0) > st.baseline,
        string.format("baseline=%.4f now=%.4f (t_ready=%d)", st.baseline, c.scenic or 0, st.t_ready or -1))
      local pb = c.scenic_parts and c.scenic_parts.plaza or 0
      ctx.check("scenic_parts.plaza is the capped four-plaza bonus",
        pb == plaza.bonus(4) and plaza.bonus(4) == plaza.CAP and (c.plaza_count or 0) == 4,
        string.format("part=%.4f bonus(4)=%.4f cap=%.4f count=%s", pb, plaza.bonus(4), plaza.CAP,
          tostring(c.plaza_count)))
      local pcs = st.plazas[1].valid and st.plazas[1].custom_status
      local plabel = pcs and pcs.label and pcs.label[1]
      ctx.check("plaza feedback tooltip reports the scenic bonus, not zero",
        plabel == "colony-status.plaza-scenic", "label=" .. tostring(plabel))
      if theatre_e.valid then theatre_e.destroy() end
      ctx.after(330, function()   -- two evaluations at 150 ticks
        local any = false
        for _, h in pairs(c.houses) do if h.inspired then any = true end end
        ctx.check("destroying the theatre clears inspiration within two evaluations",
          not any and (c.inspiration and c.inspiration.quality or 0) == 0,
          string.format("any_inspired=%s quality=%s", tostring(any), tostring(c.inspiration and c.inspiration.quality)))
        ctx.check("lab modifier returns to base when the theatre is gone",
          math.abs(force.laboratory_speed_modifier) < 1e-9,
          "modifier=" .. tostring(force.laboratory_speed_modifier))
        for _, e in ipairs(st.plazas) do if e.valid then e.destroy() end end
        ctx.after(700, no_plazas)
      end)
    end

    -- Phase 4: another full scenic cadence after the Plaza demolition.
    no_plazas = function()
      local pb = c.scenic_parts and c.scenic_parts.plaza or 0
      ctx.check("destroying plazas drops the scenic bonus to zero", pb == 0 and (c.plaza_count or 0) == 0,
        string.format("part=%.4f count=%s", pb, tostring(c.plaza_count)))
      ctx.check("scenic returns to the pre-plaza baseline", math.abs((c.scenic or 0) - st.baseline) < 1e-9,
        string.format("baseline=%.4f now=%.4f", st.baseline, c.scenic or 0))
      ctx.finish()
    end
  end,
})
