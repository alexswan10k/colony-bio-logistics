-- Technology adapter: keep a force's recipes in sync with the technologies it has already researched.
--
-- The engine applies `unlock-recipe` effects when a technology finishes, but a mod update can add an effect to a
-- technology a force already has, or rename a recipe. Existing saves then keep the technology and lose the item.
-- Re-applying the effects is idempotent and only ever enables recipes, so it is safe to run on every load.
local events = require("scripts.events")
local M = {}

-- Returns how many recipes were enabled. Only newly enabled recipes are counted.
function M.sync_force(force)
  local enabled = 0
  for _, tech in pairs(force.technologies) do
    if tech.researched then
      for _, effect in ipairs(tech.prototype.effects or {}) do
        if effect.type == "unlock-recipe" then
          local recipe = force.recipes[effect.recipe]
          if recipe and not recipe.enabled then
            recipe.enabled = true
            enabled = enabled + 1
          end
        end
      end
    end
  end
  return enabled
end

function M.sync_all()
  local enabled = 0
  for _, force in pairs(game.forces) do
    enabled = enabled + M.sync_force(force)
  end
  return enabled
end

events.on_configuration_changed(function() M.sync_all() end)

return M
