-- Prototypes used only by feasibility spikes. Delete once spikes are resolved.

-- Spike #5: pods that spoil; plain vs item-with-tags; refresh recipes with result_is_always_fresh.
local icon = "__base__/graphics/icons/iron-plate.png"
local function pod(name, type)
  return {
    type = type, name = name, icon = icon, icon_size = 64, stack_size = 1,
    spoil_ticks = 60 * 60 * 20, spoil_result = "spoilage",
  }
end
local function refresh(pod_name)
  return {
    type = "recipe", name = pod_name .. "-refresh", categories = {"crafting"}, enabled = true,
    energy_required = 1,
    ingredients = {{type = "item", name = pod_name, amount = 1}, {type = "item", name = "iron-plate", amount = 1}},
    results = {{type = "item", name = pod_name, amount = 1, always_fresh = true}},
  }
end
data:extend({
  pod("colony-pod-plain", "item"), pod("colony-pod-tagged", "item-with-tags"),
  refresh("colony-pod-plain"), refresh("colony-pod-tagged"),
})

-- Spike #2: a "passenger coach" is a cargo wagon clone.
do
  local item = table.deepcopy(data.raw["item-with-entity-data"]["cargo-wagon"] or data.raw["item"]["cargo-wagon"])
  item.name = "colony-passenger-coach"
  item.place_result = "colony-passenger-coach"
  local wagon = table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
  wagon.name = "colony-passenger-coach"
  wagon.minable.result = "colony-passenger-coach"
  wagon.inventory_size = 20
  wagon.fast_replaceable_group = nil
  wagon.next_upgrade = nil
  data:extend({item, wagon})
end
