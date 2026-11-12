-- Tech-tree integrity + save-sync check. Run: scripts/headless-spike.sh m1_tech
--
-- The colony tree is meant to sit inside the vanilla tree, not beside it: every colony technology must be
-- reachable, every recipe it unlocks must exist, the packs it costs must be accepted by a lab available at
-- that point, and its recipes must not need vanilla intermediates whose technology is not a prerequisite.
-- `model/tech_audit.lua` owns the rules; this file only turns the runtime prototypes into a plain graph.
local core = require("scripts.spike.core")
local audit = require("scripts.model.tech_audit")
local science = require("scripts.model.science")
local tech_mod = require("scripts.tech")

core.register("m1_tech", {
  issue = 54, auto = true, desc = "colony technology graph integrity and force recipe sync", usage = "",
  run = function(ctx)
    local graph = {techs = {}, recipes = {}, items = {}, fluids = {}, labs = {}, raw = {}}

    for name, t in pairs(prototypes.technology) do
      -- `LuaTechnologyPrototype.prerequisites` is a dictionary keyed by technology name in 2.0, not an array.
      local prereqs = {}
      for p in pairs(t.prerequisites or {}) do prereqs[#prereqs + 1] = p end
      local effects = {}
      for _, e in ipairs(t.effects or {}) do
        if e.type == "unlock-recipe" then effects[#effects + 1] = {type = e.type, recipe = e.recipe} end
      end
      local packs = {}
      for _, i in ipairs(t.research_unit_ingredients or {}) do packs[#packs + 1] = i.name end
      graph.techs[name] = {prerequisites = prereqs, effects = effects, packs = packs,
                          trigger = t.research_trigger ~= nil}
    end

    for name, r in pairs(prototypes.recipe) do
      local ingredients, results, categories = {}, {}, {}
      for _, i in ipairs(r.ingredients or {}) do
        ingredients[#ingredients + 1] = {type = i.type, name = i.name}
      end
      for _, p in ipairs(r.products or {}) do
        results[#results + 1] = {type = p.type, name = p.name}
      end
      for _, c in ipairs(r.categories or {}) do categories[#categories + 1] = c end
      graph.recipes[name] = {enabled = r.enabled, ingredients = ingredients, results = results,
                             categories = categories}
    end

    for name in pairs(prototypes.item) do graph.items[name] = true end
    for name in pairs(prototypes.fluid) do graph.fluids[name] = true end

    -- Raw goods are gathered, not crafted, so no technology gates them: ore/stone patches, trees (wood), the
    -- plants a colonist harvests, and fish. `mineable_properties.products` is the runtime source of that list.
    for _, e in pairs(prototypes.entity) do
      if e.type == "resource" or e.type == "tree" or e.type == "plant" or e.type == "fish" then
        local m = e.mineable_properties
        if m and m.minable then
          for _, res in ipairs(m.products or {}) do graph.raw[res.name] = true end
        end
      end
    end

    -- The lab coverage source of truth is the model the haulers use; the item/recipe name is the entity name.
    local unlockers = {}
    for tech_name, t in pairs(graph.techs) do
      for _, e in ipairs(t.effects) do
        if e.recipe then
          unlockers[e.recipe] = unlockers[e.recipe] or {}
          unlockers[e.recipe][#unlockers[e.recipe] + 1] = tech_name
        end
      end
    end
    for lab_name, packs in pairs(science.PACKS_BY_LAB) do
      local inputs = {}
      for _, pack in ipairs(packs) do inputs[#inputs + 1] = pack end
      local unlocked_by = unlockers[lab_name] and unlockers[lab_name][1] or nil
      graph.labs[#graph.labs + 1] = {name = lab_name, inputs = inputs, unlocked_by = unlocked_by}
      ctx.log("lab " .. lab_name .. " inputs=" .. table.concat(inputs, ",") ..
        " unlocked_by=" .. tostring(unlocked_by))
    end

    -- Spike-only prototypes (prototypes/spikes.lua) are deliberately not part of the shipped tree.
    local exclude = {["colony-test-tech"] = true, ["colony-test-tech-2"] = true}
    local problems = audit.audit(graph, "colony-", exclude)
    local by_kind = audit.by_kind(problems)
    for _, kind in ipairs({
      "missing-prerequisite", "unreachable", "missing-recipe", "duplicate-unlock", "orphan-recipe",
      "no-lab", "missing-fluid", "missing-item", "unmakeable-ingredient", "unconsumed-pack",
    }) do
      local list = by_kind[kind]
      ctx.check("tech audit: " .. kind, not list,
        list and table.concat(list, " | ") or nil)
    end
    local colony_techs = 0
    for name in pairs(graph.techs) do
      if name:find("^colony%-") then colony_techs = colony_techs + 1 end
    end
    ctx.log("colony technologies audited: " .. tostring(colony_techs))

    ctx.check("Settlement is still a scripted milestone",
      prototypes.technology["colony-settlement"]
        and prototypes.technology["colony-settlement"].research_trigger ~= nil)

    -- The save-sync path: a force that already researched a technology gets its recipe back after an update.
    local force = game.create_force("colony-tech-audit-" .. tostring(game.tick))
    local settlement = force.technologies["colony-settlement"]
    settlement.researched = true
    local tent = force.recipes["colony-housing-tent"]
    ctx.check("researched settlement enables the tent recipe", tent and tent.enabled == true)
    if tent then tent.enabled = false end
    local enabled = tech_mod.sync_force(force)
    ctx.check("sync re-enables recipes of researched technologies",
      tent and tent.enabled == true and enabled >= 1,
      "enabled=" .. tostring(enabled))

    ctx.finish()
  end,
})
