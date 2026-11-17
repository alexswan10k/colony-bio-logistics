---@diagnostic disable: missing-fields
-- Militia unit (M3 defence stack, #55). A distinct prototype is MANDATORY: Stage 0 (s19_defence) proved
-- `is_military_target` is prototype-level only (runtime writes are rejected), and the militia wants it TRUE
-- so raid waves path to them. Colonists keep the inherited civilian value.
--
-- The native hitscan attack is reduced to a 1-damage baseline: the real damage is scripted by
-- scripts/militia.lua through LuaEntity:damage() using pure model/militia rules, so engine + script damage do
-- not double-count. `destroy_when_commands_fail = false` stops failed paths into a nest silently deleting
-- the unit (the s19_defence biter contrast).
local militia = table.deepcopy(data.raw["unit"]["colony-colonist"])
militia.name = "colony-militia"
militia.localised_name = {"entity-name.colony-militia"}
militia.max_health = 120
militia.is_military_target = true
militia.allow_run_time_change_of_is_military_target = false
militia.ai_settings = table.deepcopy(data.raw["unit"]["colony-colonist"].ai_settings or {})
militia.ai_settings.destroy_when_commands_fail = false
militia.ai_settings.allow_try_return_to_spawner = false
militia.ai_settings.do_separation = true
-- Keep the civilian distraction cooldown: militia never auto-aggro; engagements are commanded by the adapter.
militia.distraction_cooldown = data.raw["unit"]["colony-colonist"].distraction_cooldown

if militia.attack_parameters then
  local ap = table.deepcopy(militia.attack_parameters)
  local effects = ap.ammo_type and ap.ammo_type.action and ap.ammo_type.action.action_delivery
  if effects and effects.target_effects and effects.target_effects.damage then
    effects.target_effects.damage.amount = 1   -- baseline only; script damage is the real hit
  end
  militia.attack_parameters = ap
end

data:extend({militia})
