-- Colony Truck (#60, spike #3): a `unit`, not a `car`. A car can only be driven by a character and the engine has
-- no car autopilot, so steering one from Lua every tick is both expensive and fragile. A unit is driven by the
-- engine's own pathfinder, exactly like a colonist, so a truck is just a faster, bigger hauler that wears the
-- vanilla car's 64-direction sprite. The hauler who drives it waits inside the Motor Pool (scripts/work.lua).
local truck = table.deepcopy(data.raw["unit"]["colony-colonist"])
local car = data.raw["car"]["car"]
truck.name = "colony-truck"
truck.localised_name = {"entity-name.colony-truck"}
truck.localised_description = {"entity-description.colony-truck"}
truck.max_health = car.max_health
truck.resistances = table.deepcopy(car.resistances)
truck.movement_speed = 0.2           -- 2.5x a colonist on foot
truck.distance_per_frame = 0.3
truck.collision_box = {{-0.6, -0.6}, {0.6, 0.6}}
truck.selection_box = table.deepcopy(car.selection_box)
truck.run_animation = table.deepcopy(car.animation)
truck.attack_parameters.animation = table.deepcopy(car.animation)
truck.attack_parameters.range = 1
truck.icon, truck.icon_size, truck.icons = car.icon, car.icon_size, car.icons
truck.working_sound = table.deepcopy(car.working_sound)
truck.dying_explosion = car.dying_explosion
data:extend({truck})
