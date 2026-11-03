data:extend({
  {type = "bool-setting", name = "colony-spike-protos", setting_type = "startup", default_value = true, order = "a"},
  {type = "bool-setting", name = "colony-spike-no-attack", setting_type = "startup", default_value = false, order = "b"},
  {type = "bool-setting", name = "colony-debug-log", setting_type = "runtime-global", default_value = false, order = "a"},
  {type = "bool-setting", name = "colony-alerts", setting_type = "runtime-per-user", default_value = true, order = "a-b"},
  {type = "int-setting", name = "colony-interval-seconds", setting_type = "runtime-global", default_value = 60, minimum_value = 5, maximum_value = 600, order = "b"},
  {type = "int-setting", name = "colony-quota-iron-ore", setting_type = "runtime-global", default_value = 200, minimum_value = 0, maximum_value = 1000000, order = "c-a"},
  {type = "int-setting", name = "colony-quota-copper-ore", setting_type = "runtime-global", default_value = 200, minimum_value = 0, maximum_value = 1000000, order = "c-b"},
  {type = "int-setting", name = "colony-quota-coal", setting_type = "runtime-global", default_value = 200, minimum_value = 0, maximum_value = 1000000, order = "c-c"},
  {type = "int-setting", name = "colony-quota-stone", setting_type = "runtime-global", default_value = 200, minimum_value = 0, maximum_value = 1000000, order = "c-d"},
  {type = "int-setting", name = "colony-quota-wood", setting_type = "runtime-global", default_value = 200, minimum_value = 0, maximum_value = 1000000, order = "c-e"},
})
