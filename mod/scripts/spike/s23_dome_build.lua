-- SPIKE #63 (de-risking): can a Habitat-Dome-style prototype actually be BUILT on a space platform?
-- Run: TICKS=1800 scripts/headless-spike.sh s23_dome_build
--
-- s22_dome proved our housing clones inherit {property = gravity, min = 0.1} from the vanilla steel/iron
-- chest and that gravity-0 platforms refuse them even with create_entity / forced / ignore_surface_conditions.
-- This spike adds a dev-only steel-chest clone with surface_conditions EXPLICITLY CLEARED
-- (prototypes/spikes.lua :: colony-spike-dome) and asks the one question that gates the whole refactor:
--   with the gravity gate gone, does can_place_entity / create_entity succeed on platform foundation?
-- It also proves the inherited-gate control still fails, that ordinary Nauvis is unaffected, and whether
-- defines.events.on_space_platform_built_entity fires for the successful build.
--
-- Every engine call that might disagree with the docs goes through ctx.probe (pcall). ctx.finish() is
-- called exactly once on every path via the `finish` guard below.
local core = require("scripts.spike.core")

core.register("s23_dome_build", {
  issue = 63, auto = false,
  desc = "prove a surface-condition-free dome prototype can be placed/created on a space platform, with inherited-gate and Nauvis controls",
  usage = "",
  run = function(ctx)
    local finished = false
    local function finish()
      if not finished then finished = true; ctx.finish() end
    end

    local DOME = "colony-spike-dome"
    local HOUSE = "colony-housing-townhouse"   -- inherits gravity >= 0.1, our control

    -- Format a prototype's surface_conditions the same way s22_dome did, so the logs are comparable.
    local function fmt_surface_conditions(name)
      local e = prototypes.entity[name]
      if not e then return "MISSING" end
      local ok, sc = pcall(function() return e.surface_conditions end)
      if not ok then return "ERROR: " .. tostring(sc) end
      if sc == nil then return "nil (no surface conditions)" end
      if type(sc) ~= "table" then return tostring(sc) end
      local n, parts = 0, {}
      for i, cond in ipairs(sc) do
        n = i
        local d = {}
        for k, v in pairs(cond) do d[#d + 1] = k .. "=" .. tostring(v) end
        table.sort(d)
        parts[#parts + 1] = "[" .. i .. "]" .. table.concat(d, ",")
      end
      return "count=" .. n .. " " .. table.concat(parts, " | ")
    end
    local function fmt_tiles(surface, cx, cy, r)
      local counts = {}
      for _, t in pairs(surface.find_tiles_filtered{area = {{cx - r, cy - r}, {cx + r, cy + r}}}) do
        counts[t.name] = (counts[t.name] or 0) + 1
      end
      local parts = {}
      for n, c in pairs(counts) do parts[#parts + 1] = n .. "=" .. c end
      table.sort(parts)
      return table.concat(parts, ", ")
    end
    -- First tile-center position in a square scan where `name` can be placed.
    local function find_patch(surface, cx, cy, name, radius)
      for dx = -radius, radius do
        for dy = -radius, radius do
          local pos = {x = cx + dx, y = cy + dy}
          if surface.can_place_entity{name = name, position = pos, force = "player"} then
            return pos
          end
        end
      end
      return nil
    end
    local function pos_str(pos)
      return pos and (pos.x .. "," .. pos.y) or "NONE"
    end

    -- ============================================================ prototype facts
    ctx.check("spike dome prototype exists", prototypes.entity[DOME] ~= nil, DOME)
    ctx.check("spike dome ITEM exists", prototypes.item[DOME] ~= nil, DOME)
    if not prototypes.entity[DOME] then
      ctx.log("*** The dev-only dome prototype did not load - cannot proceed (check colony-spike-protos startup setting).")
      finish()
      return
    end
    ctx.probe(DOME .. ".surface_conditions", function() return fmt_surface_conditions(DOME) end)
    ctx.probe(HOUSE .. ".surface_conditions", function() return fmt_surface_conditions(HOUSE) end)
    ctx.probe(DOME .. ".collision_box", function()
      local cb = prototypes.entity[DOME].collision_box
      if not cb then return "nil" end
      local function p(t)
        if not t then return "nil" end
        if t.x then return t.x .. "," .. t.y end
        return tostring(t[1]) .. "," .. tostring(t[2])
      end
      if cb.left_top then return p(cb.left_top) .. " .. " .. p(cb.right_bottom) end
      return p(cb[1]) .. " .. " .. p(cb[2])
    end)
    ctx.check("defines.events.on_space_platform_built_entity exists",
      defines.events.on_space_platform_built_entity ~= nil,
      tostring(defines.events.on_space_platform_built_entity))

    -- ============================================================ built-event observers
    -- Docs: on_space_platform_built_entity is raised when the PLATFORM (its construction robots) builds,
    -- with fields platform/entity/stack/tags. A scripted create_entity{raise_built=true} instead raises
    -- script_raised_built (entity only). Both are registered so the report shows which path actually fires.
    local script_built_fired = 0
    local script_built_report = "none"
    if defines.events.script_raised_built then
      script.on_event(defines.events.script_raised_built, function(ev)
        script_built_fired = script_built_fired + 1
        local e = ev.entity
        script_built_report = "entity=" .. tostring(e and e.name) ..
          " surface=" .. tostring(e and e.valid and e.surface and e.surface.name)
      end)
    end
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
        local oke, ent = pcall(function()
          if not ev.entity then return "nil" end
          return ev.entity.name .. "@" .. ev.entity.position.x .. "," .. ev.entity.position.y
        end)
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

    -- ============================================================ platform (exactly as s04_platform)
    local okp, platform = ctx.probe("force.create_space_platform (s04 style)", function()
      return game.forces.player.create_space_platform{
        name = "s23-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    end)
    if not (okp and platform) then
      ctx.log("*** platform could not be created - cannot prove platform buildability")
      finish()
      return
    end
    ctx.probe("platform.apply_starter_pack", function() return platform.apply_starter_pack() ~= nil end)

    ctx.after(90, function()
      local surface = platform.surface
      ctx.check("platform surface valid", surface ~= nil and surface.valid)
      if not (surface and surface.valid) then finish() return end
      ctx.probe("platform surface.name", function() return surface.name end)
      ctx.probe("platform gravity / pressure", function()
        return "gravity=" .. tostring(surface.get_property("gravity")) ..
          " pressure=" .. tostring(surface.get_property("pressure"))
      end)

      local hub = platform.hub
      local origin = hub and hub.position or {x = 0, y = 0}
      ctx.probe("platform.hub position", function()
        return origin.x .. "," .. origin.y
      end)
      ctx.probe("tile census near hub", function() return fmt_tiles(surface, origin.x, origin.y, 20) end)
      ctx.probe("entities near hub", function()
        local counts = {}
        for _, e in pairs(surface.find_entities_filtered{area = {
          {origin.x - 10, origin.y - 10}, {origin.x + 10, origin.y + 10}}}) do
          counts[e.name] = (counts[e.name] or 0) + 1
        end
        local parts = {}
        for n, c in pairs(counts) do parts[#parts + 1] = n .. "=" .. c end
        table.sort(parts)
        return table.concat(parts, ", ")
      end)

      -- ---- Attempt 1: the starter 10x10 foundation around the hub.
      ctx.log("--- attempt 1: scan for a clear 3x3 patch on the starter foundation (radius 14) ---")
      local pos = find_patch(surface, origin.x, origin.y, DOME, 14)
      ctx.probe("attempt 1: can_place_entity colony-spike-dome on starter foundation", function()
        return pos_str(pos)
      end)

      -- ---- Attempt 2/3: grow the deck with set_tiles (s22 proved this adds space-platform-foundation).
      if not pos then
        ctx.log("--- starter foundation too small/occupied - growing the deck with set_tiles ---")
        local function grow(lo, hi, cx, cy, label)
          ctx.probe(label .. ": request/force chunks", function()
            surface.request_to_generate_chunks({cx, cy}, 4)
            surface.force_generate_chunk_requests()
            return "chunk generated=" .. tostring(surface.is_chunk_generated({math.floor(cx / 32), math.floor(cy / 32)}))
          end)
          local tiles = {}
          for x = origin.x + lo, origin.x + hi do
            for y = origin.y + lo, origin.y + hi do
              tiles[#tiles + 1] = {name = "space-platform-foundation", position = {x = x, y = y}}
            end
          end
          ctx.probe(label .. ": surface.set_tiles(" .. #tiles .. " foundation tiles)", function()
            local ok, err = pcall(function() surface.set_tiles(tiles) end)
            if not ok then return "ERROR: " .. tostring(err) end
            return "tile at " .. cx .. "," .. cy .. " = " ..
              tostring(surface.get_tile({x = cx, y = cy}).name)
          end)
          local p = find_patch(surface, cx, cy, DOME, 8)
          ctx.probe(label .. ": can_place_entity colony-spike-dome on grown foundation", function()
            return pos_str(p)
          end)
          return p
        end
        pos = grow(8, 24, origin.x + 16, origin.y + 16, "attempt 2 (+8..+24)")
        if not pos then
          pos = grow(-24, -8, origin.x - 16, origin.y - 16, "attempt 3 (-24..-8)")
        end
      end

      -- ---- THE decision check.
      ctx.check("platform: can_place_entity colony-spike-dome (surface_conditions cleared)",
        pos ~= nil, pos_str(pos))

      if pos then
        ctx.probe("chosen patch tile names (3x3)", function()
          local out = {}
          for ox = -1, 1 do
            for oy = -1, 1 do
              local t = surface.get_tile({x = pos.x + ox, y = pos.y + oy})
              out[#out + 1] = tostring(t and t.name)
            end
          end
          table.sort(out)
          return table.concat(out, ",")
        end)
        ctx.probe("chosen patch occupying entities", function()
          local es = surface.find_entities_filtered{area = {
            {pos.x - 2, pos.y - 2}, {pos.x + 2, pos.y + 2}}}
          local parts = {}
          for _, e in pairs(es) do parts[#parts + 1] = e.name .. "@" .. e.position.x .. "," .. e.position.y end
          table.sort(parts)
          return #parts > 0 and table.concat(parts, " | ") or "none"
        end)

        -- Real build with raise_built=true, so the event observer can see on_space_platform_built_entity.
        local built
        ctx.probe("create_entity colony-spike-dome on platform, raise_built=true", function()
          local ok, e = pcall(function()
            return surface.create_entity{name = DOME, position = pos, force = "player", raise_built = true}
          end)
          if not ok then return "ERROR: " .. tostring(e) end
          built = e
          return e and (e.valid and (e.name .. "@" .. e.position.x .. "," .. e.position.y .. " valid=" .. tostring(e.valid)) or "INVALID") or "nil"
        end)
        ctx.check("platform: create_entity colony-spike-dome returned a valid entity",
          built ~= nil and built.valid, built and built.name or "nil")
        ctx.probe("built dome surface_conditions at runtime", function()
          return built and built.valid and fmt_surface_conditions(built.name) or "no built entity"
        end)

        -- Control: the SAME position with the inherited-gravity house must still be refused.
        ctx.probe("CONTROL can_place_entity colony-housing-townhouse at the SAME platform position", function()
          local ok, res = pcall(function()
            return surface.can_place_entity{name = HOUSE, position = pos, force = "player"}
          end)
          return ok and tostring(res) or ("ERROR: " .. tostring(res))
        end)
        ctx.check("platform: control townhouse (gravity >= 0.1) still CANNOT be placed",
          surface.can_place_entity{name = HOUSE, position = pos, force = "player"} == false,
          "townhouse=" .. tostring(surface.can_place_entity{name = HOUSE, position = pos, force = "player"}))
      else
        -- Diagnosis: why does the surface-condition-free prototype still fail?
        ctx.log("*** DIAGNOSIS: dome prototype has no surface conditions yet no patch was found - inspect collision/tiles.")
        local probe_pos = {x = origin.x + 10, y = origin.y + 10}
        ctx.probe("diagnostic tile at " .. probe_pos.x .. "," .. probe_pos.y, function()
          return tostring(surface.get_tile(probe_pos).name)
        end)
        ctx.probe("diagnostic can_place forced=true at " .. probe_pos.x .. "," .. probe_pos.y, function()
          local ok, res = pcall(function()
            return surface.can_place_entity{name = DOME, position = probe_pos, force = "player", forced = true}
          end)
          return ok and tostring(res) or ("ERROR: " .. tostring(res))
        end)
        ctx.probe("diagnostic entity_prototype_collides(prototype, pos, false)", function()
          local ok, res = pcall(function()
            return surface.entity_prototype_collides(prototypes.entity[DOME], probe_pos, false)
          end)
          return ok and tostring(res) or ("ERROR: " .. tostring(res))
        end)
        ctx.probe("diagnostic entity_prototype_collides(prototype, pos, true)", function()
          local ok, res = pcall(function()
            return surface.entity_prototype_collides(prototypes.entity[DOME], probe_pos, true)
          end)
          return ok and tostring(res) or ("ERROR: " .. tostring(res))
        end)
        ctx.probe("diagnostic overlapping entities at probe pos", function()
          local es = surface.find_entities_filtered{area = {
            {probe_pos.x - 2, probe_pos.y - 2}, {probe_pos.x + 2, probe_pos.y + 2}}}
          local parts = {}
          for _, e in pairs(es) do parts[#parts + 1] = e.name end
          table.sort(parts)
          return #parts > 0 and table.concat(parts, ",") or "none"
        end)
      end

      -- ---- Control: clearing surface_conditions must not break ordinary worlds.
      local nauvis = game.surfaces.nauvis
      local np = {x = 64, y = 64}
      ctx.probe("Nauvis: generate chunks at " .. np.x .. "," .. np.y, function()
        nauvis.request_to_generate_chunks(np, 3)
        nauvis.force_generate_chunk_requests()
        return "tile=" .. tostring(nauvis.get_tile(np).name)
      end)
      local npos = nauvis.find_non_colliding_position(DOME, np, 20, 1, true)
      ctx.check("Nauvis: colony-spike-dome CAN be placed on an ordinary world",
        npos ~= nil and nauvis.can_place_entity{name = DOME, position = npos, force = "player"},
        pos_str(npos))
      ctx.probe("Nauvis: create_entity colony-spike-dome", function()
        if not npos then return "no position" end
        local ok, e = pcall(function()
          return nauvis.create_entity{name = DOME, position = npos, force = "player", raise_built = true}
        end)
        if not ok then return "ERROR: " .. tostring(e) end
        return e and (e.valid and ("valid " .. e.name) or "INVALID") or "nil"
      end)

      -- Give the engine a few ticks to deliver the built event, then report and finish.
      ctx.after(30, function()
        ctx.probe("on_space_platform_built_entity fired count", function() return built_fired end)
        ctx.probe("script_raised_built fired count (scripted create_entity path)", function()
          return script_built_fired
        end)
        if script_built_fired > 0 then
          ctx.log("script_raised_built data: " .. script_built_report)
        end
        if built_fired > 0 then
          ctx.check("built event carries entity/platform/stack/tags fields", built_report ~= "none", built_report)
          ctx.log("built event data: " .. built_report)
        else
          ctx.log("on_space_platform_built_entity did NOT fire (even though the dome was created) - event fields unproven here")
        end
        finish()
      end)
    end)
  end,
})
