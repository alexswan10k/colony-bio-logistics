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

-- Spike #13 (Issue #19 / #42): Colony Science feasibility
do
  local pack = {
    type = "tool", name = "colony-test-pack",
    icon = "__base__/graphics/icons/automation-science-pack.png", icon_size = 64,
    subgroup = "science-pack", order = "z[colony]-a[test-pack]", stack_size = 200, durability = 1,
  }
  local spoil_pack = {
    type = "tool", name = "colony-test-spoil-pack",
    icon = "__base__/graphics/icons/logistic-science-pack.png", icon_size = 64,
    subgroup = "science-pack", order = "z[colony]-b[test-spoil-pack]", stack_size = 200, durability = 1,
    spoil_ticks = 120, spoil_result = "spoilage",
  }
  local lab_item = {
    type = "item", name = "colony-test-lab",
    icon = "__base__/graphics/icons/lab.png", icon_size = 64,
    subgroup = "science-pack", order = "z[colony]-c[test-lab]", stack_size = 10,
    place_result = "colony-test-lab",
  }
  local lab = table.deepcopy(data.raw["lab"]["lab"])
  lab.name = "colony-test-lab"
  lab.minable = {mining_time = 0.5, result = "colony-test-lab"}
  lab.inputs = {"colony-test-pack", "colony-test-spoil-pack"}
  lab.fast_replaceable_group = nil
  lab.next_upgrade = nil

  local tech = {
    type = "technology", name = "colony-test-tech",
    icon = "__base__/graphics/technology/automation.png", icon_size = 256,
    unit = {
      count = 20,
      ingredients = {{"colony-test-pack", 1}},
      time = 1,
    },
    order = "z[colony]-a[test]",
  }
  local tech2 = {
    type = "technology", name = "colony-test-tech-2",
    icon = "__base__/graphics/technology/logistics.png", icon_size = 256,
    unit = {
      count = 20,
      ingredients = {{"colony-test-pack", 1}},
      time = 1,
    },
    order = "z[colony]-b[test]",
  }
  data:extend({pack, spoil_pack, lab_item, lab, tech, tech2})
end
