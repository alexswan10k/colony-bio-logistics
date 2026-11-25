---@diagnostic enable: undefined-field, missing-fields
-- PURE: off-world working conditions (#69, design §9.1). A colonist on a hostile planet or a space platform
-- cannot simply work in the open: without an issued Enviro-Suit every work spell takes twice as long. The
-- adapter supplies the two facts (is the colony's surface exotic, is a suit in stock); this module owns the
-- number so the rule is testable offline. Existing Nauvis/Gleba towns are unaffected (mult == 1).
local M = {}

M.SUIT = "colony-enviro-suit"
M.EXOTIC_PENALTY = 0.5

---@param exotic boolean|nil
---@param has_suit boolean|nil
---@return number multiplier in (0, 1]
function M.work_mult(exotic, has_suit)
  return exotic and not has_suit and M.EXOTIC_PENALTY or 1
end

---@param base number
---@param exotic boolean|nil
---@param has_suit boolean|nil
---@return number
function M.work_ticks(base, exotic, has_suit)
  return math.ceil(base * M.work_mult(exotic, has_suit))
end

return M
