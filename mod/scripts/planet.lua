-- Thin adapter (#70, #63): tells a spore (Gleba) surface from an ordinary one and gates which buildings may
-- be founded on hostile worlds and space platforms. No engine mutation: every check is a read of a surface's
-- planet, pollutant type or name. Kept out of model/ because it reads Factorio surfaces.
local core = require("scripts.model.core")
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

-- A boarded surface is a space platform; `surface.platform` is the canonical test pinned by s22_dome
-- (a platform surface has planet == nil, so the name fallback cannot identify it). Nil-safe.
function M.is_platform(surface)
  return surface ~= nil and surface.platform ~= nil
end

-- Vulcanus itself (#70): planet association first, then a name fallback for script-created surfaces. Nil-safe
-- and deliberately independent of `pollutant_type`, which is nil on every hostile world and on platforms.
function M.is_vulcanus(surface)
  if not surface then return false end
  local name = (surface.planet and surface.planet.name) or surface.name
  return name == "vulcanus"
end

-- Vulcanus, Fulgora and Aquilo (design §9.1). Gleba is life-friendly, so it is deliberately NOT hostile.
-- Nil-safe on script-created surfaces with no planet; an optional name fallback covers those.
local HOSTILE = {vulcanus = true, fulgora = true, aquilo = true}
function M.is_hostile(surface)
  if not surface then return false end
  local name = (surface.planet and surface.planet.name) or surface.name
  return HOSTILE[name] == true
end

-- Anywhere a colonist cannot live in the open: a platform or a hostile world.
function M.is_exotic(surface)
  return M.is_platform(surface) or M.is_hostile(surface)
end

-- A Habitat Dome may be founded anywhere (it is the pressurized housing those worlds need); every other
-- core building stays on life-friendly surfaces. Nil-safe.
function M.may_found(surface, name)
  return core.is_dome(name) or not M.is_exotic(surface)
end

-- The plain hall may not be founded on a platform or a hostile world. Nil-safe.
function M.may_build_hall(surface)
  return not M.is_exotic(surface)
end

return M
