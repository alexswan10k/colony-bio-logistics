-- SPIKE #63 (acceptance): the LANDED Habitat Dome actually founds and runs a colony on a space platform.
-- Run: TICKS=1800 scripts/headless-spike.sh s24_dome_platform
--
-- s22_dome pinned the engine facts (housing clones inherit gravity >= 0.1; platforms have gravity 0) and
-- s23_dome_build proved that CLEARING surface_conditions is enough to build a 4x4 candidate on platform
-- foundation. This spike proves the game code that ships with #63, end to end:
--   * create a real platform, grow its deck, build the real colony-habitat-dome with raise_built=true;
--   * the same spot still refuses a Town Hall (hall-on-platform gate) and a townhouse (gravity control);
--   * one evaluation later `colony.hall` IS the dome, the scheduler chains run, territory owns the ring,
--     the dome is a 32-bed house, and seed_forage is a no-op on a tile-less platform;
--   * on_space_platform_built_entity is observed for a scripted create_entity (s23 says it does not fire).
--
-- Every engine call that can disagree with the docs goes through ctx.probe (pcall). ctx.finish() is called
-- exactly once on every path via the `finish` guard.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local planet = require("scripts.planet")
local model_core = require("scripts.model.core")

core.register("s24_dome_platform", {
  issue = 63, auto = true,
  desc = "Habitat Dome acceptance on a space platform: build, core alias, house, territory, scheduler, built event",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish()
      if not finished then finished = true; ctx.finish() end
    end

    local DOME, HALL, HOUSE = model_core.DOME, model_core.HALL, "colony-housing-townhouse"
    local function pos_str(p) return p and (p.x .. "," .. p.y) or "NONE" end

    -- First tile-centre position in a square scan where `name` can be placed (pcall-protected).
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

    -- Snapshot the scheduler jobs belonging to one colony (handlers are names, data.colony_id is plain).
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

    -- ============================================================ pure identity / gate facts
    ctx.check("core.HALL / core.DOME literals are the landed prototypes",
      HALL == "colony-town-hall" and DOME == "colony-habitat-dome", HALL .. " / " .. DOME)
    ctx.check("core.is_core / core.is_dome", model_core.is_core(HALL) and model_core.is_core(DOME)
      and model_core.is_dome(DOME) and not model_core.is_dome(HALL))
    ctx.check("DOME_RADIUS is 64 tiles", territory.DOME_RADIUS == 64
      and territory.core_radius(DOME) == 64 and territory.core_radius(HALL) == 64,
      tostring(territory.DOME_RADIUS))

    -- ============================================================ built-event observer
    local script_built_fired, script_built_report = 0, "none"
    if defines.events.script_raised_built then
      -- MUST use the multiplexer: script.on_event would REPLACE colony.on_built for this event.
      events.on(defines.events.script_raised_built, function(ev)
        script_built_fired = script_built_fired + 1
        local e = ev.entity
        -- The game gate destroys a refused hall INSIDE this event: only .valid is readable afterwards.
        script_built_report = "entity=" .. tostring(e and (e.valid and e.name or "destroyed-in-handler") or "nil") ..
          " surface=" .. tostring(e and e.valid and e.surface and e.surface.name)
      end)
    end
    local built_fired, built_report = 0, "none"
    if defines.events.on_space_platform_built_entity then
      events.on(defines.events.on_space_platform_built_entity, function(ev)
        built_fired = built_fired + 1
        local keys = {}
        for k in pairs(ev) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local okp, plat = pcall(function()
          return ev.platform and (ev.platform.name or ev.platform.object_name) or "nil"
        end)
        local oke, ent = pcall(function()
          if not ev.entity then return "nil" end
          if not ev.entity.valid then return "destroyed-in-handler" end
          return ev.entity.name .. "@" .. ev.entity.position.x .. "," .. ev.entity.position.y
        end)
        local oks, stk = pcall(function() return ev.stack and ev.stack.name or "nil" end)
        built_report = "keys=[" .. table.concat(keys, ",") .. "]" ..
          " platform=" .. (okp and tostring(plat) or "ERR") ..
          " entity=" .. (oke and tostring(ent) or "ERR") ..
          " stack=" .. (oks and tostring(stk) or "ERR")
      end)
    end
    ctx.check("defines.events.on_space_platform_built_entity exists",
      defines.events.on_space_platform_built_entity ~= nil)

    -- ============================================================ platform + grown foundation
    storage.interval_override = 150   -- one colony evaluation every 150 ticks
    local okp, platform = ctx.probe("force.create_space_platform (s23 style)", function()
      return game.forces.player.create_space_platform{
        name = "s24-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (okp and platform) then
      ctx.log("*** platform could not be created - cannot prove the platform path")
      finish()
      return
    end
    ctx.probe("platform.apply_starter_pack", function() return platform.apply_starter_pack() ~= nil end)

    ctx.after(90, function()
      local ok, err = pcall(function()
        local surface = platform.surface
        ctx.check("platform surface valid", surface ~= nil and surface.valid)
        if not (surface and surface.valid) then finish() return end
        ctx.check("planet.is_platform(platform.surface)", planet.is_platform(surface) == true)
        ctx.check("planet.may_found(platform, DOME) true / may_build_hall(platform) false",
          planet.may_found(surface, DOME) == true and planet.may_build_hall(surface) == false
          and planet.may_found(surface, HALL) == false)
        ctx.probe("platform gravity", function() return surface.get_property("gravity") end)

        local hub = platform.hub
        local origin = hub and hub.position or {x = 0, y = 0}
        ctx.probe("platform.hub position", function() return origin.x .. "," .. origin.y end)

        -- The starter 10x10 foundation is too small around the hub for a 4x4; grow it with set_tiles
        -- exactly as s23_dome_build did, then scan for a clear patch.
        local lo, hi, cx, cy = 8, 24, origin.x + 16, origin.y + 16
        ctx.probe("request/force chunks + grow the deck with set_tiles", function()
          surface.request_to_generate_chunks({x = cx, y = cy}, 4)
          surface.force_generate_chunk_requests()
          local tiles = {}
          for x = origin.x + lo, origin.x + hi do
            for y = origin.y + lo, origin.y + hi do
              tiles[#tiles + 1] = {name = "space-platform-foundation", position = {x = x, y = y}}
            end
          end
          surface.set_tiles(tiles)
          return #tiles .. " tiles; centre=" .. tostring(surface.get_tile({x = cx, y = cy}).name)
        end)

        local pos = find_patch(surface, cx, cy, DOME, 8)
        if not pos then
          ctx.probe("fallback: grow the opposite corner and rescan", function()
            local tiles = {}
            for x = origin.x - 24, origin.x - 8 do
              for y = origin.y - 24, origin.y - 8 do
                tiles[#tiles + 1] = {name = "space-platform-foundation", position = {x = x, y = y}}
              end
            end
            surface.set_tiles(tiles)
            pos = find_patch(surface, origin.x - 16, origin.y - 16, DOME, 8)
            return "patch=" .. pos_str(pos)
          end)
        end
        ctx.check("platform: can_place_entity colony-habitat-dome (4x4) on grown foundation",
          pos ~= nil, pos_str(pos))
        if not pos then finish() return end

        -- Controls at the SAME untouched position: both inherit gravity >= 0.1 and must be refused.
        local okHallPlace, hallPlace = pcall(function()
          return surface.can_place_entity{name = HALL, position = pos, force = "player"}
        end)
        local okHousePlace, housePlace = pcall(function()
          return surface.can_place_entity{name = HOUSE, position = pos, force = "player"}
        end)
        ctx.check("platform: SAME position refuses a Town Hall (hall-on-platform gate)",
          okHallPlace and hallPlace == false, tostring(hallPlace))
        ctx.check("platform: SAME position refuses a townhouse (gravity >= 0.1 control)",
          okHousePlace and housePlace == false, tostring(housePlace))

        -- Founding gate through the REAL build path: a Town Hall create_entity must be refused/destroyed
        -- and must NOT found a colony. (The engine's own gravity gate also applies to halls on platforms;
        -- planet.may_build_hall(platform) == false above pins the game-side gate independently.)
        local before = storage.next_colony_id
        local refused
        ctx.probe("create_entity colony-town-hall on platform, raise_built=true", function()
          local ok, e = pcall(function()
            return surface.create_entity{name = HALL, position = pos, force = "player", raise_built = true}
          end)
          if not ok then return "ERROR: " .. tostring(e) end
          refused = e
          return e and (e.valid and "UNEXPECTEDLY VALID" or "destroyed by game gate") or "nil (engine refused)"
        end)
        ctx.check("a Town Hall build on the platform founds no colony",
          (not refused or not refused.valid) and storage.next_colony_id == before,
          "next_colony_id " .. before .. " -> " .. tostring(storage.next_colony_id))

        local built
        ctx.probe("create_entity colony-habitat-dome on platform, raise_built=true", function()
          local ok, e = pcall(function()
            return surface.create_entity{name = DOME, position = pos, force = "player", raise_built = true}
          end)
          if not ok then return "ERROR: " .. tostring(e) end
          built = e
          return e and (e.valid and (e.name .. "@" .. pos_str(e.position)) or "INVALID") or "nil"
        end)
        ctx.check("platform: create_entity colony-habitat-dome returned a valid entity",
          built ~= nil and built.valid, built and built.name or "nil")
        if not (built and built.valid) then finish() return end

        local cid = territory.owner_at(surface.index, built.position)
        local c = cid and storage.colonies[cid]
        ctx.check("the dome founded exactly one colony on the platform",
          c ~= nil and storage.next_colony_id == before + 1,
          "id=" .. tostring(cid) .. " next=" .. tostring(storage.next_colony_id))
        if not c then finish() return end

        -- One evaluation cycle: verify the whole adapter chain, then finish.
        ctx.after(300, function()
          local ok2, err2 = pcall(function()
            local d = built
            ctx.check("the founding dome is still valid after an evaluation", d and d.valid)
            ctx.check("c.hall IS the founding dome (unit_number)",
              c and c.hall and c.hall.valid and c.hall.unit_number == d.unit_number
              and c.hall.name == DOME, "hall=" .. tostring(c and c.hall and c.hall.name))
            ctx.check("colony.surface_index is the platform surface",
              c and c.surface_index == surface.index,
              tostring(c and c.surface_index) .. " vs " .. tostring(surface.index))
            ctx.check("domes registry holds the founding dome",
              c and c.domes and c.domes[d.unit_number] ~= nil)
            ctx.check("the dome is registered as a house of kind 'dome'",
              c and c.houses and c.houses[d.unit_number] and c.houses[d.unit_number].kind == "dome")
            ctx.check("dome_list reports exactly one dome", c and #colony.dome_list(c) == 1,
              c and tostring(#colony.dome_list(c)) or "no colony")
            ctx.check("a single dome supplies 32 beds", c and colony.capacity(c) >= 32,
              c and tostring(colony.capacity(c)) or "no colony")

            local handlers, summary = scheduled_for(c.id)
            ctx.probe("scheduler jobs for the dome colony", function() return summary end)
            ctx.check("scheduler chains run: colony.evaluate + construct.scan + work.machine_sweep",
              handlers["colony.evaluate"] ~= nil and handlers["construct.scan"] ~= nil
              and handlers["work.machine_sweep"] ~= nil, summary)

            local owner_in = territory.owner_at(surface.index,
              {x = d.position.x + 60, y = d.position.y})
            local owner_70 = territory.owner_at(surface.index,
              {x = d.position.x + 70, y = d.position.y})
            local owner_out = territory.owner_at(surface.index,
              {x = d.position.x + 200, y = d.position.y})
            ctx.check("territory covers a point 60 tiles from the dome",
              owner_in == c.id, tostring(owner_in))
            ctx.probe("owner 70 tiles out (beyond DOME_RADIUS=64)", function() return tostring(owner_70) end)
            ctx.check("+70 is outside the 64-tile dome ring", owner_70 == nil, tostring(owner_70))
            ctx.check("a far-away platform point is unowned", owner_out == nil, tostring(owner_out))

            local seeded
            ctx.probe("seed_forage on a platform (no forage tiles)", function()
              local ok3, n = pcall(function() return colony.seed_forage(c) end)
              if not ok3 then return "ERROR: " .. tostring(n) end
              seeded = n
              local patches = surface.find_entities_filtered{name = "colony-forage-patch"}
              return "seeded=" .. tostring(n) .. " patches=" .. #patches
            end)
            ctx.check("seed_forage did not conjure forage on a platform",
              seeded == 0 and #surface.find_entities_filtered{name = "colony-forage-patch"} == 0,
              tostring(seeded))
          end)
          if not ok2 then ctx.log("[ERR] platform acceptance phase crashed: " .. tostring(err2)) end

          ctx.probe("on_space_platform_built_entity fired count", function() return built_fired end)
          if built_fired > 0 then
            ctx.check("built event fields observed", built_report ~= "none", built_report)
            ctx.log("built event data: " .. built_report)
          else
            ctx.log("on_space_platform_built_entity did NOT fire for scripted create_entity (matches s23)")
          end
          ctx.probe("script_raised_built fired count", function() return script_built_fired end)
          if script_built_fired > 0 then ctx.log("script_raised_built data: " .. script_built_report) end
          finish()
        end)
      end)
      if not ok then
        ctx.log("[ERR] platform setup phase crashed: " .. tostring(err))
        finish()
      end
    end)
  end,
})
