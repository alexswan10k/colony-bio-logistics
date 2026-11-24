---@diagnostic enable: undefined-field, missing-fields
-- PURE: the identities of the two colony core buildings (seed hall and Habitat Dome). No Factorio globals.
-- Adapters use these literals instead of repeating them, so a core name has one definition.
local M = {}

M.HALL = "colony-town-hall"
M.DOME = "colony-habitat-dome"
M.CORE = {[M.HALL] = true, [M.DOME] = true}

function M.is_core(name) return M.CORE[name] == true end
function M.is_dome(name) return name == M.DOME end

return M
