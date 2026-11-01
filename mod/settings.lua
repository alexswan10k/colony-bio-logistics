data:extend({
  {type = "bool-setting", name = "colony-spike-protos", setting_type = "startup", default_value = true, order = "a"},
  {type = "bool-setting", name = "colony-spike-no-attack", setting_type = "startup", default_value = false, order = "b"},
  {type = "bool-setting", name = "colony-debug-log", setting_type = "runtime-global", default_value = true, order = "a"},
  {type = "int-setting", name = "colony-interval-seconds", setting_type = "runtime-global", default_value = 60, minimum_value = 5, maximum_value = 600, order = "b"},
})
