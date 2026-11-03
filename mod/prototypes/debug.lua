-- Debug generator: free power for testing powered buildings. Debug only; no recipe, given by /colony-kit.
-- A copy of the vanilla interface (never edit the vanilla prototype) that produces 10 MW from nothing.
local debug_gen = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
debug_gen.name = "colony-debug-generator"
debug_gen.localised_name = {"entity-name.colony-debug-generator"}
debug_gen.localised_description = {"entity-description.colony-debug-generator"}
debug_gen.minable = {mining_time = 0.5, result = "colony-debug-generator"}
debug_gen.flags = {"placeable-neutral", "placeable-player", "player-creation"}
debug_gen.energy_source = {type = "electric", usage_priority = "primary-output", buffer_capacity = "10MJ"}
debug_gen.energy_production = "10MW"
debug_gen.energy_usage = "0kW"

local vanilla_item = data.raw["item"]["electric-energy-interface"]
local debug_item = {
  type = "item", name = "colony-debug-generator", place_result = "colony-debug-generator",
  icon = vanilla_item.icon, icon_size = vanilla_item.icon_size, icons = vanilla_item.icons,
  subgroup = "energy", order = "z[colony]-z[debug-generator]", stack_size = 10,
  localised_name = {"item-name.colony-debug-generator"},
  localised_description = {"entity-description.colony-debug-generator"},
}

data:extend({debug_gen, debug_item})
