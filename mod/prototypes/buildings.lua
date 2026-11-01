-- M1 buildings: Town Hall (#24), Housing Tent/Cabin (#28), Tool Rack, hidden power sink. Placeholder art: tinted vanilla chests.
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

local function item_of(entity, base_item, order)
  local base = data.raw["item"][base_item]
  return {
    type = "item", name = entity.name, icon = base.icon, icon_size = base.icon_size,
    subgroup = "storage", order = order, place_result = entity.name, stack_size = 10,
    localised_name = {"entity-name." .. entity.name},
  }
end

local function recipe(name, ingredients, time)
  local ing = {}
  for item, n in pairs(ingredients) do ing[#ing + 1] = {type = "item", name = item, amount = n} end
  return {type = "recipe", name = name, enabled = true, energy_required = time,
    ingredients = ing, results = {{type = "item", name = name, amount = 1}}}
end

local hall = chest_clone("steel-chest", "colony-town-hall", {r = 1, g = 0.6, b = 0.3}, 48)
local tent = chest_clone("iron-chest", "colony-housing-tent", {r = 0.6, g = 0.9, b = 0.5}, 4)
local cabin = chest_clone("steel-chest", "colony-housing-cabin", {r = 0.7, g = 0.5, b = 0.3}, 6)
local rack = chest_clone("iron-chest", "colony-tool-rack", {r = 0.8, g = 0.8, b = 0.3}, 8)

-- Hidden electric consumer used to detect whether a powered house is on a live network (read sink.energy).
local sink = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
sink.name = "colony-power-sink"
sink.localised_name = {"entity-name.colony-power-sink"}
sink.minable = nil
sink.flags = {"not-on-map", "placeable-off-grid", "not-blueprintable", "not-deconstructable", "hide-alt-info"}
sink.collision_mask = {layers = {}}
sink.selectable_in_game = false
sink.energy_source = {type = "electric", usage_priority = "secondary-input", buffer_capacity = "20kJ", output_flow_limit = "0W"}
sink.energy_production = "0W"
sink.energy_usage = "5kW"
sink.picture = {filename = "__core__/graphics/empty.png", size = 1}
sink.pictures = nil

local function tool(name, base_icon_item)
  local base = data.raw["item"][base_icon_item] or data.raw["repair-tool"]["repair-pack"]
  return {type = "item", name = name, icon = base.icon, icon_size = base.icon_size, subgroup = "tool",
    order = "z[colony]-" .. name, stack_size = 20, localised_name = {"item-name." .. name}}
end
local fish = data.raw["capsule"]["raw-fish"]

data:extend({
  hall, tent, cabin, rack, sink,
  item_of(hall, "steel-chest", "z[colony]-a[town-hall]"),
  item_of(tent, "iron-chest", "z[colony]-b[housing-tent]"),
  item_of(cabin, "steel-chest", "z[colony]-c[housing-cabin]"),
  item_of(rack, "iron-chest", "z[colony]-d[tool-rack]"),
  recipe("colony-town-hall", {wood = 50, ["iron-plate"] = 50}, 5),
  recipe("colony-housing-tent", {wood = 20, ["iron-plate"] = 5}, 2),
  recipe("colony-housing-cabin", {wood = 40, ["stone-brick"] = 10, ["iron-plate"] = 10}, 4),
  recipe("colony-tool-rack", {wood = 10, ["iron-plate"] = 5}, 2),
  tool("colony-axe", "iron-plate"), tool("colony-pickaxe", "iron-plate"),
  recipe("colony-axe", {wood = 2, ["iron-plate"] = 3}, 1),
  recipe("colony-pickaxe", {wood = 2, ["iron-plate"] = 3}, 1),
  {type = "item", name = "colony-forage", icon = fish.icon, icon_size = fish.icon_size,
   subgroup = "raw-resource", order = "z[colony]-a[forage]", stack_size = 100,
   spoil_ticks = 60 * 60 * 20, spoil_result = "spoilage", localised_name = {"item-name.colony-forage"}},
})
