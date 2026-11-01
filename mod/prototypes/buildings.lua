-- M1 buildings (#24 Town Hall, #28 Housing). Placeholder art: tinted clones of vanilla chests.
local function chest_clone(base, name, tint, size)
  local e = table.deepcopy(data.raw["container"][base])
  e.name = name
  e.minable = {mining_time = 0.5, result = name}
  e.inventory_size = size
  e.localised_name = {"entity-name." .. name}
  e.localised_description = {"entity-description." .. name}
  e.picture.layers[1].tint = tint
  e.fast_replaceable_group = nil
  e.next_upgrade = nil
  return e
end

local function item_of(entity, order)
  local base = data.raw["item"][entity.name == "colony-town-hall" and "steel-chest" or "iron-chest"]
  return {
    type = "item", name = entity.name, icon = base.icon, icon_size = base.icon_size,
    subgroup = "storage", order = order, place_result = entity.name, stack_size = 10,
    localised_name = {"entity-name." .. entity.name},
  }
end

local hall = chest_clone("steel-chest", "colony-town-hall", {r = 1, g = 0.6, b = 0.3}, 32)
local housing = chest_clone("iron-chest", "colony-housing-tent", {r = 0.6, g = 0.9, b = 0.5}, 1)

data:extend({
  hall, housing,
  item_of(hall, "z[colony]-a[town-hall]"), item_of(housing, "z[colony]-b[housing-tent]"),
  {type = "recipe", name = "colony-town-hall", enabled = true, energy_required = 5,
   ingredients = {{type = "item", name = "wood", amount = 50}, {type = "item", name = "iron-plate", amount = 50}},
   results = {{type = "item", name = "colony-town-hall", amount = 1}}},
  {type = "recipe", name = "colony-housing-tent", enabled = true, energy_required = 2,
   ingredients = {{type = "item", name = "wood", amount = 20}, {type = "item", name = "iron-plate", amount = 5}},
   results = {{type = "item", name = "colony-housing-tent", amount = 1}}},
})

local fish = data.raw["capsule"]["raw-fish"]
data:extend({{
  type = "item", name = "colony-forage", icon = fish.icon, icon_size = fish.icon_size,
  subgroup = "raw-resource", order = "z[colony]-a[forage]", stack_size = 100,
  spoil_ticks = 60 * 60 * 20, spoil_result = "spoilage",
  localised_name = {"item-name.colony-forage"},
}})
