-- Colony Tech Subtree prototypes (#42, design §8).
--
-- Unlocks colony progression tiers, researched in Town Archives and Universities.
local G = "__colony-bio-logistics__/graphics/"

local function tech(name, icon, count, packs, time, prereqs, effects)
  local ingredients = {}
  for _, p in ipairs(packs) do
    ingredients[#ingredients + 1] = {p, 1}
  end
  return {
    type = "technology",
    name = name,
    icon = G .. icon,
    icon_size = 64,
    prerequisites = prereqs,
    effects = effects or {},
    unit = {
      count = count,
      ingredients = ingredients,
      time = time or 15,
    },
    order = "z[colony]-" .. name,
    localised_name = {"technology-name." .. name},
    localised_description = {"technology-description." .. name},
  }
end

local function unlock(recipe_name)
  return {type = "unlock-recipe", recipe = recipe_name}
end

data:extend({
  tech("colony-frontier-charter", "icon-frontier-pack.png", 15, {"colony-frontier-pack"}, 10, {}, {
    unlock("colony-frontier-pack-fish"),
  }),
  tech("colony-food-preservation", "icon-salt-pan.png", 25, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter"}),
  tech("colony-water-infrastructure", "icon-well.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter"}, {
      unlock("colony-well"),
      unlock("colony-water-bottling"),
      unlock("colony-housing-homestead"),
      unlock("colony-furniture"),
    }),
  tech("colony-advanced-agriculture", "icon-farm-hut.png", 25, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter"}, {
      unlock("colony-farm-hut"),
      unlock("colony-farm-plot"),
      unlock("colony-hoe"),
    }),
  tech("colony-civic-governance", "icon-civic-pack.png", 50, {"colony-frontier-pack"}, 20,
    {"colony-water-infrastructure", "colony-food-preservation"}, {
      unlock("colony-university"),
      unlock("colony-civic-pack"),
      unlock("colony-housing-apartment"),
      unlock("colony-kitchen"),
    }),
})
