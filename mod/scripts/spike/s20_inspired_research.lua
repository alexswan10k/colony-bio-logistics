-- s20: Inspired research engine lever (#48 slice A).
-- Proves the force-wide laboratory_speed_modifier is raised by Inspired scholars, self-heals an engine
-- technology-effects reset, and drops back to base when the ale runs out or the Tavern is gone. The engine
-- facts (LuaForce.laboratory_speed_modifier is RW double; reset_technology_effects wipes script modifiers and
-- raises on_technology_effects_reset with the force) are pinned against the 2.1 docs in STAGE_A.md.
-- Run: TICKS=5000 scripts/headless-spike.sh s20_inspired_research
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local work = require("scripts.work")
local inspiration = require("scripts.model.inspiration")

core.register("s20_inspired_research", {
  issue = 48, auto = true,
  desc = "inspired scholars raise the force lab modifier; reset self-heals; strip ale or remove tavern drops it",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(70, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local force = game.forces["player"]
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = force, raise_built = true}
    end

    storage.interval_override = 150              -- fast colony evaluations
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil)
    if not (c and hall and hall.valid) then return ctx.finish() end

    -- A Tavern and three houses inside its 24-tile radius; the scholars (lowest unit numbers, so housing
    -- assignment fills these tents first) live in two of them.
    local tavern = build("colony-tavern", {p.x, p.y + 6})
    ctx.check("tavern built", tavern and tavern.valid)
    local tents = {
      build("colony-housing-tent", {p.x - 6, p.y - 6}),
      build("colony-housing-tent", {p.x, p.y - 6}),
      build("colony-housing-tent", {p.x + 6, p.y - 6}),
    }
    ctx.check("three tents built", tents[1].valid and tents[2].valid and tents[3].valid)

    -- A real Town Archive, powered and stocked with colony packs, researching a cheap colony tech.
    local ap = {x = p.x - 10, y = p.y}
    ctx.power_at(ap)
    local archive = build("colony-town-archive", {ap.x, ap.y})
    ctx.check("archive built", archive and archive.valid)
    if archive and archive.valid then archive.insert{name = "colony-frontier-pack", count = 20} end
    force.technologies["colony-settlement"].researched = true
    force.research_queue = {"colony-frontier-charter"}

    hall.insert{name = "raw-fish", count = 300}
    hall.insert{name = "colony-ale", count = 60}
    for _ = 1, 6 do colony.spawn_colonist(c) end
    -- Lock the two lowest-numbered colonists to research so there is a deterministic scholar cohort.
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    for i = 1, math.min(2, #ids) do
      c.locks[ids[i]] = "research"
      work.assign(c, ids[i])
    end
    ctx.log("scholars locked: " .. table.concat(ids, ","))

    local t0 = game.tick
    local st = {inspired_mod = nil, share = nil, ready = false, reset_ok = nil,
      after_strip_mod = nil, after_strip_share = nil, after_remove_mod = nil, after_remove_quality = nil,
      rate0 = nil, rate1 = nil}

    local function ale_inflight()
      local n = 0
      for _, ust in pairs(storage.unit_state or {}) do
        for _, it in ipairs(ust.carry or {}) do
          if it.item == "colony-ale" then n = n + it.count end
        end
      end
      return n
    end

    local strip, rates
    -- Poll until the tavern has ale, houses are served, and the two scholars are on duty and Inspired.
    local function wait_inspired(waited)
      if game.tick - t0 > 3000 then
        ctx.check("scholars became Inspired in time", false,
          string.format("share=%s quality=%s ale=%d", tostring(c.inspiration and c.inspiration.share),
            tostring(c.inspiration and c.inspiration.quality),
            tavern.valid and tavern.get_item_count("colony-ale") or -1))
        return ctx.finish()
      end
      local ins = c.inspiration
      if tavern.valid and tavern.get_item_count("colony-ale") > 0 and ins and ins.share > 0 then
        st.ready, st.share, st.inspired_mod = true, ins.share, force.laboratory_speed_modifier
        ctx.check("Inspired scholars raise the force lab modifier",
          st.inspired_mod > 0 and st.inspired_mod <= 0.25 + 1e-9,
          string.format("share=%.3f quality=%s modifier=%.6f", st.share, tostring(ins.quality), st.inspired_mod))
        local expected = inspiration.research_bonus(ins.share, ins.quality)
        ctx.check("modifier equals the pure research_bonus rule", math.abs(st.inspired_mod - expected) < 1e-9,
          string.format("got %.6f expected %.6f", st.inspired_mod, expected))
        -- LuaForce::reset_technology_effects wipes script modifiers and raises on_technology_effects_reset;
        -- our load-time handler must self-heal without waiting for the next colony evaluation.
        force.reset_technology_effects()
        st.reset_ok = math.abs(force.laboratory_speed_modifier - st.inspired_mod) < 1e-9
        ctx.check("technology-effects reset self-heals the Inspired bonus", st.reset_ok,
          string.format("modifier after reset %.6f (was %.6f)", force.laboratory_speed_modifier, st.inspired_mod))
        ctx.after(120, function() strip(0) end)
      else
        ctx.after(60, function() wait_inspired(waited + 60) end)
      end
    end
    ctx.after(300, function() wait_inspired(300) end)

    -- Strip every bucket of ale (wait for haulers to deliver what they carry), then let two evaluations pass.
    strip = function(waited)
      if ale_inflight() > 0 and waited < 900 then
        ctx.after(30, function() strip(waited + 30) end)
        return
      end
      if hall.valid then
        local n = hall.get_item_count("colony-ale")
        if n > 0 then hall.remove_item{name = "colony-ale", count = n} end
      end
      if tavern.valid then
        local n = tavern.get_item_count("colony-ale")
        if n > 0 then tavern.remove_item{name = "colony-ale", count = n} end
      end
      ctx.log(string.format("[strip] t=%d inflight=%d ale left hall=%d tavern=%d",
        game.tick - t0, ale_inflight(), hall.valid and hall.get_item_count("colony-ale") or -1,
        tavern.valid and tavern.get_item_count("colony-ale") or -1))
      ctx.after(360, function()
        st.after_strip_mod = force.laboratory_speed_modifier
        st.after_strip_share = c.inspiration and c.inspiration.share
        ctx.check("no inspiration when the ale is gone", st.after_strip_share == 0,
          "share=" .. tostring(st.after_strip_share))
        ctx.check("lab modifier drops back to base when inspiration ends",
          math.abs(st.after_strip_mod) < 1e-9, "modifier=" .. tostring(st.after_strip_mod))
        if tavern.valid then tavern.destroy() end
        ctx.after(240, function()
          st.after_remove_mod = force.laboratory_speed_modifier
          st.after_remove_quality = c.inspiration and c.inspiration.quality
          ctx.check("removing the tavern clears inspiration quality", st.after_remove_quality == 0,
            "quality=" .. tostring(st.after_remove_quality))
          ctx.check("lab modifier stays at base with no tavern",
            math.abs(st.after_remove_mod) < 1e-9, "modifier=" .. tostring(st.after_remove_mod))
          rates()
        end)
      end)
    end

    -- Engine fact: laboratory_speed_modifier = 1 roughly doubles progress of a powered, stocked lab. Done last,
    -- with no inspiration left, so the adapter cannot overwrite the measured values between windows.
    rates = function()
      if archive.valid then archive.insert{name = "colony-frontier-pack", count = 20} end
      force.research_progress = 0
      force.laboratory_speed_modifier = 0
      local progress0 = force.research_progress
      ctx.after(180, function()
        st.rate0 = force.research_progress - progress0
        force.research_progress = 0
        force.laboratory_speed_modifier = 1
        ctx.after(180, function()
          st.rate1 = force.research_progress
          -- Pin the claimed 2x: both windows must actually progress, and the ratio must be 2 (within a
          -- small tolerance). The old `rate0 == 0 and rate1 > 0 or rate1 > rate0 * 1.3` passed any positive
          -- rate1 when the first window happened to be empty, and never asserted 2x.
          local ratio = st.rate0 > 0 and (st.rate1 / st.rate0) or 0
          ctx.check("force lab modifier = 1 doubles research progress (ratio within 1.9..2.1)",
            st.rate0 > 0 and st.rate1 > 0 and ratio >= 1.9 and ratio <= 2.1,
            string.format("rate0=%.6f rate1=%.6f ratio=%.4f", st.rate0, st.rate1, ratio))
          ctx.finish()
        end)
      end)
    end
  end,
})
