-- SPIKE #70: Gleba perishables as colony food - engine facts, before any adapter design is committed.
-- Run: scripts/headless-spike.sh s17_gleba
--
-- Questions (all about the 2.1 engine, so the probe uses vanilla perishables + dev-only recipes in
-- prototypes/spikes.lua):
-- 1. Exact spoil_ticks / spoil_result for yumako, jellynut, bioflux, yumako-mash, jelly and spoilage itself.
-- 2. Can a mod recipe consume perishable vanilla items and produce our own perishable item?
-- 3. Freshness inheritance: does a craft from a near-spoiled input produce a near-spoiled output, or does the
--    engine hand back a fresh one (the "laundering" faucet we are trying to avoid)?
-- 4. Which freshness knob exists at runtime: product `always_fresh` / `reset_freshness_on_craft`, or the old
--    design-doc recipe name `result_is_always_fresh`?
-- 5. Is cold.lua's restamp item-agnostic (raw Gleba fruit AND our jam revive in a refrigerated warehouse)?
-- 6. Does a spoiled jam / raw fruit become `spoilage` (so the compost loop can take it)?
-- 7. Spore facts for the *follow-up* (Swamp Fever is out of scope here): airborne pollutant ids, surface
--    pollutant_type, and whether surface.pollute(pos, n, "spores") is accepted on Nauvis.
local core = require("scripts.spike.core")
local cold = require("scripts.cold")
local compost = require("scripts.model.compost")

core.register("s17_gleba", {
  issue = 70, auto = true,
  desc = "Gleba spoil data, perishable mod recipes, freshness inheritance, cold restamp, spoilage, spores",
  usage = "",
  run = function(ctx)
    ctx.flat_area(30, "refined-concrete")
    local s, p, f = ctx.surface, ctx.position, game.forces.player

    -- ---------- 1. Vanilla prototype data (MAP_SEED-independent, exact equality is safe) ----------
    local EXPECT = {yumako = 3600, jellynut = 3600, bioflux = 7200, ["yumako-mash"] = 180, jelly = 240}
    local NAMES = {"yumako", "jellynut", "bioflux", "yumako-mash", "jelly"}
    for _, name in ipairs(NAMES) do
      local it = prototypes.item[name]
      local ticks = it and it.get_spoil_ticks() or nil
      ctx.probe(name .. " spoil data", function()
        local r = it and it.spoil_result or nil
        return "ticks=" .. tostring(ticks) .. " (wiki=" .. tostring(EXPECT[name]) .. ") spoil_result=" ..
          tostring(r and r.name or r)
      end)
      ctx.check(name .. " has a spoil timer", ticks ~= nil and ticks > 0, "ticks=" .. tostring(ticks))
      ctx.check(name .. " spoils to spoilage", it ~= nil and it.spoil_result ~= nil and it.spoil_result.name == "spoilage",
        it and it.spoil_result and it.spoil_result.name or "nil")
    end
    ctx.probe("spoilage itself", function()
      local it = prototypes.item["spoilage"]
      return it and ("exists, spoil_ticks=" .. tostring(it.get_spoil_ticks())) or "NO PROTOTYPE"
    end)

    -- ---------- 2. Our own recipes are accepted by the engine ----------
    ctx.check("probe recipes with perishable ingredients loaded",
      prototypes.recipe["colony-test-gleba-jam"] ~= nil and
      prototypes.recipe["colony-test-gleba-jam-fresh"] ~= nil and
      prototypes.item["colony-test-gleba-jam"] ~= nil)
    ctx.probe("probe recipe ingredient", function()
      local r = prototypes.recipe["colony-test-gleba-jam"]
      local i = r and r.ingredients and r.ingredients[1]
      return i and (i.name .. " x" .. tostring(i.amount)) or "none"
    end)
    local JAM_RECIPES = {"colony-gleba-jam-yumako", "colony-gleba-jam-jellynut",
      "colony-gleba-jam-mash", "colony-gleba-jam-jelly"}
    local shipped = prototypes.item["colony-gleba-jam"]
    ctx.check("jam item exists with the documented 45-minute shelf", shipped ~= nil and
      shipped.get_spoil_ticks() == 45 * 60 * 60 and shipped.spoil_result ~= nil and
      shipped.spoil_result.name == "spoilage",
      shipped and ("ticks=" .. tostring(shipped.get_spoil_ticks())) or "missing")
    local all_recipes = true
    for _, name in ipairs(JAM_RECIPES) do
      local r = prototypes.recipe[name]
      local ok = r ~= nil and r.enabled == false and r.products ~= nil and r.products[1] ~= nil and
        r.products[1].name == "colony-gleba-jam"
      if not ok then all_recipes = false end
      ctx.check(name .. " is a disabled recipe producing jam", ok,
        r and ("enabled=" .. tostring(r.enabled)) or "missing")
    end
    ctx.check("all four shipped jam recipes loaded", all_recipes)
    ctx.probe("jam recipe ingredients", function()
      local out = {}
      for _, name in ipairs(JAM_RECIPES) do
        local r = prototypes.recipe[name]
        local parts = {}
        for _, i in ipairs(r and r.ingredients or {}) do parts[#parts + 1] = i.name .. "x" .. tostring(i.amount) end
        out[#out + 1] = name .. ": " .. table.concat(parts, "+")
      end
      return table.concat(out, " | ")
    end)

    -- ---------- 4. Freshness knob names at runtime ----------
    -- Both reads are wrapped so a missing key is reported as a *finding*, not a spike [ERR].
    ctx.probe("recipe.result_is_always_fresh (design-doc name)", function()
      local r = prototypes.recipe["colony-test-gleba-jam"]
      local ok, value = pcall(function() return r.result_is_always_fresh end)
      return ok and ("value=" .. tostring(value)) or "ABSENT: " .. tostring(value)
    end)
    ctx.probe("product freshness fields", function()
      local r = prototypes.recipe["colony-test-gleba-jam"]
      local product = r and r.products and r.products[1]
      if not product then return "no products" end
      local ok1, af = pcall(function() return product.always_fresh end)
      local ok2, rf = pcall(function() return product.reset_freshness_on_craft end)
      return "always_fresh=" .. (ok1 and tostring(af) or "ABSENT") ..
        " reset_freshness_on_craft=" .. (ok2 and tostring(rf) or "ABSENT")
    end)

    -- ---------- 3. Freshness inheritance (the anti-faucet test) ----------
    -- Powered assemblers, each fed a near-spoiled but still-alive yumako stack. spoil_tick = now + 600 leaves
    -- the stack ~83% spoiled and alive for 10 s - long enough for a 1 s craft but definitely not fresh.
    ctx.power_at(p)
    local function machine(recipe, dx)
      local am = s.create_entity{name = "assembling-machine-2", position = {p.x + dx, p.y + 1.5}, force = f}
      if not am then return nil end
      am.set_recipe(recipe)
      local input = am.get_inventory(defines.inventory.crafter_input)
      input.insert{name = "yumako", count = 4}
      input.insert{name = "colony-salt", count = 4}
      for i = 1, #input do
        local st = input[i]
        if st.valid_for_read and st.name == "yumako" then st.spoil_tick = game.tick + 600 end
      end
      return am
    end
    local am_inherit = machine("colony-test-gleba-jam", 0)
    local am_fresh = machine("colony-test-gleba-jam-fresh", 4)
    ctx.check("both probe assemblers placed", am_inherit ~= nil and am_fresh ~= nil)

    -- ---------- 5. Cold chain is item-agnostic ----------
    ctx.probe("fridge prototype and placement", function()
      local proto = prototypes.entity["colony-refrigerated-warehouse"]
      local can, why = s.can_place_entity{name = "colony-refrigerated-warehouse", position = {p.x + 10, p.y}, force = f}
      return "proto=" .. tostring(proto ~= nil) .. " can_place=" .. tostring(can) .. " why=" .. tostring(why)
    end)
    local fridge = s.create_entity{name = "colony-refrigerated-warehouse", position = {p.x + 10, p.y}, force = f,
      raise_built = true}
    if not fridge then
      fridge = s.create_entity{name = "colony-refrigerated-warehouse", position = {p.x + 10.5, p.y + 0.5}, force = f}
    end
    ctx.check("refrigerated warehouse placed", fridge ~= nil)
    local fridge_stacks = {}
    if fridge then
      local inv = fridge.get_inventory(defines.inventory.chest)
      inv.insert{name = "yumako", count = 1}
      inv.insert{name = "colony-gleba-jam", count = 1}
      for i = 1, #inv do
        local st = inv[i]
        if st.valid_for_read then
          st.spoil_tick = game.tick + 1
          fridge_stacks[#fridge_stacks + 1] = st
        end
      end
    end
    local control = s.create_entity{name = "iron-chest", position = {p.x + 14, p.y}, force = f}
    control.insert{name = "yumako", count = 1}
    local control_stack = control.get_inventory(defines.inventory.chest)[1]
    control_stack.spoil_tick = game.tick + 1
    local restamped = cold.pause_all()
    ctx.check("cold pass restamped the refrigerated stacks", restamped >= 2, "restamped=" .. tostring(restamped))
    for i, st in ipairs(fridge_stacks) do
      ctx.check("fridge stack " .. i .. " revived", st.valid_for_read and st.spoil_percent == 0,
        st.valid_for_read and tostring(st.spoil_percent) or "gone")
    end
    ctx.check("control chest was NOT revived", control_stack.valid_for_read and control_stack.spoil_percent > 0.99,
      tostring(control_stack.valid_for_read and control_stack.spoil_percent or "gone"))

    -- ---------- 6. Compost loop accepts the chain's waste ----------
    local function spoil_one(name, dx)
      local chest = s.create_entity{name = "iron-chest", position = {p.x + dx, p.y}, force = f}
      chest.insert{name = name, count = 1}
      local st = chest.get_inventory(defines.inventory.chest)[1]
      local ok, err = pcall(function() st.spoil() end)
      local out = chest.get_inventory(defines.inventory.chest)[1]
      ctx.probe(name .. ".spoil()", function() return "ok=" .. tostring(ok) .. " err=" .. tostring(err) end)
      ctx.check(name .. " spoils into spoilage", out.valid_for_read and out.name == "spoilage",
        out.valid_for_read and out.name or "empty")
    end
    spoil_one("yumako", 20)
    spoil_one("colony-gleba-jam", 24)
    ctx.check("compost batches 10 spoilage into 1 fertilizer", compost.batches(10) == 1,
      "batches(10)=" .. tostring(compost.batches(10)))

    -- ---------- 7. Spore facts (follow-up only) ----------
    ctx.probe("airborne pollutant prototypes", function()
      local names = {}
      local ok, set = pcall(function() return prototypes.airborne_pollutant end)
      if ok and set then for n in pairs(set) do names[#names + 1] = n end end
      table.sort(names)
      return "airborne_pollutant=" .. table.concat(names, ",")
    end)
    ctx.probe("surface.pollutant_type", function()
      local t = s.pollutant_type
      return t and tostring(t.name) or "nil"
    end)
    ctx.probe("surface.pollute(pos, 10, 'spores')", function()
      local before = s.get_pollution(p)
      local ok, err = pcall(function() s.pollute(p, 10, "spores") end)
      local after = s.get_pollution(p)
      return "ok=" .. tostring(ok) .. " err=" .. tostring(err) ..
        " before=" .. tostring(before) .. " after=" .. tostring(after)
    end)

    -- ---------- deferred verdict: freshness inheritance ----------
    ctx.after(300, function()
      local function read(am, label)
        if not am or not am.valid then ctx.log(label, "machine invalid"); return nil end
        local out = am.get_output_inventory()
        for i = 1, #out do
          local st = out[i]
          if st.valid_for_read then
            ctx.log(label, "output:", st.name, "spoil_percent=", tostring(st.spoil_percent))
            return st.spoil_percent
          end
        end
        ctx.log(label, "produced nothing (power/recipe?)")
        return nil
      end
      local inh = read(am_inherit, "inherit")
      local fr = read(am_fresh, "always_fresh")
      ctx.check("perishable recipe produced a jam", inh ~= nil, tostring(inh))
      -- Finding, not a hard FAIL: this decides whether work.lua needs a freshness gate.
      ctx.log("FINDING freshness inheritance: inherit_output_spoil_percent=" .. tostring(inh) ..
        " always_fresh_output_spoil_percent=" .. tostring(fr))
      ctx.finish()
    end)
  end,
})
