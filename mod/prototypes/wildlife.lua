-- Wildlife (#79, design §3.1): the game a Hunting Lodge works.
--
-- It is a `unit` cloned from small-biter so every required field (run animation, steering, collision box)
-- is valid, but almost everything that makes a biter a threat is stripped: no corpse, no biter sounds, no
-- death explosion, one point of damage, and - the important part - it lives on its own force
-- (scripts/wildlife.lua), which nobody is at war with. The colony keeps it wandering with
-- `defines.command.wander` and a hunter kills it from range with a commanded attack.
local G = "__colony-bio-logistics__/graphics/"
local boar = table.deepcopy(data.raw["unit"]["small-biter"])

local function sprite()
  local common = {width = 64, height = 64, direction_count = 1, frame_count = 1, line_length = 1, scale = 0.55,
    animation_speed = 1}
  local main, shadow = table.deepcopy(common), table.deepcopy(common)
  main.filename = G .. "boar.png"
  shadow.filename = G .. "boar-shadow.png"; shadow.width = 128; shadow.draw_as_shadow = true
  return {layers = {main, shadow}}
end

boar.name = "colony-wild-boar"
boar.localised_name = {"entity-name.colony-wild-boar"}
boar.localised_description = {"entity-description.colony-wild-boar"}
boar.icon = G .. "icon-boar.png"
boar.icon_size = 64
boar.icons = nil

boar.max_health = 40
boar.healing_per_tick = 0
boar.movement_speed = 0.06
boar.distance_per_frame = 0.06
boar.vision_distance = 6
boar.distraction_cooldown = 1000000   -- being shot at never makes it break off and fight
boar.min_pursue_time = 0
boar.max_pursue_distance = 1
boar.flags = {"placeable-player", "placeable-off-grid", "not-repairable", "breaths-air"}
boar.collision_box = {{-0.35, -0.35}, {0.35, 0.35}}
boar.selection_box = {{-0.6, -0.5}, {0.6, 0.5}}
boar.sticker_box = nil
boar.corpse = nil
boar.dying_explosion = nil
boar.dying_sound = nil
boar.walking_sound = nil
boar.working_sound = nil
boar.running_sound_animation_positions = nil
boar.water_reflection = nil
boar.damaged_trigger_effect = nil
boar.absorptions_to_join_attack = nil
boar.spawning_time_modifier = nil
boar.loot = nil
boar.ai_settings = {destroy_when_commands_fail = false, allow_try_return_to_spawner = false,
  do_separation = true}
boar.run_animation = sprite()

-- It keeps the inherited melee attack so the prototype is complete, but at one point of damage it cannot
-- meaningfully hurt anyone even if something does make it fight.
boar.attack_parameters.ammo_type.action.action_delivery.target_effects.damage.amount = 1
boar.attack_parameters.animation = sprite()
boar.attack_parameters.sound = nil

data:extend({boar})
