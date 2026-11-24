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

-- Spike #70 (Gleba food): dev-only perishable jam probes. `always_fresh` is the real 2.1 product field;
-- `result_is_always_fresh` (older design-doc wording) is deliberately NOT used - the spike reports whether
-- the engine even knows that name. One recipe inherits ingredient freshness, one forces a fresh product so the
-- spike can measure the "laundering" difference directly. Enabled, so an assembling machine can be set to them.
do
  local jam = {
    type = "item", name = "colony-test-gleba-jam", icon = icon, icon_size = 64,
    stack_size = 100, spoil_ticks = 45 * 60 * 60, spoil_result = "spoilage",
  }
  local fresh_jam = {
    type = "item", name = "colony-test-gleba-jam-fresh", icon = icon, icon_size = 64,
    stack_size = 100, spoil_ticks = 45 * 60 * 60, spoil_result = "spoilage",
  }
  local function probe_recipe(name, product, always_fresh)
    return {
      type = "recipe", name = name, enabled = true, energy_required = 1,
      ingredients = {{type = "item", name = "yumako", amount = 1}, {type = "item", name = "colony-salt", amount = 1}},
      results = {{type = "item", name = product, amount = 1, always_fresh = always_fresh}},
    }
  end
  data:extend({jam, fresh_jam,
    probe_recipe("colony-test-gleba-jam", "colony-test-gleba-jam", false),
    probe_recipe("colony-test-gleba-jam-fresh", "colony-test-gleba-jam-fresh", true)})
end

-- Spike #63 (de-risking): a habitat-dome candidate that can actually be built on a space platform.
-- s22_dome proved our housing clones inherit {property = gravity, min = 0.1} from the vanilla steel/iron
-- chest, so gravity-0 platforms refuse them even with create_entity/forced/ignore_surface_conditions.
-- This is a plain steel-chest clone with surface_conditions explicitly cleared, so s23_dome_build can
-- prove that clearing the gate is sufficient before the full refactor. Art/icon reuse the existing
-- "town-hall" manifest entry so no new graphics (or manifest key) are needed and packaging still loads.
do
  local ART = require("prototypes.art_manifest")
  local G = "__colony-bio-logistics__/graphics/"
  local function reuse_town_hall_picture()
    local m = ART["town-hall"]
    return {layers = {
      {filename = G .. "town-hall.png", width = m.width, height = m.height, scale = m.scale,
        shift = {m.shift[1], m.shift[2]}},
      {filename = G .. "town-hall-shadow.png", width = m.width * 2, height = m.height, scale = m.scale,
        shift = {m.shift[1], m.shift[2]}, draw_as_shadow = true},
    }}
  end
  local dome = table.deepcopy(data.raw["container"]["steel-chest"])
  dome.name = "colony-spike-dome"
  dome.surface_conditions = nil   -- clear the inherited gravity >= 0.1 gate (the whole point of the spike)
  dome.inventory_size = 8
  dome.collision_box = {{-1.4, -1.4}, {1.4, 1.4}}
  dome.selection_box = {{-1.5, -1.5}, {1.5, 1.5}}
  dome.minable = {mining_time = 0.5, result = "colony-spike-dome"}
  dome.picture = reuse_town_hall_picture()
  dome.icon = G .. "icon-town-hall.png"
  dome.icon_size = 64
  dome.icons = nil
  dome.circuit_connector = nil
  dome.fast_replaceable_group = nil
  dome.next_upgrade = nil

  local dome_item = {
    type = "item", name = "colony-spike-dome",
    icon = G .. "icon-town-hall.png", icon_size = 64,
    subgroup = "storage", order = "z[colony]-z[spike-dome]", stack_size = 10,
    place_result = "colony-spike-dome",
  }
  data:extend({dome, dome_item})
end
