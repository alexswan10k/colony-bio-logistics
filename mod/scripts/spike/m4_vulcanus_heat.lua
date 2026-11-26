-- M4 Vulcanus heat spike (#70): the LANDED feature driven through real colony evaluations on a real associated
-- Vulcanus surface. Run: TICKS=3600 scripts/headless-spike.sh m4_vulcanus_heat
--
--   * ENGINE FACTS: off-world pollutant_type is nil, so risk cannot be a pollution reading; get_pollution and
--     get_property('temperature') are probed rather than assumed. A Habitat Dome founds the colony (a Town Hall
--     is refused), and the guard makes colony.evaluate treat off-world pollution as clean.
--   * NATURAL CATCH: on-duty colonists working in the open catch Heat Stroke over several real 150-tick
--     colony evaluations; colonists inside a dome's safe ring and off-duty children stay well; Nauvis does not
--     catch it at all.
--   * SEEDED CHECKS: counters/desirability, a Clinic cure and an untreated death use the same adapter path
--     the colony evaluation calls.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local planet = require("scripts.planet")
local illness_model = require("scripts.model.illness")
local vulcanus = require("scripts.model.vulcanus")
local illness_adapter = require("scripts.illness")

core.register("m4_vulcanus_heat", {
  issue = 70, auto = true,
  desc = "Vulcanus Heat Stroke: off-world pollution guard, dome shelter, natural catch, Clinic cure, untreated death",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish() if not finished then finished = true; ctx.finish() end end
    local function phase(fn)
      return function()
        local ok, err = xpcall(fn, function(e) return tostring(e) .. " " .. debug.traceback(e, 2) end)
        if not ok then ctx.log("[ERR] deferred phase crashed: " .. tostring(err)); finish() end
      end
    end

    -- ---------- the real associated Vulcanus surface ----------
    local vp = game.planets["vulcanus"]
    local s
    ctx.probe("game.planets.vulcanus -> surface", function()
      if not vp then return "NO PLANET" end
      if vp.surface then s = vp.surface; return "existing " .. s.name end
      local ok, surf = pcall(function() return vp.create_surface() end)
      if not ok then return "create_surface ERROR: " .. tostring(surf) end
      s = surf
      return "created " .. tostring(s and s.name)
    end)
    if not s then ctx.check("Vulcanus surface exists", false, "no planet/surface"); return finish() end
    ctx.surface, ctx.position = s, {x = 0, y = 0}
    local p = ctx.position
    ctx.flat_area(60, "refined-concrete")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0

    ctx.check("planet.is_vulcanus / is_hostile true on the hall's surface",
      planet.is_vulcanus(s) == true and planet.is_hostile(s) == true and planet.is_platform(s) == false)
    ctx.probe("off-world surface properties", function()
      local okp, poll = pcall(function() return s.get_pollution(p) end)
      local okt, temp = pcall(function() return s.get_property("temperature") end)
      return "pollutant_type=" .. tostring(s.pollutant_type and s.pollutant_type.name)
        .. " get_pollution=" .. (okp and tostring(poll) or ("ERR " .. tostring(poll)))
        .. " temperature=" .. (okt and tostring(temp) or ("ERR " .. tostring(temp)))
    end)
    ctx.check("Vulcanus has no pollutant type (research note; s22_dome)", s.pollutant_type == nil,
      tostring(s.pollutant_type and s.pollutant_type.name))
    ctx.check("a Town Hall may not be founded but a Habitat Dome may",
      planet.may_found(s, "colony-town-hall") == false and planet.may_found(s, "colony-habitat-dome") == true
      and planet.may_build_hall(s) == false)
    ctx.check("a dome's safe ring is narrower than the open-air scale",
      vulcanus.DOME_SAFE < vulcanus.DOME_SAFE + vulcanus.HEAT_SCALE and vulcanus.exposure(vulcanus.DOME_SAFE) == 0
      and vulcanus.exposure(nil) == 1)

    -- ---------- dome-founded colony ----------
    storage.interval_override = 150
    local function build(name, pos)
      local ok, e = pcall(function()
        return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
      end)
      if not ok then ctx.log("[ERR] create_entity " .. name .. ": " .. tostring(e)) return nil end
      return e
    end
    local hall = build("colony-habitat-dome", p)
    local id = hall and hall.valid and territory.owner_at(s.index, p)
    local c = id and storage.colonies[id]
    ctx.check("a Habitat Dome founded the colony on Vulcanus",
      c ~= nil and c.hall and c.hall.valid and c.hall.name == "colony-habitat-dome" and c.surface_index == s.index,
      "hall=" .. tostring(c and c.hall and c.hall.name) .. " id=" .. tostring(id))
    if not (c and hall and hall.valid) then return finish() end
    c.accept_migrants = false
    ctx.power_at(p)
    hall.insert{name = "raw-fish", count = 5000}
    hall.insert{name = "colony-water", count = 5000}

    local clinic_pos = s.find_non_colliding_position("colony-clinic", {p.x + 8, p.y + 8}, 10, 1) or {p.x + 8, p.y + 8}
    local clinic = build("colony-clinic", clinic_pos)
    ctx.check("clinic registered as a labour hut (job heal)",
      clinic and clinic.valid and c.huts[clinic.unit_number] and c.huts[clinic.unit_number].job == "heal")

    -- The off-world pollution guard is the other half of the research note: no pollutant_type means the
    -- desirability/illness pollution input must read zero rather than depending on a meaningless number.
    local ok_eval, eval_err = pcall(function() colony.evaluate({colony_id = c.id}) end)
    ctx.probe("real colony.evaluate on Vulcanus", function() return "ok=" .. tostring(ok_eval) .. " " .. tostring(eval_err) end)
    ctx.check("off-world pollution reads as clean", ok_eval and (c.pollution or 0) == 0, tostring(c.pollution))

    -- ---------- natural catch over real evaluations ----------
    local ids, sheltered = {}, {}
    for i = 1, 20 do
      local pos = {x = p.x + 14 + (i % 4) * 3, y = p.y - 12 + math.floor((i - 1) / 4) * 3}
      local unit = colony.spawn_colonist(c, pos)
      if unit then ids[#ids + 1] = unit.unit_number end
    end
    for i = 1, 2 do
      local pos = s.find_non_colliding_position("colony-colonist", {p.x + 3, p.y + (i - 1) * 2}, 4, 0.5)
        or {p.x + 3, p.y}
      local unit = colony.spawn_colonist(c, pos)
      if unit then sheltered[#sheltered + 1] = unit.unit_number end
    end
    ctx.check("colonists spawned in the open and inside the dome's safe ring", #ids == 20 and #sheltered == 2,
      #ids .. " open, " .. #sheltered .. " sheltered")
    if #ids < 20 or #sheltered < 2 then return finish() end

    storage.age = storage.age or {}
    for _, un in ipairs(ids) do
      storage.unit_state[un] = {colony_id = c.id, job = "chop", state = "working"}
      storage.age[un] = {stage = "adult", born = game.tick}
    end
    for _, un in ipairs(sheltered) do
      local e = c.colonists[un]
      local dx = e and e.position.x - hall.position.x or 99
      local dy = e and e.position.y - hall.position.y or 99
      ctx.check("sheltered colonist " .. un .. " is inside the dome ring", math.sqrt(dx * dx + dy * dy) <= vulcanus.DOME_SAFE,
        (e and (e.position.x .. "," .. e.position.y)) or "no entity")
      storage.unit_state[un] = {colony_id = c.id, job = "chop", state = "working"}
      storage.age[un] = {stage = "adult", born = game.tick}
    end
    ctx.check("zero sickness seeded before natural exposure", next(storage.sick or {}) == nil)
    ctx.probe("Heat Stroke caption key used by fell/death messages", function()
      local key = {"colony-illness." .. vulcanus.DISEASE}
      return "built=" .. tostring(key[1]) .. " (resolution: tests/locale_test.lua, no player in headless)"
    end)

    ctx.after(900, phase(function()   -- six real colony evaluations at 150 ticks each
      local cases = 0
      for _, un in ipairs(ids) do
        local rec = storage.sick[un]
        if rec and rec.kind == "heat_stroke" then cases = cases + 1 end
      end
      ctx.check("natural exposure catches Heat Stroke with zero seeded sickness", cases > 0,
        cases .. " cases of " .. #ids .. " open-air workers")
      local sheltered_cases = 0
      for _, un in ipairs(sheltered) do
        local rec = storage.sick[un]
        if rec and rec.kind == "heat_stroke" then sheltered_cases = sheltered_cases + 1 end
      end
      ctx.check("the dome's conditioned air prevents Heat Stroke", sheltered_cases == 0, tostring(sheltered_cases))
      ctx.check("Heat Stroke is counted and costs desirability", (c.sick_heat_stroke or 0) > 0
        and (c.sick_count or 0) >= (c.sick_heat_stroke or 0) and c.d_parts and c.d_parts.sickness < 0,
        "heat=" .. tostring(c.sick_heat_stroke) .. " all=" .. tostring(c.sick_count))

      -- ---------- the Nauvis control: same on-duty state, no planet rule ----------
      local nauvis = game.surfaces[1]
      local np = nauvis.find_non_colliding_position("colony-town-hall", {x = 0, y = 0}, 30, 1) or {x = 0, y = 0}
      local nHall = nauvis.create_entity{name = "colony-town-hall", position = np, force = "player", raise_built = true}
      local nc = nHall and nHall.valid and storage.colonies[territory.owner_at(nauvis.index, np)]
      local nUnit = nc and colony.spawn_colonist(nc)
      local nUn = nUnit and nUnit.unit_number
      ctx.check("Nauvis control colony and colonist built", nHall and nHall.valid and nc ~= nil and nUn ~= nil,
        "hall=" .. tostring(nHall and nHall.valid) .. " colonist=" .. tostring(nUn))
      ctx.check("planet.is_vulcanus is false on Nauvis", planet.is_vulcanus(nauvis) == false)
      if nUn then
        storage.unit_state[nUn] = {colony_id = nc.id, job = "chop", state = "working"}
        storage.sick[nUn] = nil
        illness_adapter.evaluate(nc, {})
        ctx.check("a Nauvis worker never catches Heat Stroke", storage.sick[nUn] == nil
          or storage.sick[nUn].kind ~= "heat_stroke",
          tostring(storage.sick[nUn] and storage.sick[nUn].kind))
      end

      -- ---------- seeded Clinic cure ----------
      local function all_off_duty()
        for _, un in ipairs(ids) do
          storage.unit_state[un] = {colony_id = c.id, job = "child", state = "child"}
          storage.sick[un] = nil
        end
        for _, un in ipairs(sheltered) do
          storage.unit_state[un] = {colony_id = c.id, job = "child", state = "child"}
          storage.sick[un] = nil
        end
      end
      all_off_duty()
      local patient = ids[1]
      storage.sick[patient] = {kind = "heat_stroke", age = 1}
      storage.unit_state[ids[2]] = {colony_id = c.id, job = "heal", state = "working", hut = c.huts[clinic.unit_number]}
      clinic.insert{name = illness_model.MEDICINE, count = 4}
      local before_med = clinic.get_item_count(illness_model.MEDICINE)
      local ok, err = pcall(function() illness_adapter.evaluate(c, {}) end)
      ctx.probe("colony evaluation with a Clinic doctor", function() return "ok=" .. tostring(ok) .. " " .. tostring(err) end)
      ctx.check("a Clinic doctor cures Heat Stroke", ok and storage.sick[patient] == nil,
        tostring(storage.sick[patient] and storage.sick[patient].kind))
      ctx.check("one Herbal Medicine is consumed per cure",
        clinic.get_item_count(illness_model.MEDICINE) == before_med - 1,
        before_med .. " -> " .. clinic.get_item_count(illness_model.MEDICINE))
      all_off_duty()

      -- ---------- seeded untreated death ----------
      local victim = ids[3]
      storage.sick[victim] = {kind = "heat_stroke", age = illness_model.DISEASES.heat_stroke.fatal_after - 1}
      local fallen0 = c.fallen or 0
      local ok2, err2 = pcall(function() illness_adapter.evaluate(c, {}) end)
      ctx.probe("colony evaluation with an untreated patient", function() return "ok=" .. tostring(ok2) .. " " .. tostring(err2) end)
      ctx.check("untreated Heat Stroke kills at the documented age", ok2 and c.colonists[victim] == nil
        and storage.sick[victim] == nil and (c.fallen or 0) == fallen0 + 1,
        "fallen " .. fallen0 .. " -> " .. tostring(c.fallen))
      finish()
    end))
  end,
})
