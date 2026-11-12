---@diagnostic enable: undefined-field, missing-fields
-- PURE: crop growth and soil fertility for player-placed farm plots (#44 first slice).
-- Vanilla 2.0 exposes no per-tile fertility property (spike s06), so fertility is a table keyed by tile
-- name: grass is best, dirt good, dry dirt/red desert poor, sand barely worth it. Anything unlisted
-- (water, stone path, concrete, out-of-map) cannot be farmed at all.
local yields = require("scripts.model.yields")

local M = {}

M.GROW_TICKS = 60 * 60          -- 60 s from planting to ripe
M.YIELD_BASE = yields.FARM_BASE  -- produce per harvest at fertility 1.0
M.MIN_FERTILITY = 0.35          -- below this the player cannot place a plot
M.FALLOW, M.GROWING, M.RIPE = 1, 2, 3   -- also the 1-based graphics_variation of the plot sprite

M.FERTILITY = {
  ["grass-1"] = 1.0, ["grass-2"] = 1.0, ["grass-3"] = 1.0, ["grass-4"] = 1.0,
  ["dirt-1"] = 0.85, ["dirt-2"] = 0.85, ["dirt-3"] = 0.85, ["dirt-4"] = 0.85,
  ["dirt-5"] = 0.85, ["dirt-6"] = 0.85, ["dirt-7"] = 0.85,
  ["dry-dirt"] = 0.5,
  ["red-desert-0"] = 0.45, ["red-desert-1"] = 0.45, ["red-desert-2"] = 0.45, ["red-desert-3"] = 0.45,
  ["sand-1"] = 0.25, ["sand-2"] = 0.25, ["sand-3"] = 0.25,
  ["landfill"] = 0.6,
}

function M.fertility(tile_name) return M.FERTILITY[tile_name] or 0 end

function M.plantable(tile_name) return M.fertility(tile_name) >= M.MIN_FERTILITY end

-- Produce from one harvest. Poor soil still gives something, but the tile table is what makes
-- geography matter (design pillar: geographic specialization).
function M.yield_for(fertility)
  return math.max(0, math.floor(M.YIELD_BASE * (fertility or 0) + 0.5))
end

-- Yield with optional fertilizer boost (#44): fertilizer doubles crop yield (2x). Bonus is the per-harvest
-- bonus the specialization score can add on a fertile town (#46); it exists so tests and the overlay can
-- distinguish base yield from town bonus.
function M.harvest_yield(fertility, fertilized, bonus)
  local base = M.yield_for(fertility) + (bonus or 0)
  return (fertilized and (base * 2)) or base
end

-- Stage of a stored plot record at `tick`: fallow, growing or ripe. The runtime also schedules a
-- ripen event; this is the pure view used by tests and the GUI.
function M.stage(plot, tick)
  if not plot or (plot.stage or M.FALLOW) == M.FALLOW then return M.FALLOW end
  if plot.stage == M.GROWING then
    if plot.ripe_at and tick >= plot.ripe_at then return M.RIPE end
    return M.GROWING
  end
  return M.RIPE
end

return M
