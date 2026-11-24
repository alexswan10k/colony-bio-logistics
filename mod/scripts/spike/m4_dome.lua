-- M4 Habitat Dome acceptance (#63): the LANDED feature driven through real colony evaluations.
-- Run: TICKS=6000 scripts/headless-spike.sh m4_dome
--
-- Nauvis phase: a Habitat Dome is the FIRST core (no Town Hall anywhere). Colonists are fed from its chest,
-- housed in it, and a second dome extends the same colony's territory. Then the founding core is destroyed
-- (the remaining dome is promoted) and finally the last dome dies (the colony goes dormant, no crash).
-- Hostile phase: on real Vulcanus (and briefly Fulgora) surfaces a Town Hall build is refused and refunded,
-- while a Habitat Dome founds a colony whose surface_index matches the hostile surface.
--
-- Every scheduled phase is pcall-wrapped; ctx.finish() is called exactly once via the `finish` guard.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local planet = require("scripts.planet")
local model_core = require("scripts.model.core")

core.register("m4_dome", {
  issue = 63, auto = true,
  desc = "Habitat Dome end-to-end: founding dome, second emitter, core migration, dormancy, hostile-world founding",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish()
      if not finished then finished = true; ctx.finish() end
    end
    local function phase(fn)
      return function()
        local ok, err = xpcall(fn, function(e) return tostring(e) .. " " .. debug.traceback(e, 2) end)
        if not ok then
          ctx.log("[ERR] deferred phase crashed: " .. tostring(err))
          finish()
        end
      end
    end

    local DOME, HALL = model_core.DOME, model_core.HALL
    local function pos_str(p) return p and (p.x .. "," .. p.y) or "NONE" end
    local function build(surface, name, pos)
      local ok, e = pcall(function()
        return surface.create_entity{name = name, position = pos, force = "player", raise_built = true}
      end)
      if not ok then ctx.log("[ERR] create_entity " .. name .. ": " .. tostring(e)); return nil end
      return e
    end
    local function find_patch(surface, cx, cy, name, radius)
      for dx = -radius, radius do
        for dy = -radius, radius do
          local pos = {x = cx + dx, y = cy + dy}
          local ok, res = pcall(function()
            return surface.can_place_entity{name = name, position = pos, force = "player"}
          end)
          if ok and res then return pos end
        end
      end
      return nil
    end
    local function scheduled_for(id)
      local found = {}
      for _tick, bucket in pairs(storage.scheduled or {}) do
        for _, job in ipairs(bucket) do
          if job.data and job.data.colony_id == id then
            found[job.handler] = (found[job.handler] or 0) + 1
          end
        end
      end
      local parts = {}
      for n, c in pairs(found) do parts[#parts + 1] = n .. "x" .. c end
      table.sort(parts)
      return found, table.concat(parts, ", ")
    end
    local hostile_phases   -- forward declaration: the Nauvis phases call it from a deferred callback

    -- ============================================================ Nauvis: FOUNDING DOME (no hall)
    local s = game.surfaces.nauvis
    ctx.surface, ctx.position = s, {x = 0, y = 0}
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    ctx.flat_area(64, "refined-concrete")
    storage.interval_override = 150      -- before the first core is built

    local p1 = find_patch(s, 0, 0, DOME, 8)
    ctx.check("Nauvis: found a clear 4x4 patch for the founding dome", p1 ~= nil, pos_str(p1))
    if not p1 then finish() return end
    local id_before = storage.next_colony_id
    local dome1 = build(s, DOME, p1)
    ctx.check("founding dome created with raise_built=true", dome1 and dome1.valid)
    if not (dome1 and dome1.valid) then finish() return end
    ctx.power_at(p1)
    -- A 4x4 dome's hidden power sink sits at its centre; one more pole at 3 tiles guarantees it is fed.
    s.create_entity{name = "medium-electric-pole", position = {x = p1.x + 3, y = p1.y}, force = "player"}

    local cid = territory.owner_at(s.index, dome1.position)
    local c = cid and storage.colonies[cid]
    ctx.check("a dome-only colony was founded (no Town Hall)",
      c ~= nil and c.hall and c.hall.valid and c.hall.name == DOME
      and c.hall.unit_number == dome1.unit_number and storage.next_colony_id == id_before + 1,
      "hall=" .. tostring(c and c.hall and c.hall.name) .. " next=" .. tostring(storage.next_colony_id))
    if not (c and c.hall and c.hall.valid) then finish() return end
    local first_un = dome1.unit_number   -- captured while the entity is alive
    ctx.check("domes registry + house registry hold the founding core",
      c.domes and c.domes[first_un] ~= nil and c.houses[first_un]
      and c.houses[first_un].kind == "dome" and #colony.dome_list(c) == 1)
    ctx.check("housing.TIERS.dome capacity is 32 and the colony reports it",
      colony.capacity(c) == 32, tostring(colony.capacity(c)))

    -- Hall-equivalent stock lives in the dome chest; it is both the core stock room and a house shelf.
    dome1.insert{name = "raw-fish", count = 2000}
    dome1.insert{name = "colony-water", count = 2000}
    local fish0 = dome1.get_item_count("raw-fish")
    local initial_pop = 0
    for i = 1, 6 do
      local unit = colony.spawn_colonist(c,
        {x = p1.x - 6 + (i % 3) * 5, y = p1.y - 6 + math.floor((i - 1) / 3) * 5})
      if unit then initial_pop = initial_pop + 1 end
    end
    ctx.check("six colonists spawned at the dome", initial_pop == 6, tostring(initial_pop))
    ctx.probe("handlers right after founding", function()
      local _h, summary = scheduled_for(c.id); return summary
    end)

    -- A second dome INSIDE the founding territory: new emitter, new beds, no new colony.
    local p2 = find_patch(s, p1.x + 56, p1.y, DOME, 6)
    ctx.check("found a clear patch for a second dome inside the 64-tile ring", p2 ~= nil, pos_str(p2))
    if not p2 then finish() return end
    ctx.check("second dome position is owned by the founding colony",
      territory.owner_at(s.index, p2) == c.id, tostring(territory.owner_at(s.index, p2)))
    local chunks_before = #territory.chunks(c)
    local next_before = storage.next_colony_id
    local dome2 = build(s, DOME, p2)
    ctx.check("second dome created", dome2 and dome2.valid)
    if not (dome2 and dome2.valid) then finish() return end
    ctx.power_at(p2)
    s.create_entity{name = "medium-electric-pole", position = {x = p2.x + 3, y = p2.y}, force = "player"}
    dome2.insert{name = "raw-fish", count = 2000}
    dome2.insert{name = "colony-water", count = 2000}
    local chunks_after = #territory.chunks(c)
    ctx.check("the second dome did NOT found a new colony", storage.next_colony_id == next_before,
      next_before .. " -> " .. tostring(storage.next_colony_id))
    ctx.check("dome_list now has two domes", #colony.dome_list(c) == 2,
      tostring(#colony.dome_list(c)))
    ctx.check("both domes are houses; capacity is 64", colony.capacity(c) == 64
      and c.houses[dome1.unit_number] and c.houses[dome2.unit_number],
      tostring(colony.capacity(c)))
    ctx.check("territory.chunks grew when the second emitter was added",
      chunks_after > chunks_before, chunks_before .. " -> " .. chunks_after)
    local only_second = {x = p2.x + 45, y = p2.y}
    ctx.check("a point only the second dome covers belongs to the same colony",
      territory.owner_at(s.index, only_second) == c.id,
      tostring(territory.owner_at(s.index, only_second)))
    ctx.check("a far-away Nauvis point is unowned",
      territory.owner_at(s.index, {x = p1.x + 200, y = p1.y}) == nil)

    -- #63 review: territory ownership alone is not enough to join the registry - a dome of another force
    -- must be refused (and refunded), or one colony could quietly absorb another force's buildings.
    local enemy = game.forces["enemy"] or game.create_force("enemy")
    local pf = find_patch(s, p1.x + 40, p1.y, DOME, 4)
    ctx.check("found a clear patch for a foreign-force dome", pf ~= nil, pos_str(pf))
    if pf then
      local foreign = s.create_entity{name = DOME, position = pf, force = enemy, raise_built = true}
      ctx.check("a foreign-force dome is refused inside our territory",
        not foreign or not foreign.valid, tostring(foreign and foreign.valid))
      ctx.check("the refused dome did not join the registry or found a colony",
        #colony.dome_list(c) == 2 and storage.next_colony_id == next_before,
        "domes=" .. #colony.dome_list(c) .. " next=" .. tostring(storage.next_colony_id))
    end

    -- ============================================================ evaluation evidence
    ctx.after(600, phase(function()
      local handlers, summary = scheduled_for(c.id)
      ctx.probe("scheduler chains for the dome colony", function() return summary end)
      ctx.check("evaluate / construct.scan / machine_sweep chains all run for a dome-founded colony",
        handlers["colony.evaluate"] ~= nil and handlers["construct.scan"] ~= nil
        and handlers["work.machine_sweep"] ~= nil, summary)
      local pop = colony.live_colonists(c)
      ctx.check("the colony grew through real evaluations", pop > initial_pop,
        initial_pop .. " -> " .. tostring(pop))
      local fish1 = dome1.get_item_count("raw-fish")
      ctx.check("colonists ate from the founding dome's chest", fish1 < fish0,
        fish0 .. " -> " .. fish1)
      ctx.check("the founding dome has real occupants",
        (c.houses[first_un] and c.houses[first_un].occupants or 0) > 0,
        tostring(c.houses[first_un] and c.houses[first_un].occupants))
      ctx.check("the founding dome's Tier-5 electricity need is met (powered sink)",
        colony.is_powered(c.houses[first_un]) == true,
        tostring(c.houses[first_un] and c.houses[first_un].sink
          and c.houses[first_un].sink.valid and c.houses[first_un].sink.energy))
      ctx.check("desirability was computed", type(c.d) == "number", tostring(c.d))
      ctx.probe("founding dome custom_status after feedback tick", function()
        local st = dome1.custom_status
        return type(st) == "table" and ("diode=" .. tostring(st.diode)) or tostring(st)
      end)

      -- ---------------------------------------------------------- founding core dies -> promote
      local second_un = dome2.unit_number
      local fish2 = dome2.get_item_count("raw-fish")
      dome1.destroy()
      ctx.after(60, phase(function()
        ctx.check("the surviving dome was promoted to colony.hall",
          c.hall and c.hall.valid and c.hall.unit_number == second_un and c.hall.name == DOME,
          tostring(c and c.hall and c.hall.name))
        ctx.check("the dead founding dome left the registries",
          c.domes[first_un] == nil and c.houses[first_un] == nil
          and #colony.dome_list(c) == 1)
        ctx.after(300, phase(function()
          local fish3 = dome2.valid and dome2.get_item_count("raw-fish") or -1
          ctx.check("evaluation continues from the promoted dome (food consumed)", fish3 < fish2,
            fish2 .. " -> " .. fish3)
          ctx.check("the colony is still alive after losing its founding core",
            c.hall and c.hall.valid and colony.live_colonists(c) > 0)

          -- ------------------------------------------------------ last dome dies -> dormancy
          dome2.destroy()
          ctx.after(60, phase(function()
            ctx.check("with no dome left the colony is dormant (invalid hall)",
              c.hall ~= nil and not c.hall.valid, tostring(c.hall and c.hall.valid))
            local d_before = c.d
            ctx.after(300, phase(function()
              ctx.check("a dormant dome colony does not evaluate and does not crash",
                c.d == d_before and storage.colonies[c.id] == c,
                "d " .. tostring(d_before) .. " -> " .. tostring(c.d))
              hostile_phases()
            end))
          end))
        end))
      end))
    end))

    -- ============================================================ hostile worlds
    hostile_phases = function()
      local keys = {"vulcanus", "fulgora"}
      local function one(idx)
        if idx > #keys then finish() return end
        local key = keys[idx]
        local p = game.planets[key]
        ctx.check("game.planets['" .. key .. "'] exists", p ~= nil)
        if not p then one(idx + 1) return end
        local hs
        ctx.probe(key .. ": planet.surface or create_surface()", function()
          if p.surface then hs = p.surface; return "existing " .. hs.name end
          local ok, surf = pcall(function() return p.create_surface() end)
          if not ok then return "ERROR: " .. tostring(surf) end
          hs = surf
          return "created " .. tostring(hs and hs.name)
        end)
        if not hs then one(idx + 1) return end
        ctx.check(key .. ": planet.is_hostile / is_exotic true", planet.is_hostile(hs) == true
          and planet.is_exotic(hs) == true and planet.is_platform(hs) == false)
        ctx.check(key .. ": may_found(DOME) true, may_found(HALL) false, may_build_hall false",
          planet.may_found(hs, DOME) == true and planet.may_found(hs, HALL) == false
          and planet.may_build_hall(hs) == false)

        -- Generate + flatten a patch so the test is about the game gate, not terrain/collision.
        ctx.probe(key .. ": generate chunks + lay a flat buildable pad", function()
          hs.request_to_generate_chunks({0, 0}, 3)
          hs.force_generate_chunk_requests()
          local base = hs.get_tile({x = 0, y = 0})
          local name = base and base.name or "stone-path"
          if base and base.collides_with("water_tile") then name = "stone-path" end
          local tiles = {}
          for x = -24, 24 do
            for y = -24, 24 do
              tiles[#tiles + 1] = {name = name, position = {x = x, y = y}}
            end
          end
          hs.set_tiles(tiles)
          for _, e in pairs(hs.find_entities_filtered{area = {{-26, -26}, {26, 26}}}) do
            if e.valid and e.type ~= "character" then e.destroy() end
          end
          return "tile=" .. name
        end)
        local hp = find_patch(hs, 0, 0, DOME, 10)
        ctx.check(key .. ": a clear 4x4 dome patch exists", hp ~= nil, pos_str(hp))
        if not hp then one(idx + 1) return end
        ctx.probe(key .. ": can_place_entity Town Hall on the same pad", function()
          return tostring(hs.can_place_entity{name = HALL, position = hp, force = "player"})
        end)

        local before = storage.next_colony_id
        local hall_e = build(hs, HALL, hp)
        ctx.check(key .. ": the Town Hall build is refused + refunded, no colony founded",
          (not hall_e or not hall_e.valid) and storage.next_colony_id == before,
          "next " .. before .. " -> " .. tostring(storage.next_colony_id)
          .. " hall=" .. tostring(hall_e and hall_e.valid))

        local dome = build(hs, DOME, hp)
        ctx.check(key .. ": the Habitat Dome founds a colony there",
          dome and dome.valid and storage.next_colony_id == before + 1
          and territory.owner_at(hs.index, dome.position) ~= nil,
          "next=" .. tostring(storage.next_colony_id))
        if dome and dome.valid then
          local hc = storage.colonies[territory.owner_at(hs.index, dome.position)]
          ctx.check(key .. ": the new colony's surface_index matches the hostile surface",
            hc ~= nil and hc.surface_index == hs.index and hc.hall and hc.hall.unit_number == dome.unit_number,
            tostring(hc and hc.surface_index) .. " vs " .. tostring(hs.index))
          ctx.check(key .. ": the hostile dome is a 32-bed house and core",
            hc and hc.domes and hc.domes[dome.unit_number] ~= nil
            and hc.houses[dome.unit_number] and hc.houses[dome.unit_number].kind == "dome"
            and colony.capacity(hc) == 32)

          -- #63 review: the REAL player path is a ghost the colony's builder revives, not a direct build.
          -- Place the ghost inside the founding dome's ring, then drive the same revive call construct.finish
          -- uses (m1_blueprint pattern) and prove the revived dome joins THIS colony, not a new one.
          local gy = (hp.y > 4) and (hp.y - 10) or (hp.y + 10)
          local gp = find_patch(hs, hp.x, gy, DOME, 2)
          ctx.check(key .. ": a clear patch in the ring for a dome ghost", gp ~= nil, pos_str(gp))
          if gp then
            local ok_g, ghost = ctx.probe(key .. ": place a colony dome ghost (player path)", function()
              return hs.create_entity{name = "entity-ghost", inner_name = DOME, position = gp,
                force = "player", raise_built = true}
            end)
            local gkey = hs.index .. ":" .. gp.x .. "," .. gp.y
            ctx.probe(key .. ": dome ghost build cost", function()
              local items = (ghost and ghost.valid and ghost.ghost_prototype
                and ghost.ghost_prototype.items_to_place_this) or {}
              local parts = {}
              for _, it in ipairs(items) do parts[#parts + 1] = tostring(it.name) .. "x" .. tostring(it.count or it.amount) end
              return table.concat(parts, ",")
            end)
            ctx.check(key .. ": the ghost was queued in the colony's registry", ok_g and ghost and ghost.valid
              and hc.ghosts[gkey] ~= nil, "gkey=" .. gkey)
            if ghost and ghost.valid then
              local ok_r, revived = ctx.probe(key .. ": revive the ghost like the colony builder does", function()
                return select(2, ghost.revive{raise_revive = true})
              end)
              ctx.check(key .. ": the ghost revived into a live dome", ok_r and revived and revived.valid
                and revived.name == DOME, tostring(revived and revived.name))
              if revived and revived.valid then
                ctx.check(key .. ": the revived dome joined this colony, not a new one",
                  hc.domes[revived.unit_number] ~= nil and hc.houses[revived.unit_number]
                    and hc.houses[revived.unit_number].kind == "dome" and #colony.dome_list(hc) == 2
                    and storage.next_colony_id == before + 1,
                  "domes=" .. #colony.dome_list(hc) .. " next=" .. tostring(storage.next_colony_id))
              end
            end
          end
        end
        ctx.after(180, phase(function()
          one(idx + 1)
        end))
      end
      one(1)
    end
  end,
})
