-- Thin adapter (#70): tells a spore (Gleba) surface from an ordinary one. No engine mutation: every check is a
-- read of a surface's planet, pollutant type or name. Kept out of model/ because it reads Factorio surfaces.
local M = {}

-- True on a surface the game associates with Gleba, one whose pollutant is spores, or a script-created surface
-- literally named "gleba" (game.create_surface does not associate a planet). Nil-safe: a script-created surface
-- has no `planet`, and a modded/older surface may have no `pollutant_type`.
function M.is_gleba(surface)
  if not surface then return false end
  if surface.planet and surface.planet.name == "gleba" then return true end
  if surface.pollutant_type and surface.pollutant_type.name == "spores" then return true end
  return surface.name == "gleba"
end

-- True ONLY when the surface's own pollutant type is spores. This is the guard for emitting spores: a Nauvis
-- harvest must never gain normal pollution from a Gleba rule. Nil-safe.
function M.is_spore(surface)
  return surface ~= nil and surface.pollutant_type ~= nil and surface.pollutant_type.name == "spores"
end

return M
