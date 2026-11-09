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
    "colony-housing-tent", "colony-forager-hut", "colony-woodcutter-hut", "colony-miner-hut",
    "colony-basket", "colony-axe", "colony-pickaxe", "colony-toolsmith",
    "colony-compost-bin", "colony-supply-crate",
    "colony-town-archive", "colony-frontier-pack", "colony-frontier-pack-forage",
    "colony-frontier-pack-meat", "colony-frontier-pack-produce", "colony-frontier-pack-gleba"}),
  tech("colony-frontier-charter", "icon-frontier-pack.png", 10, {"colony-frontier-pack"}, 10,
    {"colony-settlement"}, {
    unlock("colony-frontier-pack-fish"),
  }),
  tech("colony-permanent-housing", "icon-cabin.png", 10, {"colony-frontier-pack"}, 10,
    {"colony-frontier-charter"}, {
    unlock("colony-housing-cabin"),
  }),
  tech("colony-hunting-fishing", "icon-hunting-lodge.png", 10, {"colony-frontier-pack"}, 10,
    {"colony-frontier-charter"}, {
    unlock("colony-hunting-lodge"), unlock("colony-bow"), unlock("colony-arrow"),
    unlock("colony-fishing-dock"), unlock("colony-rod"),
  }),
  tech("colony-food-preservation", "icon-smokehouse.png", 10, {"colony-frontier-pack"}, 10,
    {"colony-frontier-charter"}, {
    unlock("colony-salt-pan"), unlock("colony-salt-from-stone"), unlock("colony-smokehouse"),
    unlock("colony-frontier-pack-preserved"), unlock("colony-frontier-pack-preserved-fish"),
  }),
  -- Vanilla interlock: advanced colony tiers ride the base game's tech, without making vanilla science a cost.
  -- A player who has not built belts, steel or concrete yet is not offered colony buildings they cannot build.
  tech("colony-logistics", "icon-watchtower.png", 15, {"colony-frontier-pack"}, 15,
    {"colony-frontier-charter", "logistics"}, {
    unlock("colony-watchtower"), unlock("colony-demand-crate"), unlock("colony-logistics-marker"),
    unlock("colony-rifle"), unlock("colony-haul-station"), unlock("colony-wooden-trailer"),
  }),
  tech("colony-warehousing", "icon-warehouse.png", 15, {"colony-frontier-pack"}, 15,
    {"colony-logistics"}, {
    unlock("colony-warehouse"),
  }),
  -- Steel tools (#95): steel axes/pickaxes/hoes cost steel + iron (no wood), last 45 trips and work 20%
  -- faster than the tier-1 wooden/iron tools. The Toolsmith covers tier-1 first, then upgrades.
  tech("colony-steel-tools", "icon-axe.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-logistics", "steel-processing"}, {
    unlock("colony-steel-axe"), unlock("colony-steel-pickaxe"), unlock("colony-steel-hoe"),
  }),
  tech("colony-cemetery", "icon-cemetery.png", 10, {"colony-frontier-pack"}, 10,
    {"colony-frontier-charter"}, {
    unlock("colony-cemetery"),
  }),
  tech("colony-water-infrastructure", "icon-well.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-permanent-housing", "automation-2"}, {
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
    {"colony-water-infrastructure", "colony-advanced-agriculture", "concrete"}, {
      unlock("colony-university"),
      unlock("colony-civic-pack"),
      unlock("colony-housing-apartment"),
      unlock("colony-kitchen"),
    }),
  tech("colony-motor-pool", "icon-motor-pool.png", 30, {"colony-frontier-pack"}, 15,
    {"colony-settlement", "automobilism"}, {
      unlock("colony-motor-pool"),
    }),
  tech("colony-rail-transit", "icon-passenger-platform.png", 40, {"colony-frontier-pack"}, 15,
    {"colony-civic-governance", "railway"}, {
      unlock("colony-passenger-platform"),
      unlock("colony-passenger-coach"),
      unlock("colony-canteen"),
    }),
})
