---@diagnostic enable: undefined-field, missing-fields
-- PURE: salt-pan rules (#81, design §3.1 "coastal salt").
--
-- A pan is a shoreline building: water in reach (the same rule as the Fishing Dock, model/fishing.lua) does
-- the work. Evaporation is deliberately worker-free - the colony's labour is spent on the Smokehouse, not on
-- watching brine dry - and a hauler empties the pan into colony stock like any other provider.
local yields = require("scripts.model.yields")

local M = {}

M.ITEM = "colony-salt"
M.TICKS_PER_SALT = yields.SALT_TICKS   -- slow enough that salt is a real input, quick enough to see
M.CAP = yields.SALT_CAP     -- a full pan stops: salt is a means, not a money printer

function M.full(count) return (count or 0) >= M.CAP end

return M
