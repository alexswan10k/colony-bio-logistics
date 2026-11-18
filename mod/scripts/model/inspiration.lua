---@diagnostic enable: undefined-field, missing-fields
-- PURE: Inspired research bonus (#48 slice A). Inspiration is a *quality*, not a boolean: a Tavern is 1.25
-- (design §6.3) and a Theatre (slice B, represented here so the rule does not need rework) is 1.5. Both the
-- work buff and the research buff use the same "fraction faster" number (quality - 1), so they can never
-- disagree. Only the research half needs an engine lever; work trips already use recreation.work_ticks.
local M = {}

M.RESEARCH_MAX = 0.5              -- anti-stacking cap: even Theatre + Tavern cannot exceed +50% research
M.TAVERN = 1.25                   -- quality of a Tavern-served house
M.THEATRE = 1.5                   -- quality of a Theatre-served house (slice B; no prototype here yet)
M.QUALITY = {tavern = M.TAVERN, theatre = M.THEATRE}

-- Work ticks for one trip at `quality` (0 = uninspired, 1.25 = Tavern, 1.5 = Theatre).
-- Mirrors recreation.work_ticks(480, true) == 384 exactly at the Tavern quality.
function M.work_ticks(base, quality)
  if quality and quality > 1 then return math.floor(base / quality + 0.5) end
  return base
end

-- Research bonus (a fraction added to force.laboratory_speed_modifier) for the share 0..1 of scholars on
-- duty who are Inspired at `quality`. clamp((quality - 1) * share, 0, RESEARCH_MAX).
-- nil and NaN inputs are treated as "no inspiration" so a bad derived value can never corrupt the engine.
function M.research_bonus(share, quality)
  if not share or not quality then return 0 end
  if share ~= share or quality ~= quality then return 0 end   -- NaN guard
  local bonus = (quality - 1) * share
  if bonus <= 0 then return 0 end
  if bonus > M.RESEARCH_MAX then return M.RESEARCH_MAX end
  return bonus
end

return M
