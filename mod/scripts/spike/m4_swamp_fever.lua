-- M4 Swamp Fever spike (#70): the whole story on a real associated Gleba surface - planet guard, spore exposure,
-- the new disease's counters/desirability, half-speed work, a Clinic cure, and an untreated death.
-- Run: TICKS=3600 scripts/headless-spike.sh m4_swamp_fever
--
-- Unlike the earlier seeded-only version, this now drives the REAL paths the review required:
--   * NATURAL CATCH: no seeded sickness, 20 on-duty colonists on Gleba with full spore exposure, several real
--     colony evaluations -> a genuine storage.sick swamp_fever record appears (off-duty children stay well).
--   * NATURAL EMISSION: a real Smokehouse `work.finish` on raw Gleba fruit raises local spores by exactly
--     SPORE_PER_HARVEST on Gleba; the same recipe on Nauvis raises no pollution at all.
--   * SEEDED CHECKS: counters/desirability, a Clinic cure, and an untreated death stay deterministic.
-- Engine facts (pollutant_type names, 2-arg pollute, 3-arg pollute failure, is_spore on Nauvis) are probed here
-- for the integrated report but pinned in detail by s21_gleba_spores.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local planet = require("scripts.planet")
local scheduler = require("scripts.scheduler")
local tech_mod = require("scripts.tech")
local gleba = require("scripts.model.gleba")
local illness_model = require("scripts.model.illness")
local illness_adapter = require("scripts.illness")

core.register("m4_swamp_fever", {
  issue = 70, auto = true,
  desc = "Swamp Fever: natural catch + Smokehouse spores + counters/desirability/half speed/cure/death on Gleba",
  usage = "",
  run = function(ctx)
    -- ---------- the real associated Gleba surface ----------
    local g = game.planets["gleba"]
    local gs
    ctx.probe("game.planets.gleba -> surface", function()
      if not g then return "NO PLANET" end
      if g.surface then gs = g.surface; return "existing " .. gs.name end
      local ok, s = pcall(function() return g.create_surface() end)
      if not ok then return "create_surface ERROR: " .. tostring(s) end
      gs = s
      return "created " .. tostring(s and s.name)
    end)
    if not gs then ctx.check("Gleba surface exists", false, "no planet/surface"); return ctx.finish() end
    ctx.surface, ctx.position = gs, {x = 0, y = 0}
    local p, s = ctx.position, gs
    ctx.flat_area(60, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local nauvis = game.surfaces[1]

    -- Engine facts, already pinned by s21 (probes here, not hard assertions).
    ctx.probe("Gleba pollutant_type", function()
      return "planet=" .. tostring(s.planet and s.planet.name) ..
        " pollutant_type=" .. tostring(s.pollutant_type and s.pollutant_type.name) ..
        " is_gleba=" .. tostring(planet.is_gleba(s)) .. " is_spore=" .. tostring(planet.is_spore(s))
    end)

    -- ---------- the colony ----------
    storage.interval_override = 150
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local hall = build("colony-town-hall", {p.x, p.y})
    local id = territory.owner_at(s.index, p)
    local c = id and storage.colonies[id]
    ctx.check("colony registered on the Gleba surface", c ~= nil and hall and hall.valid and c.surface_index == s.index,
      "surface_index=" .. tostring(c and c.surface_index) .. " gleba=" .. tostring(s.index))
    if not (c and hall and hall.valid) then return ctx.finish() end
    c.accept_migrants = false
    build("colony-housing-cabin", {p.x - 6, p.y - 9})
    build("colony-housing-cabin", {p.x + 6, p.y - 9})
    local clinic = build("colony-clinic", {p.x + 8, p.y + 6})
    ctx.check("clinic registered as a labour hut (job heal)", clinic and clinic.valid and c.huts[clinic.unit_number]
      and c.huts[clinic.unit_number].job == "heal")
    local smoke = build("colony-smokehouse", {p.x - 16, p.y + 12})
    ctx.check("Smokehouse registered as a labour hut (job preserve)", smoke and smoke.valid and c.huts[smoke.unit_number]
      and c.huts[smoke.unit_number].job == "preserve")
    hall.insert{name = "raw-fish", count = 5000}       -- enough food for 20 colonists over several evaluations
    for i = 1, 20 do
      colony.spawn_colonist(c, {p.x - 8 + (i % 8) * 2, p.y - 4 + math.floor((i - 1) / 8) * 2})
    end
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    ctx.check("twenty colonists spawned", #ids == 20, "ids=" .. tostring(#ids))
    if #ids < 20 then return ctx.finish() end

    -- ---------- planet + pure-rule checks ----------
    ctx.check("planet.is_gleba true on the hall's surface", planet.is_gleba(hall.surface) == true)
    ctx.check("planet.is_spore true on the hall's surface", planet.is_spore(hall.surface) == true)
    ctx.check("planet.is_spore false on Nauvis", planet.is_spore(nauvis) == false)
    ctx.check("chop and forage emit spores, mine does not", gleba.emits_spores("chop") == true and
      gleba.emits_spores("forage") == true and gleba.emits_spores("mine") == false)
    ctx.check("raw Gleba fruit is recognised by is_raw", gleba.is_raw("yumako") == true and
      gleba.is_raw("jellynut") == true and gleba.is_raw("yumako-mash") == true and
      gleba.is_raw("colony-gleba-jam") == false and gleba.is_raw("colony-meat") == false)
    ctx.check("a sick colonist takes twice as long over a job", illness_model.work_ticks(480, true) == 960,
      tostring(illness_model.work_ticks(480, true)))
    ctx.check("swamp fever is fatal after the documented 24 evaluations",
      illness_model.DISEASES.swamp_fever.fatal_after == 24,
      tostring(illness_model.DISEASES.swamp_fever.fatal_after))
    ctx.check("only on-duty states catch an occupational disease",
      illness_model.on_duty{job = "chop", state = "working"} == true and
      illness_model.on_duty{job = "chop", state = "child"} == false and
      illness_model.on_duty{job = "chop", state = "waiting_train"} == false)

    -- The localised caption is built on every fell/death message. Headless has no player/GUI to render a
    -- localised string, so its resolution is covered by the locale audit in tests/locale_test.lua; here we pin
    -- the exact key the adapter hands to the engine.
    ctx.probe("colony-illness.swamp_fever caption key", function()
      local key = {"colony-illness." .. "swamp_fever"}
      return "built=" .. tostring(key[1]) .. " (resolution: tests/locale_test.lua, no player in headless)"
    end)

    -- ---------- spore emissions on a spore surface vs Nauvis (engine facts) ----------
    s.set_pollution(p, 0)
    local before_spore = s.get_pollution(p)
    s.pollute(p, gleba.SPORE_PER_HARVEST)                  -- TWO args
    local after_spore = s.get_pollution(p)
    ctx.probe("2-arg pollute on the spore surface", function()
      return "SPORE_PER_HARVEST=" .. tostring(gleba.SPORE_PER_HARVEST) .. " before=" .. tostring(before_spore) ..
        " after=" .. tostring(after_spore)
    end)
    ctx.check("a scripted harvest raises spore pollution on Gleba", after_spore > before_spore)

    -- ---------- phase 1: NATURAL CATCH, zero seeded sickness ----------
    s.clear_pollution()
    ctx.check("no sickness seeded before natural exposure", next(storage.sick or {}) == nil)
    s.set_pollution(p, 600)                                -- full exposure: 0.5 + 600/300 -> clamped to 1
    ctx.check("high spore pollution gives full exposure", gleba.exposure(s.get_pollution(p)) == 1,
      tostring(s.get_pollution(p)))
    local off = {ids[#ids - 1], ids[#ids]}
    storage.age = storage.age or {}
    for _, un in ipairs(ids) do
      storage.unit_state[un] = {colony_id = c.id, job = "chop", state = "working"}
    end
    for _, un in ipairs(off) do                            -- off-duty children: identical air, no occupational risk
      storage.age[un] = {stage = "child", born = game.tick}
      storage.unit_state[un] = {colony_id = c.id, job = "child", state = "child"}
    end

    ctx.after(900, function()   -- six real colony evaluations at 150 ticks each
      local swamp, total = 0, 0
      for _, rec in pairs(storage.sick or {}) do
        total = total + 1
        if rec.kind == "swamp_fever" then swamp = swamp + 1 end
      end
      ctx.check("natural exposure catches swamp fever with zero seeded sickness", swamp > 0,
        swamp .. " swamp-fever records of " .. total .. " sick")
      ctx.check("off-duty children do not catch the occupational disease",
        storage.sick[off[1]] == nil and storage.sick[off[2]] == nil)

      -- ---------- phase 2: NATURAL EMISSION from a real Smokehouse work.finish ----------
      for _, un in ipairs(off) do storage.age[un] = nil end   -- restore them to adults for the seeded phases
      s.clear_pollution()                                    -- an exact +15 emission reading needs clean air
      local f = game.forces.player
      f.technologies[gleba.TECH].researched = true
      tech_mod.sync_force(f)
      smoke.insert{name = "yumako", count = 4}
      smoke.insert{name = "colony-salt", count = 4}
      local hut = c.huts[smoke.unit_number]
      local before = s.get_pollution(smoke.position)
      storage.unit_state[ids[1]] = {colony_id = c.id, job = "preserve", state = "working", hut = hut, site = smoke}
      scheduler.after(1, "work.finish", {un = ids[1]})     -- the real adapter path, not a stub
      -- Read 2 ticks later: the engine diffuses/decays spore pollution every tick, so a long wait would hide
      -- the exact +15 burst even though the adapter wrote precisely that into surface.pollute.
      ctx.after(2, function()
        local after = s.get_pollution(smoke.position)
        ctx.check("a real Gleba Smokehouse trip emits exactly SPORE_PER_HARVEST spores",
          math.abs((after - before) - gleba.SPORE_PER_HARVEST) < 1e-6,
          before .. " -> " .. after .. " (expected +" .. tostring(gleba.SPORE_PER_HARVEST) .. ")")
        ctx.check("the real recipe consumed its raw fruit and salt",
          smoke.get_item_count("yumako") == 2 and smoke.get_item_count("colony-salt") == 3,
          "yumako=" .. smoke.get_item_count("yumako") .. " salt=" .. smoke.get_item_count("colony-salt"))

        -- The same recipe on Nauvis: force-wide tech, same stock, same real work.finish, no spore surface.
        nauvis.request_to_generate_chunks({x = 0, y = 0}, 3)
        nauvis.force_generate_chunk_requests()
        local np = nauvis.find_non_colliding_position("colony-town-hall", {x = 0, y = 0}, 20, 1) or {x = 0, y = 0}
        for _, e in pairs(nauvis.find_entities_filtered{area = {{np.x - 20, np.y - 20}, {np.x + 20, np.y + 20}}}) do
          if e.type ~= "character" and e.valid then e.destroy() end
        end
        local nHall = nauvis.create_entity{name = "colony-town-hall", position = np, force = "player", raise_built = true}
        local nc = nHall and nHall.valid and storage.colonies[territory.owner_at(nauvis.index, np)]
        local nsp = nauvis.find_non_colliding_position("colony-smokehouse", {np.x - 8, np.y + 6}, 10, 1)
          or {np.x - 8, np.y + 6}
        local nSmoke = nauvis.create_entity{name = "colony-smokehouse", position = nsp, force = "player", raise_built = true}
        if nSmoke then
          nSmoke.insert{name = "yumako", count = 4}
          nSmoke.insert{name = "colony-salt", count = 4}
        end
        local nHut = nc and nSmoke and nc.huts[nSmoke.unit_number]
        local nUn = nc and colony.spawn_colonist(nc)
        nauvis.set_pollution(nsp, 0)
        local beforeN = nauvis.get_pollution(nsp)
        ctx.check("Nauvis control colony and Smokehouse built", nHut ~= nil and nUn ~= nil and nHut ~= false and nUn ~= false,
          "hall=" .. tostring(nHall and nHall.valid) .. " colony=" .. tostring(nc and nc.id) ..
          " smoke=" .. tostring(nSmoke and nSmoke.valid) .. " colonist=" .. tostring(nUn))
        local nUnId = nUn and nUn.unit_number
        if nUnId and nHut then
          storage.unit_state[nUnId] = {colony_id = nc.id, job = "preserve", state = "working", hut = nHut, site = nSmoke}
          scheduler.after(1, "work.finish", {un = nUnId})
        end
        ctx.after(2, function()
          ctx.probe("Nauvis work.finish state", function()
            local st = nUnId and storage.unit_state[nUnId]
            return "state=" .. tostring(st and st.state) .. " job=" .. tostring(st and st.job) ..
              " hut_valid=" .. tostring(nHut and nHut.entity and nHut.entity.valid) ..
              " site_valid=" .. tostring(nSmoke and nSmoke.valid) ..
              " yumako=" .. tostring(nSmoke and nSmoke.get_item_count("yumako"))
          end)
        end)
        ctx.after(90, function()
          local afterN = nauvis.get_pollution(nsp)
          ctx.check("the same Gleba recipe on Nauvis adds no spore pollution", afterN == beforeN,
            beforeN .. " -> " .. afterN)
          ctx.check("the Nauvis Smokehouse still consumed its fruit", nSmoke and nSmoke.get_item_count("yumako") == 2)

          -- ---------- phase 3: seeded counters, desirability and a Clinic cure ----------
          -- Keep everyone off duty for the seeded phases: with 20 colonists and the 0.5 clean-air baseline,
          -- real evaluations could otherwise add noise cases and break the exact counters below. Registering
          -- them as children makes work.assign hold them at job="child" instead of handing out new trips.
          local function all_off_duty()
            storage.age = storage.age or {}
            for _, un in ipairs(ids) do
              storage.age[un] = {stage = "child", born = game.tick}
              storage.unit_state[un] = {colony_id = c.id, job = "child", state = "child"}
            end
          end
          local function only_sick(un, age)
            storage.sick = storage.sick or {}
            for u in pairs(storage.sick) do storage.sick[u] = nil end
            storage.sick[un] = {kind = "swamp_fever", age = age}
          end
          all_off_duty()
          only_sick(ids[1], 0)

          ctx.after(480, function()
            ctx.check("swamp fever counted in sick_swamp_fever", (c.sick_swamp_fever or 0) >= 1,
              tostring(c.sick_swamp_fever))
            ctx.check("swamp fever included in the combined sick count", (c.sick_count or 0) >= 1,
              tostring(c.sick_count))
            ctx.check("the swamp patient is not double-counted as lung/poison",
              (c.sick_lung or 0) == 0 and (c.sick_poison or 0) == 0,
              "lung=" .. tostring(c.sick_lung) .. " poison=" .. tostring(c.sick_poison))
            ctx.check("sickness cost desirability", c.d_parts and c.d_parts.sickness < 0,
              c.d_parts and string.format("%.3f", c.d_parts.sickness) or "no parts")

            -- One doctor on duty, picked with the largest roll so the exposure roll cannot give it swamp fever too.
            all_off_duty()
            only_sick(ids[1], 1)
            local doc, best = nil, -1
            for i = 2, #ids do
              local un = ids[i]
              local r = illness_model.roll(un, game.tick, 3)
              if r > best then best, doc = r, un end
            end
            local exposure = doc and gleba.exposure(s.get_pollution(c.colonists[doc] and c.colonists[doc].position or p)) or 0
            ctx.check("doctor's exposure roll cannot add a second case", doc ~= nil and
              illness_model.catches("swamp_fever", exposure, best) == false,
              "doctor=" .. tostring(doc) .. " roll=" .. string.format("%.3f", best))
            local st = doc and storage.unit_state[doc]
            if not st then return ctx.finish() end
            st.job, st.state, st.hut = "heal", "working", c.huts[clinic.unit_number]
            local function medicine_total()
              return (clinic.valid and clinic.get_item_count(illness_model.MEDICINE) or 0) +
                hall.get_item_count(illness_model.MEDICINE)
            end
            clinic.insert{name = illness_model.MEDICINE, count = 5}
            local before_med = medicine_total()
            local ok, err = pcall(function() illness_adapter.evaluate(c, {}) end)
            ctx.probe("colony evaluation with a Clinic doctor", function()
              return "ok=" .. tostring(ok) .. " err=" .. tostring(err)
            end)
            local after_med = medicine_total()
            ctx.check("a Clinic doctor cures a swamp-fever patient", storage.sick[ids[1]] == nil,
              "rec=" .. tostring(storage.sick[ids[1]] and storage.sick[ids[1]].kind))
            ctx.check("the swamp counter drops when the patient is cured", (c.sick_swamp_fever or 0) == 0,
              tostring(c.sick_swamp_fever))
            ctx.check("one Herbal Medicine is consumed per cure", after_med == before_med - 1,
              before_med .. " -> " .. after_med)
            all_off_duty()

            -- ---------- phase 4: untreated swamp fever kills at the documented age ----------
            ctx.after(960, function()
              clinic.remove_item{name = illness_model.MEDICINE, count = 100}
              hall.remove_item{name = illness_model.MEDICINE, count = 100}
              all_off_duty()
              local victim = ids[3]
              only_sick(victim, illness_model.DISEASES.swamp_fever.fatal_after - 1)  -- step increments before the check
              local fallen0 = c.fallen or 0
              local ok2, err2 = pcall(function() illness_adapter.evaluate(c, {}) end)
              ctx.probe("colony evaluation with an untreated patient", function()
                return "ok=" .. tostring(ok2) .. " err=" .. tostring(err2)
              end)
              ctx.check("an untreated swamp-fever patient dies on the next evaluation", c.last_death == "illness",
                tostring(c.last_death))
              ctx.check("the death increments fallen exactly once", (c.fallen or 0) == fallen0 + 1,
                tostring(fallen0) .. " -> " .. tostring(c.fallen))
              ctx.check("the dead colonist is struck off the roster", c.colonists[victim] == nil)
              ctx.check("the death record is removed from storage.sick", storage.sick[victim] == nil)
              ctx.finish()
            end)
          end)
        end)
      end)
    end)
  end,
})
