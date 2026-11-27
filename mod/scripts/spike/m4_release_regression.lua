-- M4 release regression (#71): one headless run that re-checks the four features merged for M4.
-- Run: TICKS=3600 scripts/headless-spike.sh m4_release_regression
--
-- The dedicated feature spikes (m4_swamp_fever, m4_vulcanus_heat, m3_waystation, s18_command) pin each
-- feature's full story. This one is the release gate: a single map drives every feature through its REAL
-- adapter path, so a later refactor that breaks any one of them turns this spike red instead of shipping.
--
--   * Swamp Fever (#70, Gleba): pure spore/fever rules, natural catch on an associated Gleba surface,
--     counters/desirability, Clinic cure and untreated death.
--   * Heat Stroke + Habitat Dome (#70, Vulcanus): a dome founds the colony (a hall is refused), open-air
--     catch vs the dome's safe ring, a Nauvis control, Clinic cure and untreated death.
--   * Waystations (#56): pure gap rule, real far-refused / adjacent-accepted build, territory growth and
--     ring release on destruction.
--   * Command Whistle death cleanup (#101): pure forget_unit and the real on_entity_died path pruning a
--     dead colonist from every player's selection and its lease.
--
-- [PASS]/[FAIL] are assertions carrying a detail that names what regressed; [OK ]/[ERR] are engine probes.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local planet = require("scripts.planet")
local illness_model = require("scripts.model.illness")
local illness_adapter = require("scripts.illness")
local gleba = require("scripts.model.gleba")
local vulcanus = require("scripts.model.vulcanus")
local waystation_model = require("scripts.model.waystation")
local command_model = require("scripts.model.command")

core.register("m4_release_regression", {
  issue = 71, auto = true,
  desc = "M4 release regression: Swamp Fever, Heat Stroke/Habitat Dome, Waystations, whistle death cleanup",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish() if not finished then finished = true; ctx.finish() end end
    local function phase(fn)
      return function()
        local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback(e, 2) end)
        if not ok then ctx.log("[ERR] deferred phase crashed: " .. tostring(err)); finish() end
      end
    end
    local function build(s, name, pos)
      local ok, e = pcall(function()
        return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
      end)
      if not ok then ctx.log("[ERR] create_entity " .. name .. ": " .. tostring(e)); return nil end
      return e
    end

    storage.interval_override = 150   -- six colony evaluations in 900 ticks
    storage.sick = {}

    -- ============ SECTION 1: pure/prototype rules (no engine state needed) ============
    ctx.check("[fever] spore rules: 15 spores, scale 300, 0.5 clean-air baseline",
      gleba.SPORE_PER_HARVEST == 15 and gleba.SPORE_SCALE == 300 and gleba.exposure(0) == 0.5
      and gleba.exposure(600) == 1 and gleba.emits_spores("chop") and not gleba.emits_spores("mine")
      and gleba.is_raw("yumako") and not gleba.is_raw("colony-gleba-jam"),
      "spores=" .. tostring(gleba.SPORE_PER_HARVEST) .. " baseline=" .. tostring(gleba.exposure(0)))
    ctx.check("[fever] Swamp Fever is fatal untreated and uses its own catch rate",
      illness_model.DISEASES.swamp_fever.fatal_after == 24 and illness_model.SWAMP_RATE == 0.04
      and illness_model.catches("swamp_fever", 1, 0.039) and not illness_model.catches("swamp_fever", 1, 0.041),
      "fatal_after=" .. tostring(illness_model.DISEASES.swamp_fever.fatal_after))
    ctx.check("[heat] dome safe ring and open-air exposure",
      vulcanus.DOME_SAFE == 6 and vulcanus.exposure(0) == 0 and vulcanus.exposure(6) == 0
      and vulcanus.exposure(nil) == 1 and illness_model.HEAT_RATE == vulcanus.HEAT_RATE
      and illness_model.DISEASES.heat_stroke.fatal_after == 20,
      "safe=" .. tostring(vulcanus.DOME_SAFE) .. " rate=" .. tostring(vulcanus.HEAT_RATE))
    ctx.check("[waystation] 96-tile radius, 16-tile adjacency, signed gap",
      waystation_model.RADIUS == 96 and waystation_model.ADJACENT == 16
      and waystation_model.can_place({x = 79, y = 0}, {{position = {x = 0, y = 0}, radius = 64}})
      and not waystation_model.can_place({x = 81, y = 0}, {{position = {x = 0, y = 0}, radius = 64}}),
      "radius=" .. tostring(waystation_model.RADIUS) .. " gap=" .. tostring(waystation_model.ADJACENT))
    ctx.check("[whistle] forget_unit prunes every selection and only the dead lease", (function()
      local out = command_model.forget_unit({selection = {[1] = {4, 7}, [2] = {7, 9}},
        owner = {[4] = 1, [7] = 1, [9] = 2}, leased = {[4] = true, [7] = true, [9] = true}}, 7)
      return table.concat(out.selection[1], ",") == "4" and table.concat(out.selection[2], ",") == "9"
        and table.concat(out.changed, ",") == "1,2" and out.owner[7] == nil and out.leased[7] == nil
        and out.owner[9] == 2 and out.leased[9] == true
    end)())
    ctx.check("[proto] waystation / dome / clinic / whistle prototypes are registered",
      prototypes.entity["colony-waystation"] ~= nil and prototypes.entity["colony-habitat-dome"] ~= nil
      and prototypes.entity["colony-clinic"] ~= nil and prototypes.item["colony-command-whistle"] ~= nil)

    -- ============ SECTION 2: Swamp Fever on a real associated Gleba surface ============
    local g = game.planets["gleba"]
    local gs
    ctx.probe("[fever] game.planets.gleba -> surface", function()
      if not g then return "NO PLANET" end
      if g.surface then gs = g.surface; return "existing " .. gs.name end
      local ok, s = pcall(function() return g.create_surface() end)
      if not ok then return "create_surface ERROR: " .. tostring(s) end
      gs = s; return "created " .. tostring(s and s.name)
    end)
    if not gs then ctx.check("[fever] Gleba surface exists", false, "no planet/surface"); return finish() end
    ctx.surface, ctx.position = gs, {x = 0, y = 0}
    local gp = ctx.position
    ctx.flat_area(60, "grass-1")
    gs.always_day, gs.freeze_daytime, gs.daytime = true, true, 0
    ctx.check("[fever] planet.is_gleba / is_spore true, Nauvis is not a spore world",
      planet.is_gleba(gs) and planet.is_spore(gs) and not planet.is_spore(game.surfaces[1]))
    local gHall = build(gs, "colony-town-hall", gp)
    local gid = gHall and gHall.valid and territory.owner_at(gs.index, gp)
    local gc = gid and storage.colonies[gid]
    ctx.check("[fever] a colony registered on the Gleba surface", gc ~= nil and gHall and gHall.valid
      and gc.surface_index == gs.index, "id=" .. tostring(gid))
    if not (gc and gHall and gHall.valid) then return finish() end
    gc.accept_migrants = false
    gHall.insert{name = "raw-fish", count = 5000}
    local clinic = build(gs, "colony-clinic", {gp.x + 9, gp.y + 9})
    ctx.check("[fever] Clinic registered as a labour hut (job heal)",
      clinic and clinic.valid and gc.huts[clinic.unit_number] and gc.huts[clinic.unit_number].job == "heal")
    if not (clinic and clinic.valid) then return finish() end
    local gids = {}
    for i = 1, 16 do
      local u = colony.spawn_colonist(gc, {gp.x - 10 + (i % 8) * 2, gp.y - 6 + math.floor((i - 1) / 8) * 2})
      if u then gids[#gids + 1] = u.unit_number end
    end
    ctx.check("[fever] 16 colonists spawned on Gleba", #gids == 16, "ids=" .. tostring(#gids))
    if #gids < 3 then return finish() end   -- cure/death phases need three live colonists
    gs.set_pollution(gp, 600)   -- full spore exposure, exactly as m4_swamp_fever pins
    for _, un in ipairs(gids) do
      storage.unit_state[un] = {colony_id = gc.id, job = "chop", state = "working"}
      storage.age[un] = {stage = "adult", born = game.tick}
      storage.sick[un] = nil
    end

    -- ============ SECTION 3: Heat Stroke + Habitat Dome on Vulcanus ============
    local vp = game.planets["vulcanus"]
    local vs
    ctx.probe("[heat] game.planets.vulcanus -> surface", function()
      if not vp then return "NO PLANET" end
      if vp.surface then vs = vp.surface; return "existing " .. vs.name end
      local ok, s = pcall(function() return vp.create_surface() end)
      if not ok then return "create_surface ERROR: " .. tostring(s) end
      vs = s; return "created " .. tostring(s and s.name)
    end)
    if not vs then ctx.check("[heat] Vulcanus surface exists", false, "no planet/surface"); return finish() end
    ctx.surface, ctx.position = vs, {x = 0, y = 0}
    local vp0 = ctx.position
    ctx.flat_area(60, "refined-concrete")
    vs.always_day, vs.freeze_daytime, vs.daytime = true, true, 0
    ctx.check("[heat] planet.is_vulcanus, hall refused and Habitat Dome allowed",
      planet.is_vulcanus(vs) and planet.may_found(vs, "colony-town-hall") == false
      and planet.may_found(vs, "colony-habitat-dome") == true)
    local dome = build(vs, "colony-habitat-dome", vp0)
    local vid = dome and dome.valid and territory.owner_at(vs.index, vp0)
    local vc = vid and storage.colonies[vid]
    ctx.check("[heat] a Habitat Dome founded the Vulcanus colony", vc ~= nil and dome and dome.valid
      and vc.hall.name == "colony-habitat-dome" and vc.surface_index == vs.index, "id=" .. tostring(vid))
    if not (vc and dome and dome.valid) then return finish() end
    vc.accept_migrants = false
    ctx.power_at(vp0)
    dome.insert{name = "raw-fish", count = 5000}
    dome.insert{name = "colony-water", count = 5000}
    local vClinic = build(vs, "colony-clinic", {vp0.x + 10, vp0.y + 10})
    ctx.check("[heat] Vulcanus Clinic registered as a labour hut",
      vClinic and vClinic.valid and vc.huts[vClinic.unit_number] and vc.huts[vClinic.unit_number].job == "heal")
    if not (vClinic and vClinic.valid) then return finish() end
    local vids, vsafe = {}, {}
    for i = 1, 20 do
      local u = colony.spawn_colonist(vc, {vp0.x + 14 + (i % 4) * 3, vp0.y - 12 + math.floor((i - 1) / 4) * 3})
      if u then vids[#vids + 1] = u.unit_number end
    end
    for i = 1, 2 do
      local u = colony.spawn_colonist(vc, {vp0.x + 3, vp0.y + (i - 1) * 2})
      if u then vsafe[#vsafe + 1] = u.unit_number end
    end
    ctx.check("[heat] 20 open-air and 2 dome-sheltered colonists spawned", #vids == 20 and #vsafe == 2,
      #vids .. " open, " .. #vsafe .. " sheltered")
    if #vids < 3 or #vsafe < 2 then return finish() end   -- cure/death and shelter phases need them
    for _, un in ipairs(vids) do
      storage.unit_state[un] = {colony_id = vc.id, job = "chop", state = "working"}
      storage.age[un] = {stage = "adult", born = game.tick}
      storage.sick[un] = nil
    end
    for _, un in ipairs(vsafe) do
      storage.unit_state[un] = {colony_id = vc.id, job = "chop", state = "working"}
      storage.age[un] = {stage = "adult", born = game.tick}
      storage.sick[un] = nil
    end
    local okv, verr = pcall(function() colony.evaluate({colony_id = vc.id}) end)
    ctx.check("[heat] real colony.evaluate reads off-world pollution as clean", okv and (vc.pollution or 0) == 0,
      tostring(verr) .. " pollution=" .. tostring(vc.pollution))

    -- ============ SECTION 4: Waystations + whistle death cleanup on Nauvis ============
    local ns = game.surfaces[1]
    ctx.surface, ctx.position = ns, {x = 0, y = 0}
    local np = ctx.position
    ctx.flat_area(180, "grass-1")
    ns.always_day, ns.freeze_daytime, ns.daytime = true, true, 0
    local nHall = build(ns, "colony-town-hall", np)
    local nid = nHall and nHall.valid and territory.owner_at(ns.index, np)
    local nc = nid and storage.colonies[nid]
    ctx.check("[waystation] Nauvis control colony founded", nc ~= nil and nHall and nHall.valid)
    if not (nc and nHall and nHall.valid) then return finish() end
    nc.accept_migrants = false
    local before = #territory.chunks(nc)
    local far = build(ns, "colony-waystation", {np.x + 160, np.y})
    ctx.check("[waystation] a waystation far outside territory is refused", not (far and far.valid))
    local ws = build(ns, "colony-waystation", {np.x + 72, np.y})
    ctx.check("[waystation] a waystation just outside the boundary is built and registered",
      ws and ws.valid and nc.waystations and nc.waystations[ws.unit_number] == ws)
    local isEmitter = false
    for _, e in ipairs(territory.emitters(nc)) do
      if e.entity == ws and e.radius == waystation_model.RADIUS then isEmitter = true end
    end
    ctx.check("[waystation] the live waystation is a 96-tile territory emitter", isEmitter)
    ctx.check("[waystation] territory grew past the hall and stops at the waystation edge",
      territory.owner_at(ns.index, {x = np.x + 150, y = np.y}) == nid
      and territory.owner_at(ns.index, {x = np.x + 170, y = np.y}) == nil
      and #territory.chunks(nc) > before, "chunks " .. before .. " -> " .. tostring(#territory.chunks(nc)))
    local wsUn = ws and ws.unit_number
    if ws and ws.valid then ws.destroy() end
    ctx.after(2, phase(function()
      ctx.check("[waystation] destroying the node releases its ring, not the hall's land",
        nc.waystations[wsUn] == nil and territory.owner_at(ns.index, {x = np.x + 150, y = np.y}) == nil
        and territory.owner_at(ns.index, np) == nid)
    end))

    -- mortality's real on_entity_died calls command.died before its roster check, so this covers a unit
    -- already struck off the roster too (as #101 hardened).
    local dead = colony.spawn_colonist(nc, {np.x + 4, np.y + 4})
    if dead then
      local dun = dead.unit_number
      storage.command = storage.command or {}
      -- An unresolvable sentinel unit (as in s18_command): headless has no player 2, so a colonist that
      -- actually exists here would make the adapter's draw_circle{players={2}} raise. The prune is what
      -- this checks, not marker rendering.
      local sentinel = 99999999
      storage.command.selection = {[1] = {dun}, [2] = {dun, sentinel}}
      storage.command.leased[dun], storage.command.owner[dun] = true, 1
      storage.unit_state[dun] = {colony_id = nc.id, job = "hunt", state = "commanded",
        until_tick = game.tick + 3600}
      dead.die()
      ctx.check("[whistle] a real death prunes every selection and drops the lease immediately",
        #storage.command.selection[1] == 0 and #storage.command.selection[2] == 1
        and storage.command.selection[2][1] == sentinel and storage.command.leased[dun] == nil
        and storage.command.owner[dun] == nil,
        "p1=" .. #storage.command.selection[1] .. " p2=" .. table.concat(storage.command.selection[2], ","))
    else
      ctx.check("[whistle] a colonist for the death-cleanup case spawned", false)
    end
    local control = colony.spawn_colonist(nc, {np.x - 5, np.y - 5})  -- Nauvis heat control
    local cun = control and control.unit_number
    if cun then
      storage.unit_state[cun] = {colony_id = nc.id, job = "chop", state = "working"}
      storage.sick[cun] = nil
    end

    -- ============ SECTION 5: natural catch + seeded treatment after six evaluations ============
    ctx.after(960, phase(function()
      local function kind_count(kind)
        local n = 0
        for _, rec in pairs(storage.sick or {}) do if rec.kind == kind then n = n + 1 end end
        return n
      end
      local swamp = kind_count("swamp_fever")
      ctx.check("[fever] natural exposure catches Swamp Fever with zero seeded sickness", swamp > 0,
        swamp .. " cases of " .. #gids .. " on-duty workers")
      local heat = 0
      for _, un in ipairs(vids) do
        local rec = storage.sick[un]
        if rec and rec.kind == "heat_stroke" then heat = heat + 1 end
      end
      ctx.check("[heat] open-air workers catch Heat Stroke with zero seeded sickness", heat > 0,
        heat .. " cases of " .. #vids .. " workers")
      local sheltered = 0
      for _, un in ipairs(vsafe) do
        local rec = storage.sick[un]
        if rec and rec.kind == "heat_stroke" then sheltered = sheltered + 1 end
      end
      ctx.check("[heat] the dome's safe ring prevents Heat Stroke", sheltered == 0, tostring(sheltered))
      if cun then
        local rec = storage.sick[cun]
        ctx.check("[heat] a Nauvis worker never catches Heat Stroke", not (rec and rec.kind == "heat_stroke"),
          tostring(rec and rec.kind))
      end
      ctx.check("[fever/heat] counters and desirability record the cases",
        (gc.sick_swamp_fever or 0) > 0 and (vc.sick_heat_stroke or 0) > 0
        and gc.d_parts and gc.d_parts.sickness < 0 and vc.d_parts and vc.d_parts.sickness < 0,
        "swamp=" .. tostring(gc.sick_swamp_fever) .. " heat=" .. tostring(vc.sick_heat_stroke))

      -- Seeded cure/death use the same adapter path an evaluation calls; off-duty first so no new cases.
      local function off_duty(c, ids)
        for _, un in ipairs(ids) do
          storage.unit_state[un] = {colony_id = c.id, job = "child", state = "child"}
          storage.sick[un] = nil
        end
      end
      off_duty(gc, gids); off_duty(vc, vids); off_duty(vc, vsafe)
      local function cure(col, clinicEnt, patient, doctor, kind)
        storage.sick[patient] = {kind = kind, age = 1}
        storage.unit_state[doctor] = {colony_id = col.id, job = "heal", state = "working",
          hut = col.huts[clinicEnt.unit_number]}
        clinicEnt.insert{name = illness_model.MEDICINE, count = 4}
        local med_before = clinicEnt.get_item_count(illness_model.MEDICINE)
        local ok, err = pcall(function() illness_adapter.evaluate(col, {}) end)
        ctx.check("[" .. kind .. "] a Clinic doctor cures the case and spends one medicine",
          ok and storage.sick[patient] == nil and clinicEnt.get_item_count(illness_model.MEDICINE) == med_before - 1,
          tostring(err) .. " rec=" .. tostring(storage.sick[patient] and storage.sick[patient].kind))
      end
      cure(gc, clinic, gids[1], gids[2], "swamp_fever")
      cure(vc, vClinic, vids[1], vids[2], "heat_stroke")
      off_duty(gc, gids); off_duty(vc, vids); off_duty(vc, vsafe)
      local function death(col, victim, kind)
        storage.sick[victim] = {kind = kind, age = illness_model.DISEASES[kind].fatal_after - 1}
        local fallen0 = col.fallen or 0
        local ok, err = pcall(function() illness_adapter.evaluate(col, {}) end)
        ctx.check("[" .. kind .. "] an untreated case dies at the documented age",
          ok and col.colonists[victim] == nil and storage.sick[victim] == nil
          and (col.fallen or 0) == fallen0 + 1,
          tostring(err) .. " fallen " .. tostring(fallen0) .. " -> " .. tostring(col.fallen))
      end
      death(gc, gids[3], "swamp_fever")
      death(vc, vids[3], "heat_stroke")
      finish()
    end))
  end,
})
