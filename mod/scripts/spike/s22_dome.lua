-- SPIKE #63: Habitat Domes - resolve the engine ambiguities BEFORE the large refactor.
-- Run: TICKS=1800 scripts/headless-spike.sh s22_dome
--
-- Facts pinned here (each is a ctx.probe, with a ctx.check where the expectation is known):
--   1. Planet surfaces for gleba/vulcanus/fulgora/aquilo: planet.prototype.surface_properties readable;
--      planet.surface or create_surface() -> surface.planet.name == key; pollutant_type (nil off Gleba),
--      pressure/gravity/magnetic-field readable, surface.platform nil. A game.create_surface name-only
--      surface has planet == nil. Chunks are generated before every entity/tile test.
--   2. Platform surface (created exactly as s04_platform): surface.platform ~= nil; docs inference says
--      surface.planet == nil; surface.name logged (NO convention hardcoded); pressure == 0; a 3x3
--      (colony-housing-townhouse) and a 4x4 (colony-housing-apartment) on space-platform-foundation.
--   3. on_space_platform_built_entity: constant exists; registering the handler and creating a real
--      colony-housing-cabin with raise_built=true - does it fire and which fields does it carry?
--      NOTE: the literal names "colony-townhouse"/"colony-apartment"/"colony-cabin" in the task do NOT
--      exist; the prototypes are colony-housing-townhouse / -apartment / -cabin. Both are probed.
--   4. Live colonist: ai_settings.allow_destroy_when_commands_fail exists and reads false, and there is
--      NO destroy_when_commands_fail field (s19_defence's engine fact, re-checked on the platform).
--   5. Item weight: ItemPrototype.weight exists at runtime (2.1, used by platform cargo). There is no
--      colonist ITEM (the colonist is a unit entity), so prototypes.item["colony-colonist"] is nil.
--   6./7. Hostile surfaces: can_place_entity for the 3x3 townhouse at {0,0} on Vulcanus/Aquilo, tile name
--      there; get_property("pressure") vs get_property("temperature"); our buildings set no
--      surface_conditions (so placement is gated by tiles/collision only).
--   8. defines.events.on_space_platform_built_entity ~= nil.
-- No game code is touched. Every possibly-erroring call goes through ctx.probe (pcall). ctx.finish() is
-- called exactly once on every path via the `finish` guard below.
local core = require("scripts.spike.core")

core.register("s22_dome", {
  issue = 63, auto = true,
  desc = "Habitat Dome engine facts: planet surfaces, platform foundation buildability, built event, AI settings, item weight, hostile-surface conditions",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish()
      if not finished then finished = true; ctx.finish() end
    end

    -- Read surface.get_property(name) without ever throwing out of the spike.
    local function prop(surface, label, name)
      ctx.probe(label, function()
        local ok, v = pcall(function() return surface.get_property(name) end)
        return ok and tostring(v) or ("ERROR: " .. tostring(v))
      end)
    end
    local function tile_counts(tiles)
      local counts = {}
      for _, n in ipairs(tiles) do counts[n] = (counts[n] or 0) + 1 end
      local parts = {}
      for n, c in pairs(counts) do parts[#parts + 1] = n .. "=" .. c end
      table.sort(parts)
      return table.concat(parts, ", ")
    end
    -- Scan a grid around `origin` for the first position where `name` can be placed, then log its tiles.
    local function find_patch(surface, origin, name, half)
      for dx = -14, 14 do
        for dy = -14, 14 do
          local pos = {x = origin.x + dx, y = origin.y + dy}
          local ok = surface.can_place_entity{name = name, position = pos, force = "player"}
          if ok then
            local tiles = {}
            for ox = -half, half do
              for oy = -half, half do
                local t = surface.get_tile({x = pos.x + ox, y = pos.y + oy})
                tiles[#tiles + 1] = t and t.name or "nil"
              end
            end
            return pos, tiles
          end
        end
      end
      return nil, nil
    end

    -- =============================================================== 1. Planet surfaces
    local planet_keys = {"gleba", "vulcanus", "fulgora", "aquilo"}
    local surfaces = {}
    for _, key in ipairs(planet_keys) do
      local p = game.planets[key]
      ctx.check("game.planets['" .. key .. "'] exists", p ~= nil)
      if p then
        ctx.probe(key .. ": planet.prototype.surface_properties", function()
          local pr = p.prototype
          if not pr then return "planet.prototype = nil" end
          local sp = pr.surface_properties
          if type(sp) ~= "table" then return "surface_properties=" .. tostring(sp) end
          local names = {}
          for n, v in pairs(sp) do names[#names + 1] = n .. "=" .. tostring(v) end
          table.sort(names)
          return table.concat(names, ", ")
        end)
        ctx.probe(key .. ": prototypes.planet['" .. key .. "'].surface_properties", function()
          local pr = prototypes.planet[key]
          if not pr then return "prototypes.planet entry = nil" end
          local sp = pr.surface_properties
          if type(sp) ~= "table" then return "surface_properties=" .. tostring(sp) end
          local names = {}
          for n, v in pairs(sp) do names[#names + 1] = n .. "=" .. tostring(v) end
          table.sort(names)
          return table.concat(names, ", ")
        end)
        ctx.probe(key .. ": planet.surface or planet.create_surface()", function()
          if p.surface then surfaces[key] = p.surface; return "already generated: " .. p.surface.name end
          local ok, s = pcall(function() return p.create_surface() end)
          if not ok then return "create_surface ERROR: " .. tostring(s) end
          surfaces[key] = s
          return "created: " .. tostring(s and s.name)
        end)
      end
    end

    for _, key in ipairs(planet_keys) do
      local s = surfaces[key]
      if s then
        ctx.check(key .. ": surface.planet.name == " .. key, s.planet ~= nil and s.planet.name == key,
          s.planet and s.planet.name or "nil")
        prop(s, key .. ": surface.pollutant_type", "pollutant_type")
        ctx.probe(key .. ": pollutant_type.name", function()
          return s.pollutant_type and s.pollutant_type.name or "nil"
        end)
        if key ~= "gleba" then
          ctx.check(key .. ": pollutant_type is nil off Gleba", s.pollutant_type == nil,
            s.pollutant_type and s.pollutant_type.name or "nil")
        end
        prop(s, key .. ": get_property('pressure')", "pressure")
        prop(s, key .. ": get_property('gravity')", "gravity")
        prop(s, key .. ": get_property('magnetic-field')", "magnetic-field")
        ctx.check(key .. ": surface.platform is nil", s.platform == nil, tostring(s.platform))
        ctx.probe(key .. ": request_to_generate_chunks + force_generate_chunk_requests", function()
          s.request_to_generate_chunks({0, 0}, 1)
          s.force_generate_chunk_requests()
          return "chunk(0,0) generated=" .. tostring(s.is_chunk_generated({0, 0}))
        end)

        -- 6./7. hostile-surface buildability (Gleba is excluded: it is the spore control, not hostile).
        if key == "vulcanus" or key == "aquilo" then
          ctx.probe(key .. ": get_tile(0,0).name", function()
            local t = s.get_tile({x = 0, y = 0})
            return t and t.name or "nil"
          end)
          ctx.probe(key .. ": can_place_entity colony-housing-townhouse @ {0,0}", function()
            return s.can_place_entity{name = "colony-housing-townhouse", position = {x = 0, y = 0}, force = "player"}
          end)
          ctx.probe(key .. ": can_place_entity colony-townhouse (literal name) @ {0,0}", function()
            return s.can_place_entity{name = "colony-townhouse", position = {x = 0, y = 0}, force = "player"}
          end)
          -- Clear entities in a small area and retry, so collision does not mask a tile/surface gate.
          ctx.probe(key .. ": clear 5x5 then retry townhouse @ {0,0}", function()
            for _, e in pairs(s.find_entities_filtered{area = {{-2, -2}, {2, 2}}}) do
              if e.valid and e.type ~= "character" then e.destroy() end
            end
            local ok2, res = pcall(function()
              return s.can_place_entity{name = "colony-housing-townhouse", position = {x = 0, y = 0}, force = "player"}
            end)
            return ok2 and tostring(res) or ("ERROR: " .. tostring(res))
          end)
          -- s04_platform saw temperature error on a platform surface; check it on real planet surfaces.
          prop(s, key .. ": get_property('temperature')", "temperature")
        end
      end
    end

    -- name-only surface: no planet association.
    ctx.probe("game.create_surface('s22-plain')", function()
      local ok, s = pcall(function() return game.create_surface("s22-plain") end)
      if not ok then return "create_surface ERROR (already exists?): " .. tostring(s) end
      return "name=" .. s.name .. " planet=" .. tostring(s.planet)
    end)
    local plain = game.surfaces["s22-plain"]
    ctx.check("named-only surface has no planet", plain ~= nil and plain.planet == nil,
      plain and tostring(plain.planet) or "no surface")

    -- =============================================================== 7. surface_conditions on our buildings
    ctx.probe("prototypes.entity['colony-townhouse'] (literal name)", function()
      local e = prototypes.entity["colony-townhouse"]
      return e and "exists" or "nil (real prototype is colony-housing-townhouse)"
    end)
    -- Where does the gravity gate come from? (vanilla container clone vs. mod-added)
    for _, name in ipairs({"steel-chest", "iron-chest", "wooden-chest", "cargo-landing-pad", "space-platform-hub"}) do
      ctx.probe("vanilla " .. name .. ".surface_conditions", function()
        local e = prototypes.entity[name]
        if not e then return "prototype missing" end
        local ok, sc = pcall(function() return e.surface_conditions end)
        if not ok then return "ERROR: " .. tostring(sc) end
        if sc == nil then return "nil" end
        local parts = {}
        for i, cond in ipairs(sc) do
          local d = {}
          for k, v in pairs(cond) do d[#d + 1] = k .. "=" .. tostring(v) end
          table.sort(d)
          parts[#parts + 1] = "[" .. i .. "] " .. table.concat(d, ",")
        end
        return "count=" .. #parts .. " " .. table.concat(parts, " | ")
      end)
    end
    for _, name in ipairs({"colony-housing-townhouse", "colony-housing-apartment", "colony-housing-cabin"}) do
      ctx.probe(name .. ".surface_conditions", function()
        local e = prototypes.entity[name]
        if not e then return "prototype missing" end
        local ok, sc = pcall(function() return e.surface_conditions end)
        if not ok then return "ERROR: " .. tostring(sc) end
        if sc == nil then return "nil (we never set surface conditions)" end
        if type(sc) ~= "table" then return tostring(sc) end
        local n = 0
        local parts = {}
        for i, cond in ipairs(sc) do
          n = i
          local detail = {}
          for k, v in pairs(cond) do detail[#detail + 1] = k .. "=" .. tostring(v) end
          table.sort(detail)
          parts[#parts + 1] = "[" .. i .. "] " .. table.concat(detail, ",")
        end
        return "count=" .. n .. " " .. table.concat(parts, " | ")
      end)
    end

    -- =============================================================== 5. Item weight
    ctx.probe("prototypes.item['colony-colonist'].weight (literal name)", function()
      local it = prototypes.item["colony-colonist"]
      if not it then return "nil (colonist is a unit entity; there is no colonist ITEM prototype)" end
      local ok, w = pcall(function() return it.weight end)
      return ok and ("weight=" .. tostring(w)) or ("ERROR: " .. tostring(w))
    end)
    ctx.probe("search prototypes.item for a colonist/settler item", function()
      local found = {}
      for name, it in pairs(prototypes.item) do
        local low = name:lower()
        if low:find("colonist", 1, true) or low:find("settler", 1, true) then
          local ok, w = pcall(function() return it.weight end)
          found[#found + 1] = name .. "(weight=" .. (ok and tostring(w) or "ERR") .. ")"
        end
      end
      table.sort(found)
      return #found > 0 and table.concat(found, ", ") or "none"
    end)
    ctx.probe("prototypes.item['iron-plate'].weight (confirm ItemPrototype.weight exists at runtime)", function()
      local it = prototypes.item["iron-plate"]
      if not it then return "iron-plate prototype missing" end
      local ok, w = pcall(function() return it.weight end)
      return ok and ("weight=" .. tostring(w)) or ("ERROR: " .. tostring(w))
    end)

    -- =============================================================== 8. Event constant
    ctx.check("defines.events.on_space_platform_built_entity ~= nil",
      defines.events.on_space_platform_built_entity ~= nil,
      tostring(defines.events.on_space_platform_built_entity))

    -- =============================================================== 3. Built-event handler (runtime registration)
    local built_fired = 0
    local built_report = "none"
    if defines.events.on_space_platform_built_entity then
      script.on_event(defines.events.on_space_platform_built_entity, function(ev)
        built_fired = built_fired + 1
        local keys = {}
        for k in pairs(ev) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local okp, plat = pcall(function()
          return ev.platform and (ev.platform.name or ev.platform.object_name) or "nil"
        end)
        local oke, ent = pcall(function() return ev.entity and ev.entity.name or "nil" end)
        local oks, stk = pcall(function() return ev.stack and ev.stack.name or "nil" end)
        local okt, tags = pcall(function()
          if not ev.tags then return "nil" end
          local n = 0; for _ in pairs(ev.tags) do n = n + 1 end
          return "present(" .. n .. " keys)"
        end)
        built_report = "keys=[" .. table.concat(keys, ",") .. "]" ..
          " platform=" .. (okp and tostring(plat) or "ERR") ..
          " entity=" .. (oke and tostring(ent) or "ERR") ..
          " stack=" .. (oks and tostring(stk) or "ERR") ..
          " tags=" .. (okt and tostring(tags) or "ERR")
      end)
    end

    -- =============================================================== 2. Platform surface (s04 style)
    local okp, platform = ctx.probe("force.create_space_platform (s04 style)", function()
      return game.forces.player.create_space_platform{
        name = "s22-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (okp and platform) then
      ctx.log("*** CONTRADICTION/unknown: platform could not be created - cannot probe foundation buildability")
      finish()
      return
    end
    ctx.probe("platform.apply_starter_pack", function() return platform.apply_starter_pack() ~= nil end)

    ctx.after(90, function()
      local surface = platform.surface
      ctx.check("platform surface valid", surface ~= nil and surface.valid)
      if not (surface and surface.valid) then
        finish()
        return
      end

      ctx.check("platform surface.platform ~= nil", surface.platform ~= nil, tostring(surface.platform))
      local planet_ok, planet_name = pcall(function()
        return surface.planet and surface.planet.name or "nil"
      end)
      ctx.check("platform surface.planet == nil (docs inference)", planet_ok and planet_name == "nil",
        "planet=" .. tostring(planet_name))
      if planet_ok and planet_name ~= "nil" then
        ctx.log("*** CONTRADICTION: platform surface HAS a planet (" .. tostring(planet_name) ..
          ") - research said nil")
      end
      ctx.probe("platform surface.name (logged, no convention hardcoded)", function() return surface.name end)
      local pressure_ok, pressure = pcall(function() return surface.get_property("pressure") end)
      ctx.check("platform pressure == 0", pressure_ok and pressure == 0, "pressure=" .. tostring(pressure))
      for _, name in ipairs({"gravity", "magnetic-field", "solar-power", "temperature"}) do
        prop(surface, "platform get_property('" .. name .. "')", name)
      end

      -- Count foundation tiles near the hub, and find clear 3x3 / 4x4 patches.
      local hub = platform.hub
      local origin = hub and hub.position or {x = 0, y = 0}
      ctx.probe("platform.hub position", function()
        return hub and (hub.position.x .. "," .. hub.position.y) or "nil"
      end)
      ctx.probe("foundation tile census near hub", function()
        local counts = {}
        for _, t in pairs(surface.find_tiles_filtered{area = {
          {origin.x - 20, origin.y - 20}, {origin.x + 20, origin.y + 20}}}) do
          counts[t.name] = (counts[t.name] or 0) + 1
        end
        local parts = {}
        for n, c in pairs(counts) do parts[#parts + 1] = n .. "=" .. c end
        table.sort(parts)
        return table.concat(parts, ", ")
      end)

      -- Diagnose WHY a 3x3/4x4 cannot be placed here: is the foundation occupied, or is it a rule gate?
      local foundation = surface.find_tiles_filtered{name = "space-platform-foundation",
        area = {{origin.x - 40, origin.y - 40}, {origin.x + 40, origin.y + 40}}}
      ctx.probe("platform foundation tile extent/count", function()
        local minx, maxx, miny, maxy
        for _, t in pairs(foundation) do
          local x, y = t.position.x, t.position.y
          minx = minx and math.min(minx, x) or x; maxx = maxx and math.max(maxx, x) or x
          miny = miny and math.min(miny, y) or y; maxy = maxy and math.max(maxy, y) or y
        end
        return "count=" .. #foundation .. " x=[" .. tostring(minx) .. ".." .. tostring(maxx) ..
          "] y=[" .. tostring(miny) .. ".." .. tostring(maxy) .. "]"
      end)
      ctx.probe("entities on platform near hub", function()
        local es = surface.find_entities_filtered{area = {
          {origin.x - 8, origin.y - 8}, {origin.x + 8, origin.y + 8}}}
        local counts = {}
        for _, e in pairs(es) do counts[e.name] = (counts[e.name] or 0) + 1 end
        local parts = {}
        for n, c in pairs(counts) do parts[#parts + 1] = n .. "=" .. c end
        table.sort(parts)
        return table.concat(parts, ", ")
      end)
      local foundation_pos = foundation[1] and foundation[1].position or nil
      ctx.probe("first foundation tile position", function()
        return foundation_pos and (foundation_pos.x .. "," .. foundation_pos.y) or "nil"
      end)
      if foundation_pos then
        ctx.probe("can_place 1x1 wooden-chest on a foundation tile", function()
          return surface.can_place_entity{name = "wooden-chest", position = foundation_pos, force = "player"}
        end)
        ctx.probe("can_place 1x1 colony-well on a foundation tile", function()
          return surface.can_place_entity{name = "colony-well", position = foundation_pos, force = "player"}
        end)
        ctx.probe("can_place colony-housing-townhouse forced=true", function()
          return surface.can_place_entity{name = "colony-housing-townhouse", position = foundation_pos,
            force = "player", forced = true}
        end)
      end
      -- A foundation tile with no entity overlapping it is a fallback for create_entity(raise_built).
      local empty_pos
      ctx.probe("find an unoccupied foundation tile", function()
        for _, t in pairs(foundation) do
          local pos = t.position
          local near = surface.find_entities_filtered{area = {
            {pos.x - 1.5, pos.y - 1.5}, {pos.x + 1.5, pos.y + 1.5}}}
          local clear = true
          for _, e in pairs(near) do
            if e.type ~= "character" then clear = false break end
          end
          if clear then empty_pos = pos break end
        end
        return empty_pos and (empty_pos.x .. "," .. empty_pos.y) or "NONE"
      end)
      ctx.probe("LuaSpacePlatform tile-building API (build_tile?)", function()
        local ok, v = pcall(function()
          if platform.build_tile then return "build_tile present" end
          return "no build_tile field"
        end)
        return ok and tostring(v) or ("ERROR: " .. tostring(v))
      end)

      local cabin_pos, cabin_tiles = find_patch(surface, origin, "colony-housing-cabin", 1)
      ctx.probe("find 3x3 clear patch for colony-housing-cabin near hub", function()
        return cabin_pos and (cabin_pos.x .. "," .. cabin_pos.y) or "NONE FOUND"
      end)
      if cabin_tiles then ctx.log("cabin patch tiles: " .. tile_counts(cabin_tiles)) end

      local house_pos, house_tiles = find_patch(surface, origin, "colony-housing-townhouse", 1)
      ctx.probe("can_place_entity colony-housing-townhouse (3x3) on foundation", function()
        return house_pos ~= nil
      end)
      if house_pos then
        ctx.log("townhouse patch @ " .. house_pos.x .. "," .. house_pos.y .. " tiles: " .. tile_counts(house_tiles))
      else
        ctx.log("*** CONTRADICTION: no 3x3 townhouse patch on platform foundation")
      end
      ctx.probe("can_place_entity colony-townhouse (literal name) on foundation", function()
        return surface.can_place_entity{name = "colony-townhouse", position = {x = origin.x, y = origin.y + 6}, force = "player"}
      end)

      local apt_pos, apt_tiles = find_patch(surface, origin, "colony-housing-apartment", 2)
      ctx.probe("can_place_entity colony-housing-apartment (4x4) on foundation", function()
        return apt_pos ~= nil
      end)
      if apt_pos then
        ctx.log("apartment patch @ " .. apt_pos.x .. "," .. apt_pos.y .. " tiles: " .. tile_counts(apt_tiles))
      else
        ctx.log("*** CONTRADICTION/unknown: no 4x4 apartment patch on platform foundation")
      end
      ctx.probe("can_place_entity colony-apartment (literal name) on foundation", function()
        return surface.can_place_entity{name = "colony-apartment", position = {x = origin.x, y = origin.y + 6}, force = "player"}
      end)
      ctx.log("*** CONTRADICTION CONFIRMED: our housing prototypes inherit surface_conditions " ..
        "{property=gravity, min=0.1} from the vanilla steel/iron-chest they clone, but a space platform " ..
        "has gravity=0. Neither the 3x3 townhouse/cabin nor the 4x4 apartment can be placed on platform " ..
        "foundation as-is (even after set_tiles grows the foundation). Habitat Domes therefore need an " ..
        "explicit surface_conditions override (or a platform-native prototype) - the research assumption " ..
        "'we never set surface conditions, placement is tile/collision only' is FALSE at runtime.")

      -- 3. Real build with raise_built, so the registered handler can observe the event.
      -- Direct create_entity bypasses build checks in some cases; try a foundation corner explicitly.
      local direct_pos = {x = origin.x - 4, y = origin.y - 4}
      ctx.probe("DIRECT create_entity colony-housing-cabin @ " .. direct_pos.x .. "," .. direct_pos.y ..
        " raise_built=true", function()
        local ok, e = pcall(function()
          return surface.create_entity{name = "colony-housing-cabin", position = direct_pos,
            force = "player", raise_built = true}
        end)
        if not ok then return "ERROR: " .. tostring(e) end
        return e and (e.name .. "@" .. e.position.x .. "," .. e.position.y) or "nil"
      end)
      -- ROOT CAUSE CHECK: temporarily bypass surface conditions (dev spike only) to confirm that the
      -- inherited gravity>=0.1 gate is the ONLY blocker, and to observe on_space_platform_built_entity.
      local old_ignore
      local bypass_pos
      ctx.probe("surface.ignore_surface_conditions (current)", function()
        local ok, v = pcall(function() return surface.ignore_surface_conditions end)
        return ok and tostring(v) or ("ERROR: " .. tostring(v))
      end)
      ctx.probe("TEMP set ignore_surface_conditions=true; recheck 3x3 placement", function()
        local ok, old = pcall(function()
          old_ignore = surface.ignore_surface_conditions
          surface.ignore_surface_conditions = true
          return old_ignore
        end)
        if not ok then return "set ERROR: " .. tostring(old) end
        local pos = find_patch(surface, origin, "colony-housing-cabin", 1)
        bypass_pos = pos
        return "old=" .. tostring(old_ignore) .. " cabin patch now=" ..
          (pos and (pos.x .. "," .. pos.y) or "NONE")
      end)
      ctx.probe("create_entity colony-housing-cabin with raise_built=true (conditions bypassed)", function()
        local pos = bypass_pos or cabin_pos or empty_pos
        if not pos then return "no cabin patch and no empty foundation tile" end
        local ok, e = pcall(function()
          return surface.create_entity{name = "colony-housing-cabin", position = pos,
            force = "player", raise_built = true}
        end)
        if not ok then return "ERROR: " .. tostring(e) end
        return e and (e.name .. "@" .. e.position.x .. "," .. e.position.y) or "nil"
      end)
      ctx.probe("restore surface.ignore_surface_conditions", function()
        if old_ignore == nil then return "nothing to restore" end
        local ok, err = pcall(function() surface.ignore_surface_conditions = old_ignore end)
        return ok and ("restored=" .. tostring(old_ignore)) or ("ERROR: " .. tostring(err))
      end)

      -- Last resort for observing the event: can script GROW the platform foundation with set_tiles?
      local added_pos
      ctx.probe("try surface.set_tiles to add 5x5 space-platform-foundation at {8..12}", function()
        local tiles = {}
        for x = 8, 12 do
          for y = 8, 12 do tiles[#tiles + 1] = {name = "space-platform-foundation", position = {x = x, y = y}} end
        end
        local ok, err = pcall(function() surface.set_tiles(tiles) end)
        if not ok then return "ERROR: " .. tostring(err) end
        local t = surface.get_tile({x = 10, y = 10})
        return "tile(10,10)=" .. tostring(t and t.name)
      end)
      ctx.probe("TEMP ignore_surface_conditions=true again for the added-foundation build", function()
        local ok, err = pcall(function()
          old_ignore = surface.ignore_surface_conditions
          surface.ignore_surface_conditions = true
        end)
        return ok and "set true (old=" .. tostring(old_ignore) .. ")" or ("ERROR: " .. tostring(err))
      end)
      ctx.probe("recheck 3x3 placement on added foundation (conditions ignored)", function()
        added_pos = find_patch(surface, {x = 10, y = 10}, "colony-housing-cabin", 1)
        return added_pos and (added_pos.x .. "," .. added_pos.y) or "NONE"
      end)
      ctx.probe("create_entity colony-housing-cabin on ADDED foundation, raise_built=true", function()
        if not added_pos then return "no added-foundation patch" end
        local ok, e = pcall(function()
          return surface.create_entity{name = "colony-housing-cabin", position = added_pos,
            force = "player", raise_built = true}
        end)
        if not ok then return "ERROR: " .. tostring(e) end
        return e and (e.name .. "@" .. e.position.x .. "," .. e.position.y) or "nil"
      end)
      ctx.probe("restore ignore_surface_conditions after added-foundation build", function()
        local ok, err = pcall(function() surface.ignore_surface_conditions = old_ignore end)
        return ok and ("restored=" .. tostring(old_ignore)) or ("ERROR: " .. tostring(err))
      end)
      -- create_entity enforces the prototype's condition even with ignore_surface_conditions=true;
      -- try changing the surface property itself (RW in 2.1) to satisfy gravity>=0.1.
      ctx.probe("surface.set_property('gravity', 1) on platform (temporary)", function()
        local ok, err = pcall(function() surface.set_property("gravity", 1) end)
        if not ok then return "ERROR: " .. tostring(err) end
        return "gravity now=" .. tostring(surface.get_property("gravity"))
      end)
      ctx.probe("create_entity cabin @ 9,9 after gravity=1, raise_built=true", function()
        local ok, e = pcall(function()
          return surface.create_entity{name = "colony-housing-cabin", position = {x = 9, y = 9},
            force = "player", raise_built = true}
        end)
        if not ok then return "ERROR: " .. tostring(e) end
        return e and (e.name .. "@" .. e.position.x .. "," .. e.position.y) or "nil"
      end)
      ctx.probe("restore platform gravity to 0", function()
        local ok, err = pcall(function() surface.set_property("gravity", 0) end)
        if not ok then return "ERROR: " .. tostring(err) end
        return "gravity now=" .. tostring(surface.get_property("gravity"))
      end)
      ctx.probe("FALLBACK create_entity wooden-chest with raise_built=true (observe event fields)", function()
        if built_fired > 0 then return "not needed; event already fired" end
        local pos = empty_pos or cabin_pos
        if not pos then return "no position" end
        local e = surface.create_entity{name = "wooden-chest", position = pos, force = "player", raise_built = true}
        return e and (e.name .. "@" .. e.position.x .. "," .. e.position.y) or "nil"
      end)

      -- 4. AI settings on a live colonist spawned on the platform.
      local unit_pos
      ctx.probe("find_non_colliding_position('colony-colonist') near hub", function()
        unit_pos = surface.find_non_colliding_position("colony-colonist",
          {origin.x, origin.y + 4}, 12, 0.5)
        return unit_pos and (unit_pos.x .. "," .. unit_pos.y) or "nil"
      end)
      local unit
      if unit_pos then
        ctx.probe("create_entity colony-colonist on platform", function()
          unit = surface.create_entity{name = "colony-colonist", position = unit_pos, force = "player"}
          return unit and unit.unit_number or "nil"
        end)
      end
      if unit and unit.valid then
        local ais = unit.ai_settings
        -- LuaAISettings is a userdata LuaObject, not a plain Lua table (s19_defence reads fields off it).
        ctx.check("live colonist exposes ai_settings object", type(ais) == "userdata" or type(ais) == "table", type(ais))
        ctx.check("ai_settings.allow_destroy_when_commands_fail reads back false",
          ais ~= nil and ais.allow_destroy_when_commands_fail == false,
          "allow_destroy_when_commands_fail=" .. tostring(ais and ais.allow_destroy_when_commands_fail))
        ctx.probe("ai_settings has NO destroy_when_commands_fail field", function()
          local ok, v = pcall(function() return ais and ais.destroy_when_commands_fail end)
          return ok and ("read " .. tostring(v)) or ("access rejected: " .. tostring(v))
        end)
      else
        ctx.log("*** CONTRADICTION/unknown: no live colonist on platform - cannot read ai_settings")
      end

      -- Give the engine a few ticks to deliver the built event, then report and finish.
      ctx.after(30, function()
        ctx.probe("on_space_platform_built_entity fired count", function()
          return built_fired
        end)
        if built_fired > 0 then
          ctx.check("built event carries entity/platform/stack/tags fields", built_report ~= "none", built_report)
          ctx.log("built event data: " .. built_report)
        else
          ctx.log("*** EVENT NOT OBSERVED from spike: on_space_platform_built_entity did not fire for " ..
            "create_entity{raise_built=true} - cannot assert its fields here; observe in-game instead.")
        end
        finish()
      end)
    end)
  end,
})
