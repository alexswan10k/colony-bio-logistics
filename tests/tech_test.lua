local audit = require("scripts.model.tech_audit")

-- A small, clean graph: two colony techs, a start-up lab, and one vanilla intermediate.
local function fixture()
  return {
    techs = {
      ["colony-a"] = {
        prerequisites = {}, trigger = true, packs = {"colony-pack"},
        effects = {{type = "unlock-recipe", recipe = "colony-r1"}},
      },
      ["colony-b"] = {
        prerequisites = {"colony-a"}, packs = {"colony-pack"},
        effects = {{type = "unlock-recipe", recipe = "colony-r2"}},
      },
      ["iron-tech"] = {
        prerequisites = {}, trigger = true, packs = {},
        effects = {{type = "unlock-recipe", recipe = "iron-plate"}},
      },
    },
    recipes = {
      ["colony-r1"] = {enabled = false, ingredients = {}, results = {{type = "item", name = "colony-x"}}},
      ["colony-r2"] = {enabled = false, ingredients = {{type = "item", name = "iron-plate"}},
                       results = {{type = "item", name = "colony-y"}}},
      ["iron-plate"] = {enabled = true, ingredients = {}, results = {{type = "item", name = "iron-plate"}}},
    },
    items = {["colony-x"] = true, ["colony-y"] = true, ["iron-plate"] = true},
    fluids = {},
    labs = {{name = "colony-lab", inputs = {"colony-pack"}, unlocked_by = "colony-a"}},
  }
end

local function kinds(problems)
  local out = {}
  for _, p in ipairs(problems) do out[p.kind] = true end
  return out
end

describe("tech audit", function()
  it("accepts a clean graph", function()
    local p = audit.audit(fixture(), "colony-")
    eq(#p, 0, "expected no problems, got: " .. (p[1] and p[1].message or ""))
  end)

  it("flags a missing prerequisite", function()
    local g = fixture()
    g.techs["colony-b"].prerequisites = {"colony-a", "colony-missing"}
    truthy(kinds(audit.audit(g, "colony-"))["missing-prerequisite"])
  end)

  it("flags an unreachable technology", function()
    local g = fixture()
    g.techs["colony-a"].prerequisites = {"colony-b"}
    truthy(kinds(audit.audit(g, "colony-"))["unreachable"])
  end)

  it("flags a disabled recipe nobody unlocks", function()
    local g = fixture()
    g.recipes["colony-orphan"] = {enabled = false, ingredients = {}, results = {}}
    g.items["colony-orphan"] = true
    truthy(kinds(audit.audit(g, "colony-"))["orphan-recipe"])
  end)

  it("flags a pack no available lab accepts", function()
    local g = fixture()
    g.labs[1].inputs = {"colony-other-pack"}
    truthy(kinds(audit.audit(g, "colony-"))["no-lab"])
  end)

  it("flags a lab that is unlocked too late", function()
    local g = fixture()
    g.labs[1].unlocked_by = "colony-b"
    truthy(kinds(audit.audit(g, "colony-"))["no-lab"])
  end)

  it("flags an ingredient whose recipe is behind a technology the tech does not require", function()
    local g = fixture()
    g.techs["concrete-tech"] = {
      prerequisites = {}, packs = {},
      effects = {{type = "unlock-recipe", recipe = "concrete"}},
    }
    g.recipes["concrete"] = {enabled = false, ingredients = {}, results = {{type = "item", name = "concrete"}}}
    g.items["concrete"] = true
    g.recipes["colony-r2"].ingredients = {{type = "item", name = "concrete"}}
    local by_kind = audit.by_kind(audit.audit(g, "colony-"))
    truthy(by_kind["unmakeable-ingredient"])
  end)

  it("accepts the ingredient once its technology is a prerequisite", function()
    local g = fixture()
    g.techs["concrete-tech"] = {
      prerequisites = {}, packs = {},
      effects = {{type = "unlock-recipe", recipe = "concrete"}},
    }
    g.recipes["concrete"] = {enabled = false, ingredients = {}, results = {{type = "item", name = "concrete"}}}
    g.items["concrete"] = true
    g.recipes["colony-r2"].ingredients = {{type = "item", name = "concrete"}}
    g.techs["colony-b"].prerequisites = {"colony-a", "concrete-tech"}
    eq(#audit.audit(g, "colony-"), 0)
  end)

  it("flags a recipe unlocked twice", function()
    local g = fixture()
    g.techs["colony-b"].effects = {{type = "unlock-recipe", recipe = "colony-r1"}}
    truthy(kinds(audit.audit(g, "colony-"))["duplicate-unlock"])
  end)

  it("ignores vanilla problems outside the scope", function()
    local g = fixture()
    g.techs["vanilla-x"] = {prerequisites = {"vanilla-missing"}, packs = {}, effects = {}}
    eq(#audit.audit(g, "colony-"), 0)
  end)

  it("does not call a recycling loop a supply chain", function()
    local g = fixture()
    g.recipes["colony-r2"].ingredients = {{type = "item", name = "stone"}}
    g.items["stone"] = true
    g.recipes["stone-recycling"] = {
      enabled = true, categories = {"recycling"},
      ingredients = {{type = "item", name = "stone"}}, results = {{type = "item", name = "stone"}},
    }
    eq(#audit.audit(g, "colony-"), 0)
  end)

  it("exempts gathered raw goods from the ingredient rule", function()
    local g = fixture()
    g.recipes["colony-r2"].ingredients = {{type = "item", name = "stone"}}
    g.items["stone"] = true
    g.recipes["stone-crushing"] = {enabled = false, ingredients = {},
                                   results = {{type = "item", name = "stone"}}}
    g.techs["stone-tech"] = {prerequisites = {}, packs = {},
                             effects = {{type = "unlock-recipe", recipe = "stone-crushing"}}}
    truthy(kinds(audit.audit(g, "colony-"))["unmakeable-ingredient"])
    g.raw = {["stone"] = true}
    eq(#audit.audit(g, "colony-"), 0)
  end)

  it("ignores repeated vanilla unlocks of a colony recipe", function()
    local g = fixture()
    g.techs["recycling"] = {
      prerequisites = {}, packs = {},
      effects = {{type = "unlock-recipe", recipe = "colony-r1"},
                 {type = "unlock-recipe", recipe = "colony-r1"}},
    }
    eq(#audit.audit(g, "colony-"), 0)
  end)

  it("skips excluded spike-only technologies", function()
    local g = fixture()
    g.techs["colony-spike"] = {
      prerequisites = {"colony-missing"}, packs = {"spike-pack"},
      effects = {{type = "unlock-recipe", recipe = "colony-spike-recipe"}},
    }
    truthy(kinds(audit.audit(g, "colony-"))["missing-prerequisite"])
    eq(#audit.audit(g, "colony-", {["colony-spike"] = true}), 0)
  end)
end)
