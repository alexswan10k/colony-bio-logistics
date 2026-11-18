-- Adapter: Inspired scholars speed colony research (#48 slice A).
-- Research is engine-driven (work.lua only staffs the lab), so the lever is the force-wide
-- `force.laboratory_speed_modifier` (Factorio 2.1 runtime docs, LuaForce). That is a FORCE modifier:
-- vanilla labs on the same force also speed up. Research itself is force-wide in Factorio, so this is the
-- only coherent scope without physical speed modules, and the owner accepted the side effect.
--
-- All numbers come from the pure `model/inspiration.lua`. This file only reads/writes engine state and keeps
-- a module-local cache (derived data, no storage schema bump). One pass per colony evaluation, never per tick.
local events = require("scripts.events")
local inspiration = require("scripts.model.inspiration")
local M = {}

local applied = {}   -- [force_name] = bonus we last wrote; loses its mind on load, which we handle below
local reset = {}     -- [force_name] = the engine just wiped force modifiers; next write must add from zero

-- Highest bonus among the colonies whose hall belongs to `force`. Colonies combine by MAX, never by sum.
local function target_for(force)
  local target = 0
  for _, c in pairs(storage and storage.colonies or {}) do
    local hall = c.hall
    if hall and hall.valid and hall.force and hall.force.name == force.name then
      local insp = c.inspiration
      local bonus = inspiration.research_bonus(insp and insp.share or 0, insp and insp.quality or 0)
      if bonus > target then target = bonus end
    end
  end
  return target
end

-- Write `base + target`, deriving `base` so that foreign writes and engine resets are preserved:
--   * previous write cached    -> the live value still contains our last bonus, subtract it;
--   * engine reset flagged     -> our bonus was just wiped, so the live value is already the base;
--   * fresh Lua state (load)   -> the engine saved the modifier with our bonus in it, and the module-local
--                                 cache is gone. Subtract the target recomputed from the saved
--                                 colony.inspiration so a save/load does not double-add. A zero live value
--                                 is a fresh map (or a reset) instead: nothing of ours is in it yet.
-- Residual: on a fresh map where another mod has already written a non-zero base we treat it as ours-included
-- and keep the live value for that one evaluation; the next one has a warm cache and preserves it exactly.
local function write(force, target)
  local live = force.laboratory_speed_modifier or 0
  local prev = applied[force.name]
  local base
  if reset[force.name] then
    base, reset[force.name] = live, nil
  elseif prev ~= nil then
    base = live - prev
  elseif live == 0 then
    base = 0
  else
    base = live - target
  end
  local value = math.max(-1, base + target)
  if value ~= live then force.laboratory_speed_modifier = value end
  applied[force.name] = target
  return target
end

-- Called once at the end of each colony evaluation (idempotent across colonies on one force).
function M.apply(force)
  if not (force and force.valid) then return 0 end
  return write(force, target_for(force))
end

-- Exposed for tests/spikes only: simulate a fresh Lua state (save/load) with no cached write.
function M.forget_cache() applied, reset = {}, {} end

-- LuaForce::reset_technology_effects discards script-written modifiers and raises this event with `force`.
-- Re-apply immediately so the window between a reset and a save cannot lose the bonus, and so a player who
-- resets technology effects sees Inspired research restored without waiting for the next evaluation.
events.on(defines.events.on_technology_effects_reset, function(ev)
  local force = ev and ev.force
  if force and force.valid then
    reset[force.name] = true
    write(force, target_for(force))
  else
    applied, reset = {}, {}
  end
end)

return M
