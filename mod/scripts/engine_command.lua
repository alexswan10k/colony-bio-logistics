-- Shared translation from the Command Whistle's NEUTRAL command descriptions (model/command.lua) to the
-- defines.command table set_command() expects. Factored out in M3 Stage 3 so the Patrol adapter issues the
-- exact same commands as a manual whistle order rather than growing a second, drifting mapping.
-- This is an adapter (it reads `defines`); the pure models stay engine-free.
local M = {}

local DISTRACTION = {none = defines.distraction.none, by_enemy = defines.distraction.by_enemy}

--- Translate a neutral {kind, destination, radius, distraction, target} description.
--- `cmd.target` is a live LuaEntity for kind "attack"; the caller resolves it before calling.
---@param cmd table
---@return table|nil
function M.to_engine(cmd)
  if cmd.kind == "go_to_location" then
    return {type = defines.command.go_to_location, destination = cmd.destination,
      radius = cmd.radius, distraction = DISTRACTION[cmd.distraction]}
  elseif cmd.kind == "attack_area" then
    return {type = defines.command.attack_area, destination = cmd.destination,
      radius = cmd.radius, distraction = DISTRACTION[cmd.distraction]}
  elseif cmd.kind == "attack" then
    local target = cmd.target
    if not (target and target.valid) then return nil end
    return {type = defines.command.attack, target = target, distraction = DISTRACTION[cmd.distraction]}
  end
  return M.stop()
end

--- The parked command used for guards, sleepers, shelterers and a released patrol.
function M.stop()
  return {type = defines.command.stop, ticks_to_wait = 0, distraction = defines.distraction.none}
end

return M
