-- SPIKE #70: spore emissions - the engine facts the Swamp Fever adapter depends on, before it is wired in.
-- Run: scripts/headless-spike.sh s21_gleba_spores
--
-- s17_gleba already pinned the airborne pollutant ids (pollution, spores) and the 3-arg pollute failure on
-- Nauvis. This probe pins the rest on a real *associated* Gleba surface:
--   1. game.planets["gleba"] exists and g.surface or g.create_surface() gives planet.name == gleba and a spores
--      pollutant_type (game.create_surface only makes a name-only surface, with no planet association).
--   2. On that surface, a 2-arg pollute(pos, 15) really raises local pollution; a 3-arg pollute(pos, 10,
--      "spores") fails with "Unknown entity name" (the 3rd arg is an entity prototype for stats, not a type).
--   3. planet.is_spore is true on the Gleba surface and false on Nauvis / a named-only surface.
--   4. Destroying a tree on the spore surface does NOT itself emit spores: the adapter must emit them itself.
--   5. override_pollution_type (2.1) round-trips if it is reachable.
local core = require("scripts.spike.core")
local planet = require("scripts.planet")

core.register("s21_gleba_spores", {
  issue = 70, auto = true,
  desc = "Gleba spore surface association, 2-arg pollute, 3-arg failure, is_spore guard, tree.destroy emits nothing",
  usage = "",
  run = function(ctx)
    local nauvis = game.surfaces[1]

    -- ---------- 1. The planet and its associated surface ----------
    local g = game.planets["gleba"]
    ctx.check("game.planets.gleba exists", g ~= nil)
    local gs
    if g then
      ctx.probe("gleba.surface or gleba.create_surface()", function()
        if g.surface then gs = g.surface; return "already generated: " .. gs.name end
        local ok, s = pcall(function() return g.create_surface() end)
        if not ok then return "create_surface ERROR: " .. tostring(s) end
        gs = s
        return "created: " .. tostring(s and s.name)
      end)
    end
    ctx.check("obtained the associated Gleba surface", gs ~= nil)

    if gs then
      ctx.check("associated surface has planet.name == gleba", gs.planet ~= nil and gs.planet.name == "gleba",
        gs.planet and gs.planet.name or "nil")
      ctx.check("associated surface pollutant_type is spores", gs.pollutant_type ~= nil and gs.pollutant_type.name == "spores",
        gs.pollutant_type and gs.pollutant_type.name or "nil")
      ctx.probe("surface.pollutant_type / override_pollution_type", function()
        local ok, ov = pcall(function() return gs.override_pollution_type end)
        return "pollutant_type=" .. tostring(gs.pollutant_type and gs.pollutant_type.name) ..
          " override_pollution_type=" .. (ok and tostring(ov) or "ABSENT: " .. tostring(ov))
      end)
      ctx.check("planet.is_gleba true on the associated Gleba surface", planet.is_gleba(gs) == true)
      ctx.check("planet.is_spore true on the associated Gleba surface", planet.is_spore(gs) == true)
      ctx.check("planet.is_spore false on Nauvis", planet.is_spore(nauvis) == false)
      ctx.check("planet.is_gleba false on Nauvis", planet.is_gleba(nauvis) == false)

      -- Chunks are needed before get/set_pollution or create_entity will work on the fresh surface.
      ctx.probe("generate chunks on the Gleba surface", function()
        gs.request_to_generate_chunks({0, 0}, 2)
        gs.force_generate_chunk_requests()
        return "generated=" .. tostring(gs.is_chunk_generated({0, 0}))
      end)
      local pos = {x = 0, y = 0}

      -- ---------- 2. pollute: two args works, three args fails ----------
      local ok_set, err_set = pcall(function() gs.set_pollution(pos, 0) end)
      ctx.check("set_pollution(pos, 0) on the spore surface", ok_set, tostring(err_set))
      local before = gs.get_pollution(pos)
      local ok_two, err_two = pcall(function() gs.pollute(pos, 15) end)   -- 15 = gleba.SPORE_PER_HARVEST
      local after = gs.get_pollution(pos)
      ctx.check("2-arg pollute(pos, 15) raises local spore pollution", ok_two and after > before,
        "ok=" .. tostring(ok_two) .. " before=" .. tostring(before) .. " after=" .. tostring(after))
      local ok_three, err_three = pcall(function() gs.pollute(pos, 10, "spores") end)
      ctx.probe("pollute(pos, 10, 'spores')", function()
        return "ok=" .. tostring(ok_three) .. " err=" .. tostring(err_three)
      end)
      ctx.check("3-arg pollute with 'spores' fails (3rd arg is an entity prototype)", ok_three == false and
        tostring(err_three):find("Unknown entity name") ~= nil, tostring(err_three))

      -- ---------- 4. A tree dying is NOT a spore source by itself ----------
      gs.set_pollution(pos, 0)
      local tree
      ctx.probe("create a tree on the spore surface", function()
        tree = gs.create_entity{name = "tree-01", position = {pos.x + 3, pos.y}, force = "neutral"}
        return "tree=" .. tostring(tree ~= nil and tree.valid)
      end)
      if tree and tree.valid then tree.destroy() end
      local after_tree = gs.get_pollution(pos)
      ctx.check("tree.destroy() raises no spore pollution by itself", after_tree == 0,
        "pollution=" .. tostring(after_tree))

      -- ---------- 5. override_pollution_type round-trip (2.1 RW) ----------
      -- The field is a table {pollutant = LuaAirbornePollutantPrototype?}, NOT a pollutant-name string:
      -- assigning the string "spores" raises. Pin both so a future adapter cannot confuse the two.
      ctx.probe("override_pollution_type round-trip", function()
        local ok_get, old = pcall(function() return gs.override_pollution_type end)
        local ok_str, err_str = pcall(function() gs.override_pollution_type = "spores" end)
        local proto = prototypes.airborne_pollutant["spores"]
        local ok_set, err_set = pcall(function() gs.override_pollution_type = {pollutant = proto} end)
        local ok_read, now = pcall(function()
          local v = gs.override_pollution_type
          return v and v.pollutant and v.pollutant.name or tostring(v)
        end)
        if ok_set and ok_get then pcall(function() gs.override_pollution_type = old end) end
        return "old=" .. tostring(old and old.pollutant and old.pollutant.name) ..
          " string-assign=" .. tostring(ok_str) .. " (" .. tostring(err_str) .. ")" ..
          " proto=" .. tostring(proto and proto.name) .. " table-assign=" .. tostring(ok_set) ..
          " (" .. tostring(err_set) .. ") now=" .. tostring(now)
      end)
    end

    -- ---------- 3b. A game.create_surface surface is NOT associated with a planet ----------
    ctx.probe("game.create_surface('s21-named-only')", function()
      local ok, s = pcall(function() return game.create_surface("s21-named-only") end)
      if not ok then return "create_surface ERROR (already exists?): " .. tostring(s) end
      return "name=" .. s.name .. " planet=" .. tostring(s.planet)
    end)
    local named = game.surfaces["s21-named-only"]
    ctx.check("named-only surface has no planet", named ~= nil and named.planet == nil,
      named and tostring(named.planet) or "no surface")
    ctx.check("named-only surface has no spores pollutant", named ~= nil and planet.is_spore(named) == false)
    ctx.check("planet.is_gleba is false on a named-only surface", named ~= nil and planet.is_gleba(named) == false)

    ctx.finish()
  end,
})
