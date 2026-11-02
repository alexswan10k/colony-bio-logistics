-- PURE: colony well rules (#43).
local yields = require("scripts.model.yields")

local M = {}

M.ITEM = "colony-water"
M.TICKS_PER_WATER = yields.WATER_TICKS
M.CAP = yields.WATER_CAP

function M.full(count) return (count or 0) >= M.CAP end

return M
