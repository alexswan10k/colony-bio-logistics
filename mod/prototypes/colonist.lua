-- SPIKE (#1): colonist as a `unit` prototype.
-- Cloned from small-biter so all required unit fields (animations, attack_parameters,
-- collision, etc.) are valid; art is placeholder.
local colonist = table.deepcopy(data.raw["unit"]["small-biter"])
colonist.name = "colony-colonist"
colonist.localised_name = {"entity-name.colony-colonist"}
colonist.minable = nil
colonist.loot = nil
colonist.corpse = nil
colonist.max_health = 100
colonist.movement_speed = 0.2
colonist.vision_distance = 1          -- try to avoid auto-aggro / wandering
colonist.distraction_cooldown = 1000000
colonist.spawning_time_modifier = nil
colonist.absorptions_to_join_attack = nil
colonist.ai_settings = {
  destroy_when_commands_fail = false,
  allow_try_return_to_spawner = false,
  do_separation = true,
}
colonist.flags = {"placeable-off-grid", "not-repairable", "breaths-air"}
-- Placeholder art: single-frame person sprite (mod/graphics/colonist.png); no run cycle yet.
local person = {filename = "__colony-bio-logistics__/graphics/colonist.png", width = 64, height = 64,
  direction_count = 1, frame_count = 1, line_length = 1, scale = 0.6, animation_speed = 1}
colonist.run_animation = table.deepcopy(person)
colonist.attack_parameters.animation = table.deepcopy(person)
colonist.icon = "__colony-bio-logistics__/graphics/colonist.png"; colonist.icon_size = 64; colonist.icons = nil
colonist.selection_box = {{-0.4, -0.7}, {0.4, 0.4}}
-- Spike #1 variant: does a unit load without attack_parameters at all?
if settings.startup["colony-spike-no-attack"].value then
  colonist.attack_parameters = nil
end
data:extend({colonist})
