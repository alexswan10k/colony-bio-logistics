-- SPIKE (#1): colonist as a `unit` prototype.
-- Cloned from small-biter so all required unit fields (animations, attack_parameters,
-- collision, etc.) are valid; art is placeholder. Open question: which fields can be dropped.
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
colonist.tint = nil
data:extend({colonist})
