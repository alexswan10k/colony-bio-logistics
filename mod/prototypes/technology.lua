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

-- Milestones (model/milestones.lua): scripted triggers the colony completes by growing, so a new game starts
-- with only the Town Hall and the tree itself says what to do next ("Reach 8 colonists").
local function milestone(name, icon, prereqs, recipes)
  local effects = {}
  for _, r in ipairs(recipes) do effects[#effects + 1] = unlock(r) end
  return {
    type = "technology",
    name = name,
    icon = G .. icon,
    icon_size = 64,
    prerequisites = prereqs,
    effects = effects,
    research_trigger = {type = "scripted", trigger_description = {"colony-milestone." .. name}},
    order = "z[colony]-a-" .. name,
    localised_name = {"technology-name." .. name},
    localised_description = {"technology-description." .. name},
  }
end

data:extend({
  milestone("colony-settlement", "icon-town-hall.png", {}, {
    "colony-housing-tent", "colony-forager-hut", "colony-woodcutter-hut", "colony-basket", "colony-axe",
    "colony-toolsmith"}),
  milestone("colony-mining", "icon-miner-hut.png", {"colony-settlement"}, {
    "colony-miner-hut", "colony-pickaxe", "colony-housing-cabin", "colony-compost-bin",
    "colony-supply-crate", "colony-warehouse", "colony-cemetery"}),
  milestone("colony-hunting-fishing", "icon-hunting-lodge.png", {"colony-mining"}, {
    "colony-hunting-lodge", "colony-bow", "colony-arrow", "colony-fishing-dock", "colony-rod"}),
  milestone("colony-logistics", "icon-watchtower.png", {"colony-hunting-fishing"}, {
    "colony-watchtower", "colony-demand-crate", "colony-logistics-marker"}),
  milestone("colony-food-preservation", "icon-smokehouse.png", {"colony-logistics"}, {
    "colony-salt-pan", "colony-salt-from-stone", "colony-smokehouse", "colony-town-archive", "colony-frontier-pack"}),
  tech("colony-frontier-charter", "icon-frontier-pack.png", 15, {"colony-frontier-pack"}, 10,
    {"colony-food-preservation"}, {
    unlock("colony-frontier-pack-fish"),
  }),
  tech("colony-firearms", "icon-rifle.png", 20, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter"}, {
    unlock("colony-rifle"),
  }),
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
  tech("colony-recreation", "icon-tavern.png", 40, {"colony-frontier-pack"}, 15,
    {"colony-advanced-agriculture", "colony-water-infrastructure"}, {
      unlock("colony-tavern"),
      unlock("colony-ale"),
    }),
  tech("colony-medicine", "icon-clinic.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-advanced-agriculture"}, {
      unlock("colony-clinic"),
      unlock("colony-herbal-medicine"),
    }),
  tech("colony-civic-governance", "icon-civic-pack.png", 50, {"colony-frontier-pack"}, 20,
    {"colony-water-infrastructure", "colony-advanced-agriculture"}, {
      unlock("colony-university"),
      unlock("colony-civic-pack"),
      unlock("colony-housing-apartment"),
      unlock("colony-kitchen"),
    }),
  tech("colony-motor-pool", "icon-motor-pool.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter", "automobilism"}, {
      unlock("colony-motor-pool"),
    }),
  tech("colony-rail-transit", "icon-passenger-platform.png", 40, {"colony-frontier-pack"}, 15,
    {"colony-civic-governance", "railway"}, {
      unlock("colony-passenger-platform"),
      unlock("colony-passenger-coach"),
      unlock("colony-canteen"),
    }),
})
